//! Command-line parsing. `prompt` is deliberately lenient: it runs on every
//! prompt, so a malformed or unknown flag must never cost the user their
//! prompt. Other commands are strict.

const std = @import("std");
const Shell = @import("render.zig").Shell;

pub const InitShell = enum { bash, zsh, fish };

pub const PromptArgs = struct {
    shell: Shell = .plain,
    status: i32 = 0,
    duration_ms: ?u64 = null,
    jobs: u32 = 0,
};

pub const Command = union(enum) {
    prompt: PromptArgs,
    init: InitShell,
    version,
    help,
};

pub const Error = error{ UnknownCommand, MissingShell, InvalidShell, UnexpectedArgument };

pub const usage =
    \\Usage:
    \\  buta init <bash|zsh|fish>    Print the shell integration script
    \\  buta prompt [options]        Print the prompt
    \\      --shell <bash|zsh|fish>  Quote output for this shell (default: none)
    \\      --status <int>           Exit status of the last command
    \\      --duration-ms <int>      Duration of the last command
    \\      --jobs <int>             Number of background jobs
    \\  buta --version
    \\  buta --help
    \\
    \\Setup: add `eval "$(buta init bash)"` to ~/.bashrc, `eval "$(buta init zsh)"`
    \\to ~/.zshrc, or `buta init fish | source` to ~/.config/fish/config.fish.
    \\
;

/// `args` must have a `next() ?[]const u8` method and be positioned after argv[0].
pub fn parse(args: anytype) Error!Command {
    const cmd = args.next() orelse return .help;
    if (eql(cmd, "--version") or eql(cmd, "-V") or eql(cmd, "version")) return .version;
    if (eql(cmd, "--help") or eql(cmd, "-h") or eql(cmd, "help")) return .help;
    if (eql(cmd, "init")) {
        const name = args.next() orelse return error.MissingShell;
        const shell = std.meta.stringToEnum(InitShell, name) orelse return error.InvalidShell;
        if (args.next() != null) return error.UnexpectedArgument;
        return .{ .init = shell };
    }
    if (eql(cmd, "prompt")) return .{ .prompt = parsePrompt(args) };
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

        const Flag = enum { @"--shell", @"--status", @"--duration-ms", @"--jobs" };
        // Unknown flags are ignored so a newer init script works with an older binary.
        const flag = std.meta.stringToEnum(Flag, name) orelse continue;
        const value = inline_value orelse args.next() orelse break;
        switch (flag) {
            .@"--shell" => p.shell = std.meta.stringToEnum(Shell, value) orelse .plain,
            .@"--status" => p.status = std.fmt.parseInt(i32, value, 10) catch 0,
            .@"--duration-ms" => p.duration_ms = std.fmt.parseInt(u64, value, 10) catch null,
            .@"--jobs" => p.jobs = std.fmt.parseInt(u32, value, 10) catch 0,
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

test "init and meta commands" {
    try std.testing.expectEqual(Command{ .init = .fish }, try testParse(&.{ "init", "fish" }));
    try std.testing.expectError(error.InvalidShell, testParse(&.{ "init", "tcsh" }));
    try std.testing.expectError(error.MissingShell, testParse(&.{"init"}));
    try std.testing.expectError(error.UnexpectedArgument, testParse(&.{ "init", "zsh", "x" }));
    try std.testing.expectError(error.UnknownCommand, testParse(&.{"bogus"}));
    try std.testing.expectEqual(Command.version, try testParse(&.{"--version"}));
    try std.testing.expectEqual(Command.help, try testParse(&.{}));
}
