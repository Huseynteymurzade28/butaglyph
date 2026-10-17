const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const cli = @import("cli.zig");
const config = @import("config.zig");
const context = @import("context.zig");
const daemon = @import("daemon.zig");
const env_mod = @import("env.zig");
const glyphs = @import("glyphs.zig");
const module = @import("module.zig");
const render = @import("render.zig");

const scripts = struct {
    const bash = @embedFile("shell/bash.sh");
    const zsh = @embedFile("shell/zsh.sh");
    const fish = @embedFile("shell/fish.sh");
    const powershell = @embedFile("shell/powershell.ps1");
};

/// Prompt-path allocations for the config (source and parsed values) come
/// from this buffer; module data comes from per-module heaps in `runtime`.
/// Everything is released together when the process exits. Both live in
/// .bss: pages that are never touched cost nothing.
var heap_buffer: [256 * 1024]u8 = undefined;
var runtime: module.Runtime = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    // Worker threads are spawned on demand, only when an expensive module is
    // configured. `threaded` is never deinitialized: that would join workers,
    // and an abandoned module task must not be able to delay exit.
    // `environ` is what processes it spawns inherit (the daemon, started by
    // a prompt).
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{ .stack_size = 1024 * 1024, .environ = init.environ });
    const io = threaded.io();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;
    var err_buf: [1024]u8 = undefined;
    var err_file = Io.File.stderr().writer(io, &err_buf);
    const err = &err_file.interface;

    // Windows converts the (UTF-16) arguments and environment once; both
    // live until exit.
    var args = if (env_mod.is_windows)
        init.args.iterateAllocator(std.heap.page_allocator) catch return 1
    else
        init.args.iterate();
    _ = args.skip();
    const env: env_mod.Env = .init(init.environ, std.heap.page_allocator);
    const status: u8 = run(io, env, &args, out, err) catch 1;
    out.flush() catch {};
    err.flush() catch {};
    return status;
}

fn run(io: Io, env: env_mod.Env, args: anytype, out: *Io.Writer, err: *Io.Writer) !u8 {
    const cmd = cli.parse(args) catch |e| {
        try err.print("buta: {s}\n\n{s}", .{ switch (e) {
            error.UnknownCommand => "unknown command",
            error.MissingShell => "init: missing shell name",
            error.InvalidShell => "init: unsupported shell (expected bash, zsh, fish or powershell)",
            error.UnexpectedArgument => "init: unexpected argument",
            error.InvalidDaemonArgument => "daemon: expected `--detach`, `status` or `stop`",
        }, cli.usage });
        return 2;
    };
    switch (cmd) {
        .version => try out.print("buta {s}\n", .{build_options.version}),
        .help => try out.writeAll(cli.usage),
        .init => |shell| try writeInit(io, shell, out),
        .prompt => |p| prompt(io, env, p, out, err),
        .daemon => |opts| return daemon.main(io, env, opts, out, err),
    }
    return 0;
}

/// Never returns: module tasks that missed their deadline may still be
/// running and reading `ctx`, `loaded` and the buffers in this frame, so the
/// frame stays alive until the process exits right here.
fn prompt(io: Io, env: env_mod.Env, args: cli.PromptArgs, out: *Io.Writer, err: *Io.Writer) noreturn {
    var fba: std.heap.FixedBufferAllocator = .init(&heap_buffer);
    const arena = fba.allocator();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var arg_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = workingDir(io, env, args.cwd, &arg_cwd_buf, &cwd_buf);

    const ctx: context.Context = .{
        .io = io,
        .env = env,
        .cwd = cwd.logical,
        .physical_cwd = cwd.physical,
        .home = context.normalizeHome(homeDir(env, &home_buf)),
        .status = args.status,
        .duration_ms = args.duration_ms,
        .jobs = args.jobs,
        .shell = args.shell,
        .debug = env.flag("BUTA_DEBUG"),
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const loaded: config.LoadResult = if (config.path(&path_buf, env, ctx.home)) |p|
        config.load(io, arena, p)
    else
        .{ .config = .{} };
    if (loaded.problem) |msg| err.print("buta: {s}\nbuta: using the default configuration\n", .{msg}) catch {};
    const cfg = &loaded.config;

    runtime.jobs = @splat(.{});
    var slots: module.Slots = undefined;
    module.computeAll(&ctx, cfg, &runtime, &slots);

    var line: render.Line = .{};
    module.renderAll(&slots, cfg, glyphs.get(cfg.glyphs), &line);
    render.write(&line, ctx.shell, out) catch {};
    out.flush() catch {};
    err.flush() catch {};
    std.process.exit(0);
}

const WorkingDir = struct { logical: []const u8, physical: []const u8 };

/// `--cwd` when given (PowerShell), else $PWD for display and getcwd for
/// filesystem walks. Windows ignores $PWD: a POSIX layer (Git Bash, MSYS2)
/// sets it in its own `/c/...` form.
fn workingDir(io: Io, env: env_mod.Env, arg: ?[]const u8, arg_buf: []u8, buf: []u8) WorkingDir {
    if (arg) |a| if (env_mod.toSlashesCopy(arg_buf, a)) |p| if (env_mod.isAbsolute(p)) {
        const trimmed = trimTrailingSlashes(p);
        return .{ .logical = trimmed, .physical = trimmed };
    };
    const pwd = if (env_mod.is_windows) null else context.validPwd(env.get("PWD"));
    const physical: []const u8 = if (std.process.currentPath(io, buf)) |n| env_mod.toSlashes(buf[0..n]) else |_| pwd orelse "/";
    return .{ .logical = pwd orelse physical, .physical = physical };
}

fn trimTrailingSlashes(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    return if (t.len < env_mod.rootLen(p)) p[0..env_mod.rootLen(p)] else t;
}

/// $HOME; on Windows $HOME only if it is a Windows path (a POSIX layer may
/// set it), else %USERPROFILE%.
fn homeDir(env: env_mod.Env, buf: []u8) ?[]const u8 {
    if (!env_mod.is_windows) return env.get("HOME");
    if (env.get("HOME")) |h| if (env_mod.toSlashesCopy(buf, h)) |p| if (env_mod.isAbsolute(p)) return p;
    return env_mod.toSlashesCopy(buf, env.get("USERPROFILE") orelse return null);
}

/// Prints the init script with `::BUTA::` replaced by the quoted absolute
/// path of this executable, so the hooks do not depend on $PATH.
fn writeInit(io: Io, shell: cli.InitShell, out: *Io.Writer) !void {
    const script = switch (shell) {
        .bash => scripts.bash,
        .zsh => scripts.zsh,
        .fish => scripts.fish,
        .powershell => scripts.powershell,
    };
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(io, &exe_buf)) |n|
        // POSIX shells on Windows (Git Bash, MSYS2, Cygwin) run `C:/x/buta.exe`.
        if (shell == .powershell) exe_buf[0..n] else env_mod.toSlashes(exe_buf[0..n])
    else |_|
        "buta";

    var it = std.mem.splitSequence(u8, script, "::BUTA::");
    try out.writeAll(it.first());
    while (it.next()) |rest| {
        try writeQuoted(shell, exe, out);
        try out.writeAll(rest);
    }
}

fn writeQuoted(shell: cli.InitShell, s: []const u8, out: *Io.Writer) !void {
    try out.writeByte('\'');
    for (s) |c| switch (shell) {
        .bash, .zsh => if (c == '\'') try out.writeAll("'\\''") else try out.writeByte(c),
        .fish => switch (c) {
            '\'', '\\' => try out.print("\\{c}", .{c}),
            else => try out.writeByte(c),
        },
        .powershell => if (c == '\'') try out.writeAll("''") else try out.writeByte(c),
    };
    try out.writeByte('\'');
}

test writeQuoted {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeQuoted(.bash, "/o'k/buta", &w);
    try std.testing.expectEqualStrings("'/o'\\''k/buta'", w.buffered());
    w = .fixed(&buf);
    try writeQuoted(.fish, "/o'k\\/buta", &w);
    try std.testing.expectEqualStrings("'/o\\'k\\\\/buta'", w.buffered());
    w = .fixed(&buf);
    try writeQuoted(.powershell, "C:\\o'k\\buta.exe", &w);
    try std.testing.expectEqualStrings("'C:\\o''k\\buta.exe'", w.buffered());
}

test trimTrailingSlashes {
    try std.testing.expectEqualStrings("/a/b", trimTrailingSlashes("/a/b/"));
    try std.testing.expectEqualStrings("/", trimTrailingSlashes("/"));
    // `//` is the start of a UNC path on Windows, the root elsewhere.
    try std.testing.expectEqualStrings(if (env_mod.is_windows) "//" else "/", trimTrailingSlashes("//"));
}

test {
    _ = cli;
    _ = config;
    _ = context;
    _ = daemon;
    _ = env_mod;
    _ = glyphs;
    _ = @import("client.zig");
    _ = @import("protocol.zig");
    _ = @import("wire.zig");
    _ = module;
    _ = render;
    inline for (@typeInfo(module.impls).@"struct".decls) |d| _ = @field(module.impls, d.name);
}
