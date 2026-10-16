const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const cli = @import("cli.zig");
const config = @import("config.zig");
const context = @import("context.zig");
const glyphs = @import("glyphs.zig");
const module = @import("module.zig");
const render = @import("render.zig");

const scripts = struct {
    const bash = @embedFile("shell/bash.sh");
    const zsh = @embedFile("shell/zsh.sh");
    const fish = @embedFile("shell/fish.sh");
};

/// All prompt-path allocations (config source, parsed config, module data)
/// come from this buffer and are released together when the process exits.
/// It lives in .bss: pages that are never touched cost nothing.
var heap_buffer: [256 * 1024]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    // Single-threaded Io: no thread pool is started. Phase 1 swaps this for a
    // threaded implementation to run modules concurrently.
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;
    var err_buf: [1024]u8 = undefined;
    var err_file = Io.File.stderr().writer(io, &err_buf);
    const err = &err_file.interface;

    var args = init.args.iterate();
    _ = args.skip();
    const status: u8 = run(io, init.environ, &args, out, err) catch 1;
    out.flush() catch {};
    err.flush() catch {};
    return status;
}

fn run(io: Io, environ: std.process.Environ, args: anytype, out: *Io.Writer, err: *Io.Writer) !u8 {
    const cmd = cli.parse(args) catch |e| {
        try err.print("buta: {s}\n\n{s}", .{ switch (e) {
            error.UnknownCommand => "unknown command",
            error.MissingShell => "init: missing shell name",
            error.InvalidShell => "init: unsupported shell (expected bash, zsh or fish)",
            error.UnexpectedArgument => "init: unexpected argument",
        }, cli.usage });
        return 2;
    };
    switch (cmd) {
        .version => try out.print("buta {s}\n", .{build_options.version}),
        .help => try out.writeAll(cli.usage),
        .init => |shell| try writeInit(io, shell, out),
        .prompt => |p| prompt(io, environ, p, out, err),
    }
    return 0;
}

fn prompt(io: Io, environ: std.process.Environ, args: cli.PromptArgs, out: *Io.Writer, err: *Io.Writer) void {
    var fba: std.heap.FixedBufferAllocator = .init(&heap_buffer);
    const arena = fba.allocator();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pwd = context.validPwd(environ.getPosix("PWD"));
    const physical: []const u8 = if (std.process.currentPath(io, &cwd_buf)) |n| cwd_buf[0..n] else |_| pwd orelse "/";

    const ctx: context.Context = .{
        .io = io,
        .environ = environ,
        .cwd = pwd orelse physical,
        .physical_cwd = physical,
        .home = context.normalizeHome(environ.getPosix("HOME")),
        .status = args.status,
        .duration_ms = args.duration_ms,
        .jobs = args.jobs,
        .shell = args.shell,
        .debug = if (environ.getPosix("BUTA_DEBUG")) |v| v.len > 0 else false,
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const loaded: config.LoadResult = if (config.path(&path_buf, EnvLookup{ .environ = environ }, ctx.home)) |p|
        config.load(io, arena, p)
    else
        .{ .config = .{} };
    if (loaded.problem) |msg| err.print("buta: {s}\nbuta: using the default configuration\n", .{msg}) catch {};
    const cfg = &loaded.config;

    var slots: module.Slots = undefined;
    module.computeAll(&ctx, cfg, arena, &slots);

    var line: render.Line = .{};
    module.renderAll(&slots, cfg, glyphs.get(cfg.glyphs), &line);
    render.write(&line, ctx.shell, out) catch {};
}

const EnvLookup = struct {
    environ: std.process.Environ,
    pub fn get(e: EnvLookup, name: []const u8) ?[]const u8 {
        return e.environ.getPosix(name);
    }
};

/// Prints the init script with `::BUTA::` replaced by the quoted absolute
/// path of this executable, so the hooks do not depend on $PATH.
fn writeInit(io: Io, shell: cli.InitShell, out: *Io.Writer) !void {
    const script = switch (shell) {
        .bash => scripts.bash,
        .zsh => scripts.zsh,
        .fish => scripts.fish,
    };
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(io, &exe_buf)) |n| exe_buf[0..n] else |_| "buta";

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
}

test {
    _ = cli;
    _ = config;
    _ = context;
    _ = glyphs;
    _ = module;
    _ = render;
    _ = @import("git/repo.zig");
    inline for (@typeInfo(module.impls).@"struct".decls) |d| _ = @field(module.impls, d.name);
}
