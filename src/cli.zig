//! Command-line parsing. `prompt` is deliberately lenient: it runs on every
//! prompt, so a malformed or unknown flag must never cost the user their
//! prompt. Other commands are strict.

const std = @import("std");
const Shell = @import("render.zig").Shell;
const daemon = @import("daemon.zig");

pub const InitShell = enum { bash, zsh, fish, powershell };

pub const PromptArgs = struct {
    shell: Shell = .plain,
    status: i32 = 0,
    duration_ms: ?u64 = null,
    jobs: u32 = 0,
    /// The shell's working directory, for shells whose idea of it is not
    /// the process's (PowerShell). Overrides $PWD and getcwd.
    cwd: ?[]const u8 = null,
};

pub const Command = union(enum) {
    prompt: PromptArgs,
    init: InitShell,
    daemon: daemon.Options,
    version,
    help,
};

pub const Error = error{ UnknownCommand, MissingShell, InvalidShell, UnexpectedArgument, InvalidDaemonArgument };

pub const usage =
    \\Usage:
    \\  buta init <shell>            Print the shell integration script
    \\                               (bash, zsh, fish or powershell)
    \\  buta prompt [options]        Print the prompt
    \\      --shell <shell>          Quote output for this shell (default: none)
    \\      --status <int>           Exit status of the last command
    \\      --duration-ms <int>      Duration of the last command
    \\      --jobs <int>             Number of background jobs
    \\      --cwd <path>             Working directory (default: $PWD, then the process's)
    \\  buta daemon [--detach]       Run the cache daemon (in the background with --detach)
    \\  buta daemon status           Show whether it runs, and its cache statistics
    \\  buta daemon stop             Stop it
    \\  buta --version
    \\  buta --help
    \\
    \\Setup: add `eval "$(buta init bash)"` to ~/.bashrc, `eval "$(buta init zsh)"`
    \\to ~/.zshrc, `buta init fish | source` to ~/.config/fish/config.fish, or
    \\`Invoke-Expression (& buta init powershell | Out-String)` to $PROFILE.
    \\
;

/// `args` must have a `next() ?[]const u8` method and be positioned after argv[0].
pub fn parse(args: anytype) Error!Command {
    const cmd = args.next() orelse return .help;
    if (eql(cmd, "--version") or eql(cmd, "-V") or eql(cmd, "version")) return .version;
    if (eql(cmd, "--help") or eql(cmd, "-h") or eql(cmd, "help")) return .help;
    if (eql(cmd, "init")) {
        const name = args.next() orelse return error.MissingShell;
        const shell = if (eql(name, "pwsh")) .powershell else std.meta.stringToEnum(InitShell, name) orelse return error.InvalidShell;
        if (args.next() != null) return error.UnexpectedArgument;
        return .{ .init = shell };
    }
    if (eql(cmd, "prompt")) return .{ .prompt = parsePrompt(args) };
    if (eql(cmd, "daemon")) {
        var opts: daemon.Options = .{};
        while (args.next()) |arg| {
            if (eql(arg, "--detach")) {
                opts.detach = true;
            } else if (std.meta.stringToEnum(daemon.Action, arg)) |action| {
                opts.action = action;
            } else return error.InvalidDaemonArgument;
        }
        if (opts.detach and opts.action != .run) return error.InvalidDaemonArgument;
        return .{ .daemon = opts };
    }
    return error.UnknownCommand;
}

fn parsePrompt(args: anytype) PromptArgs {
    var p: PromptArgs = .{};
    while (args.next()) |arg| {
        // Accept both `--flag value` and `--flag=value`.
        const name, const inline_value = if (std.mem.indexOfScalar(u8, arg, '=')) |i|
            .{ arg[0..i], @as(?[]const u8, arg[i + 1 ..]) }
        else
            .{ arg, @as(?[]const u8, null) };

        const Flag = enum { @"--shell", @"--status", @"--duration-ms", @"--jobs", @"--cwd" };
        // Unknown flags are ignored so a newer init script works with an older binary.
        const flag = std.meta.stringToEnum(Flag, name) orelse continue;
        const value = inline_value orelse args.next() orelse break;
        switch (flag) {
            .@"--shell" => p.shell = if (eql(value, "pwsh")) .powershell else std.meta.stringToEnum(Shell, value) orelse .plain,
            .@"--status" => p.status = std.fmt.parseInt(i32, value, 10) catch 0,
            .@"--duration-ms" => p.duration_ms = std.fmt.parseInt(u64, value, 10) catch null,
            .@"--jobs" => p.jobs = std.fmt.parseInt(u32, value, 10) catch 0,
            .@"--cwd" => p.cwd = if (value.len > 0) value else null,
        }
    }
    return p;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const SliceIter = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(it: *SliceIter) ?[]const u8 {
        if (it.i == it.items.len) return null;
        defer it.i += 1;
        return it.items[it.i];
    }
};

fn testParse(items: []const []const u8) Error!Command {
    var it: SliceIter = .{ .items = items };
    return parse(&it);
}

test "prompt flags" {
    const c = try testParse(&.{ "prompt", "--shell", "zsh", "--status", "127", "--duration-ms=2500", "--jobs", "2" });
    try std.testing.expectEqual(Command{ .prompt = .{ .shell = .zsh, .status = 127, .duration_ms = 2500, .jobs = 2 } }, c);
}

test "prompt is lenient" {
    const c = try testParse(&.{ "prompt", "--future-flag", "--shell", "tcsh", "--status", "x", "--duration-ms", "", "--jobs" });
    try std.testing.expectEqual(Command{ .prompt = .{} }, c);
    try std.testing.expectEqual(Command{ .prompt = .{ .status = -1 } }, try testParse(&.{ "prompt", "--status=-1" }));
}

test "prompt --cwd and powershell" {
    const c = try testParse(&.{ "prompt", "--shell=pwsh", "--cwd", "C:\\Users\\a b", "--duration-ms=" });
    try std.testing.expectEqual(Shell.powershell, c.prompt.shell);
    try std.testing.expectEqualStrings("C:\\Users\\a b", c.prompt.cwd.?);
    try std.testing.expectEqual(@as(?u64, null), c.prompt.duration_ms);
    try std.testing.expectEqual(@as(?[]const u8, null), (try testParse(&.{ "prompt", "--cwd=" })).prompt.cwd);
}

test "init and meta commands" {
    try std.testing.expectEqual(Command{ .init = .fish }, try testParse(&.{ "init", "fish" }));
    try std.testing.expectEqual(Command{ .init = .powershell }, try testParse(&.{ "init", "pwsh" }));
    try std.testing.expectError(error.InvalidShell, testParse(&.{ "init", "tcsh" }));
    try std.testing.expectError(error.MissingShell, testParse(&.{"init"}));
    try std.testing.expectError(error.UnexpectedArgument, testParse(&.{ "init", "zsh", "x" }));
    try std.testing.expectError(error.UnknownCommand, testParse(&.{"bogus"}));
    try std.testing.expectEqual(Command.version, try testParse(&.{"--version"}));
    try std.testing.expectEqual(Command.help, try testParse(&.{}));
}

test "daemon commands" {
    try std.testing.expectEqual(Command{ .daemon = .{} }, try testParse(&.{"daemon"}));
    try std.testing.expectEqual(Command{ .daemon = .{ .detach = true } }, try testParse(&.{ "daemon", "--detach" }));
    try std.testing.expectEqual(Command{ .daemon = .{ .action = .stop } }, try testParse(&.{ "daemon", "stop" }));
    try std.testing.expectEqual(Command{ .daemon = .{ .action = .status } }, try testParse(&.{ "daemon", "status" }));
    try std.testing.expectError(error.InvalidDaemonArgument, testParse(&.{ "daemon", "restart" }));
    try std.testing.expectError(error.InvalidDaemonArgument, testParse(&.{ "daemon", "stop", "--detach" }));
}
