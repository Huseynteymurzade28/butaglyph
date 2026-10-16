//! Integration tests: run the real `buta` binary, and where available the
//! real shells, against fixture directories.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

/// The binary path from the build system may be relative to the build root;
/// tests change the child's cwd, so resolve it once.
var buta_buf: [std.fs.max_path_bytes]u8 = undefined;
var buta: []const u8 = "";

fn butaPath() ![]const u8 {
    if (buta.len == 0) {
        const n = try std.Io.Dir.cwd().realPathFile(io, build_options.buta_path, &buta_buf);
        buta = buta_buf[0..n];
    }
    return buta;
}

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(r: Result) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

const Env = []const [2][]const u8;

fn run(argv: []const []const u8, cwd: ?[]const u8, env: Env) !Result {
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("PATH", testing.environ.getPosix("PATH") orelse "/usr/bin:/bin");
    try map.put("HOME", "/nonexistent-home");
    try map.put("BUTA_CONFIG", "/nonexistent/config.zon");
    try map.put("BUTA", try butaPath());
    if (cwd) |c| try map.put("PWD", c);
    for (env) |kv| try map.put(kv[0], kv[1]);
    const r = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = &map,
    });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .code = switch (r.term) {
        .exited => |c| c,
        else => 255,
    } };
}

fn haveShell(name: []const u8) bool {
    const r = run(&.{ name, "-c", "exit 0" }, null, &.{}) catch return false;
    defer r.deinit();
    return r.code == 0;
}

/// Removes ANSI SGR sequences and readline's \x01/\x02 markers.
fn visible(out: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == 0x1b) {
            while (i < out.len and out[i] != 'm') i += 1;
            continue;
        }
        if (out[i] == 0x01 or out[i] == 0x02) continue;
        buf[n] = out[i];
        n += 1;
    }
    return buf[0..n];
}

/// Asserts that every ESC in a raw prompt sits inside a balanced, non-nested
/// zero-width marker pair: `\[ \]` (bash, where `\\` is an escaped
/// backslash) or `%{ %}` (zsh, where `%%` is an escaped percent).
fn expectWrapped(out: []const u8, esc_char: u8) !void {
    var inside = false;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (c == esc_char and i + 1 < out.len) {
            switch (out[i + 1]) {
                '[', '{' => {
                    try testing.expect(!inside);
                    inside = true;
                },
                ']', '}' => {
                    try testing.expect(inside);
                    inside = false;
                },
                else => {},
            }
            i += 1;
            continue;
        }
        if (c == 0x1b and !inside) {
            std.debug.print("unwrapped escape at byte {d} of: {any}\n", .{ i, out });
            return error.UnwrappedEscape;
        }
    }
    try testing.expect(!inside);
}

fn makeFixture(tmp: *testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(io, ".", gpa);
}

test "--version" {
    const r = try run(&.{ try butaPath(), "--version" }, null, &.{});
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "buta "));
}

test "bad usage exits 2 and prints usage on stderr" {
    const r = try run(&.{ try butaPath(), "init", "tcsh" }, null, &.{});
    defer r.deinit();
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "Usage:") != null);
}

test "init scripts embed the binary path and parse in their shell" {
    for ([_][]const u8{ "bash", "zsh", "fish" }) |shell| {
        const r = try run(&.{ try butaPath(), "init", shell }, null, &.{});
        defer r.deinit();
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stdout, buta) != null);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "::BUTA::") == null);
        if (!haveShell(shell)) continue;
        const check = try run(&.{ shell, "-n", "-c", r.stdout }, null, &.{});
        defer check.deinit();
        if (check.code != 0) std.debug.print("{s}: {s}\n", .{ shell, check.stderr });
        try testing.expectEqual(@as(u8, 0), check.code);
    }
}

test "escape sequences are always wrapped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });

    const args = [_][]const u8{ "--status", "130", "--duration-ms", "65000", "--jobs", "3" };
    const cfg = try std.fs.path.join(gpa, &.{ root, "all.zon" });
    defer gpa.free(cfg);
    try tmp.dir.writeFile(io, .{ .sub_path = "all.zon", .data =
    \\.{ .order = .{ .dir, .git_branch, .duration, .status, .jobs, .line_break, .character },
    \\   .dir = .{ .style = .{ .fg = "#ff8800", .bg = "17", .bold = true, .underline = true } } }
    });
    for ([_]struct { []const u8, u8 }{ .{ "bash", '\\' }, .{ "zsh", '%' } }) |case| {
        const r = try run(&(.{ try butaPath(), "prompt", "--shell", case[0] } ++ args), root, &.{.{ "BUTA_CONFIG", cfg }});
        defer r.deinit();
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.indexOfScalar(u8, r.stdout, 0x1b) != null);
        try expectWrapped(r.stdout, case[1]);
    }
}

test "hostile directory names are displayed literally, never executed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    const name = "$(touch PWNED1)`touch PWNED2`${HOME}\\w 100%d !!";
    try tmp.dir.createDirPath(io, name);
    const dir = try std.fs.path.join(gpa, &.{ root, name });
    defer gpa.free(dir);

    const scripts = [_]struct { []const u8, []const u8 }{
        .{ "bash", "PS1=\"$(\"$BUTA\" prompt --shell bash)\"; printf '%s' \"${PS1@P}\"" },
        .{ "zsh", "__buta_prompt=\"$(\"$BUTA\" prompt --shell zsh)\"; setopt prompt_subst; PROMPT='${__buta_prompt}'; print -rnP -- \"$PROMPT\"" },
        .{ "fish", "\"$BUTA\" prompt --shell fish" },
    };
    for (scripts) |s| {
        if (!haveShell(s[0])) continue;
        const r = try run(&.{ s[0], "-c", s[1] }, dir, &.{.{ "BUTA_CONFIG", "/nonexistent" }});
        defer r.deinit();
        var buf: [1024]u8 = undefined;
        const shown = visible(r.stdout, &buf);
        if (std.mem.indexOf(u8, shown, name) == null) {
            std.debug.print("{s} showed: {s}\nstderr: {s}\n", .{ s[0], shown, r.stderr });
            return error.NameNotShownLiterally;
        }
        for ([_][]const u8{ "PWNED1", "PWNED2" }) |f| {
            if (tmp.dir.access(io, f, .{})) |_| return error.CommandWasExecuted else |_| {}
            const in_dir = try std.fs.path.join(gpa, &.{ name, f });
            defer gpa.free(in_dir);
            if (tmp.dir.access(io, in_dir, .{})) |_| return error.CommandWasExecuted else |_| {}
        }
    }
}

test "git branch, detached HEAD and worktree via the binary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "r/.git/worktrees/w");
    try tmp.dir.createDirPath(io, "r/sub/dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "r/.git/HEAD", .data = "ref: refs/heads/topic/x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "r/.git/worktrees/w/HEAD", .data = "3f786850e387550fdab836ed7e6dc881de23001b\n" });
    try tmp.dir.createDirPath(io, "w");
    try tmp.dir.writeFile(io, .{ .sub_path = "w/.git", .data = "gitdir: ../r/.git/worktrees/w\n" });

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "r/sub/dir", " topic/x" },
        .{ "w", " 3f78685" },
    };
    for (cases) |c| {
        const dir = try std.fs.path.join(gpa, &.{ root, c[0] });
        defer gpa.free(dir);
        const r = try run(&.{ try butaPath(), "prompt" }, dir, &.{});
        defer r.deinit();
        var buf: [1024]u8 = undefined;
        const shown = visible(r.stdout, &buf);
        if (std.mem.indexOf(u8, shown, c[1]) == null) {
            std.debug.print("expected '{s}' in: {s}\n", .{ c[1], shown });
            return error.TestUnexpectedResult;
        }
    }
}

test "a failing module does not break the prompt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "broken/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/.git/HEAD", .data = "garbage" });
    const dir = try std.fs.path.join(gpa, &.{ root, "broken" });
    defer gpa.free(dir);

    const r = try run(&.{ try butaPath(), "prompt", "--status", "1" }, dir, &.{.{ "BUTA_DEBUG", "1" }});
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.code);
    var buf: [1024]u8 = undefined;
    const shown = visible(r.stdout, &buf);
    try testing.expect(std.mem.indexOf(u8, shown, "broken") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "\u{276f}") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "git_branch: InvalidHead") != null);
}

test "an invalid config falls back to defaults and says why" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zon", .data = ".{ .glyphs = .emoji }" });
    const cfg = try std.fs.path.join(gpa, &.{ root, "bad.zon" });
    defer gpa.free(cfg);

    const r = try run(&.{ try butaPath(), "prompt" }, root, &.{.{ "BUTA_CONFIG", cfg }});
    defer r.deinit();
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\u{276f}") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "bad.zon:1:") != null);
}

test "ascii glyph set produces 7-bit output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ascii.zon", .data = ".{ .glyphs = .ascii, .order = .{ .git_branch, .duration, .status, .jobs, .character } }" });
    const cfg = try std.fs.path.join(gpa, &.{ root, "ascii.zon" });
    defer gpa.free(cfg);
    const dir = try std.fs.path.join(gpa, &.{ root, "repo" });
    defer gpa.free(dir);

    const r = try run(&.{ try butaPath(), "prompt", "--status", "2", "--duration-ms", "3000", "--jobs", "2" }, dir, &.{.{ "BUTA_CONFIG", cfg }});
    defer r.deinit();
    for (r.stdout) |c| try testing.expect(c < 0x80);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("git:main took 3.0s x 2 &2 > ", visible(r.stdout, &buf));
}
