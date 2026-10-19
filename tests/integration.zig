//! Integration tests: run the real `buta` binary, and where available the
//! real shells, against fixture directories.

const std = @import("std");
const builtin = @import("builtin");
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
    try map.put("PATH", testPath());
    try map.put("HOME", "/nonexistent-home");
    try map.put("BUTA_CONFIG", "/nonexistent/config.zon");
    try map.put("BUTA", try butaPath());
    if (cwd) |c| try map.put("PWD", c);
    for (env) |kv| try map.put(kv[0], kv[1]);
    const r = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = &map,
        // A hung child must fail the test, not hang the test runner.
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
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
    // POSIX shells on Windows get the path with forward slashes.
    var slashed_buf: [std.fs.max_path_bytes]u8 = undefined;
    const slashed = slashed_buf[0..(try butaPath()).len];
    @memcpy(slashed, buta);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, slashed, '\\', '/');

    for ([_][]const u8{ "bash", "zsh", "fish", "powershell" }) |shell| {
        const r = try run(&.{ try butaPath(), "init", shell }, null, &.{});
        defer r.deinit();
        try testing.expectEqual(@as(u8, 0), r.code);
        const want = if (std.mem.eql(u8, shell, "powershell")) buta else slashed;
        try testing.expect(std.mem.indexOf(u8, r.stdout, want) != null);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "::BUTA::") == null);
        const check = if (std.mem.eql(u8, shell, "powershell")) blk: {
            if (!haveShell("pwsh")) continue;
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "init.ps1", .data = r.stdout });
            const script = try tmp.dir.realPathFileAlloc(io, "init.ps1", gpa);
            defer gpa.free(script);
            // The parser's verdict, without running anything.
            const command = try std.fmt.allocPrint(gpa,
                \\$errors = $null
                \\[void][System.Management.Automation.Language.Parser]::ParseFile('{s}', [ref]$null, [ref]$errors)
                \\if ($errors) {{ $errors | ForEach-Object {{ [Console]::Error.WriteLine($_.ToString()) }}; exit 1 }}
            , .{script});
            defer gpa.free(command);
            break :blk try run(&.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command", command }, null, &.{});
        } else blk: {
            if (!haveShell(shell)) continue;
            break :blk try run(&.{ shell, "-n", "-c", r.stdout }, null, &.{});
        };
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
    // Windows file names can't hold `\`, and bash there is a POSIX layer.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    const name = "$(touch PWNED1)`touch PWNED2`${HOME}\\w 100%d !!";
    try tmp.dir.createDirPath(io, name);
    const dir = try std.fs.path.join(gpa, &.{ root, name });
    defer gpa.free(dir);

    const scripts = [_]struct { []const u8, []const u8 }{
        // ${PS1@P} needs bash 4.4 (macOS ships 3.2).
        .{ "bash", "((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 404)) && { printf SKIP; exit; }; PS1=\"$(\"$BUTA\" prompt --shell bash)\"; printf '%s' \"${PS1@P}\"" },
        .{ "zsh", "__buta_prompt=\"$(\"$BUTA\" prompt --shell zsh)\"; setopt prompt_subst; PROMPT='${__buta_prompt}'; print -rnP -- \"$PROMPT\"" },
        .{ "fish", "\"$BUTA\" prompt --shell fish" },
    };
    for (scripts) |s| {
        if (!haveShell(s[0])) continue;
        const r = try run(&.{ s[0], "-c", s[1] }, dir, &.{.{ "BUTA_CONFIG", "/nonexistent" }});
        defer r.deinit();
        if (std.mem.eql(u8, r.stdout, "SKIP")) continue;
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

fn elapsedMs(start: std.Io.Clock.Timestamp) i64 {
    return @intCast(@divTrunc(start.untilNow(io).raw.nanoseconds, std.time.ns_per_ms));
}

test "a module that misses its deadline is left out without delaying the prompt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);

    // A FIFO with no writer: open() blocks forever, like a hung network mount.
    // Windows has no such FIFOs (Git Bash's mkfifo makes one only its own
    // programs understand).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try tmp.dir.createDirPath(io, "slow/.git");
    const fifo = try std.fs.path.join(gpa, &.{ root, "slow/.git/HEAD" });
    defer gpa.free(fifo);
    const mk = run(&.{ "mkfifo", fifo }, null, &.{}) catch return error.SkipZigTest;
    defer mk.deinit();
    if (mk.code != 0) return error.SkipZigTest;
    const dir = try std.fs.path.join(gpa, &.{ root, "slow" });
    defer gpa.free(dir);

    const cases = [_]struct { config: []const u8, deadline_ms: i64 }{
        .{ .config = ".{ .timeout_ms = 60 }", .deadline_ms = 60 },
        // A module override beats the global value.
        .{ .config = ".{ .timeout_ms = 5000, .git_branch = .{ .timeout_ms = 30 }, .git_status = .{ .timeout_ms = 20 } }", .deadline_ms = 30 },
    };
    for (cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = "t.zon", .data = c.config });
        const cfg = try std.fs.path.join(gpa, &.{ root, "t.zon" });
        defer gpa.free(cfg);

        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const r = try run(&.{ try butaPath(), "prompt" }, dir, &.{ .{ "BUTA_CONFIG", cfg }, .{ "BUTA_DEBUG", "1" } });
        defer r.deinit();
        const took = elapsedMs(start);

        try testing.expectEqual(@as(u8, 0), r.code);
        var buf: [1024]u8 = undefined;
        const shown = visible(r.stdout, &buf);
        try testing.expect(std.mem.indexOf(u8, shown, "slow") != null); // other modules still render
        try testing.expect(std.mem.indexOf(u8, shown, "\u{e0a0}") == null); // git_branch left out
        try testing.expect(std.mem.indexOf(u8, r.stderr, "git_branch: missed its") != null);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "git_status: missed its") != null);
        // It waited for the deadline, and not much longer (generous slack for loaded CI machines).
        if (took < c.deadline_ms or took > c.deadline_ms + 400) {
            std.debug.print("deadline {d} ms, took {d} ms\n", .{ c.deadline_ms, took });
            return error.TestUnexpectedResult;
        }
    }
}

test "fast modules finish well before the deadline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "r/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "r/.git/HEAD", .data = "ref: refs/heads/quick\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "t.zon", .data = ".{ .timeout_ms = 3000 }" });
    const cfg = try std.fs.path.join(gpa, &.{ root, "t.zon" });
    defer gpa.free(cfg);
    const dir = try std.fs.path.join(gpa, &.{ root, "r" });
    defer gpa.free(dir);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    const r = try run(&.{ try butaPath(), "prompt" }, dir, &.{.{ "BUTA_CONFIG", cfg }});
    defer r.deinit();
    const took = elapsedMs(start);
    var buf: [1024]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, visible(r.stdout, &buf), "quick") != null);
    // The deadline is an upper bound, not a wait: a 3 s budget must not cost 3 s.
    try testing.expect(took < 1000);
}

/// The test runner's $PATH, for finding git and the shells.
fn testPath() []const u8 {
    const S = struct {
        var map: ?std.process.Environ.Map = null;
    };
    if (S.map == null) S.map = testing.environ.createMap(std.heap.page_allocator) catch return "/usr/bin:/bin";
    return S.map.?.get("PATH") orelse "/usr/bin:/bin";
}

test "output written to a shared file lands after what is already there" {
    // `{ echo ...; buta init zsh; } > file`: the shell's descriptor has
    // moved past the echo. Writing at offset 0 would overwrite it.
    if (!haveShell("sh")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    const r = try run(&.{ "sh", "-c", "{ echo '# my settings'; \"$BUTA\" --version; \"$BUTA\" --version; } > rc" }, root, &.{});
    defer r.deinit();
    const rc = try tmp.dir.readFileAlloc(io, "rc", gpa, .unlimited);
    defer gpa.free(rc);
    try testing.expect(std.mem.startsWith(u8, rc, "# my settings\nbuta "));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, rc, "buta "));
}

test "a tool's version is asked once and then read from the cache" {
    if (builtin.os.tag == .windows or !haveShell("sh")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "proj");
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/package.json", .data = "{}" });
    // A stand-in `node` that counts how often it runs.
    const script = "#!/bin/sh\necho run >> \"$COUNT\"\necho v1.2.3\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/node", .data = script, .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg.zon", .data = ".{ .glyphs = .ascii, .order = .{ .node }, .daemon = .off, .timeout_ms = 2000 }" });
    const proj = try std.fs.path.join(gpa, &.{ root, "proj" });
    defer gpa.free(proj);
    const path = try std.fmt.allocPrint(gpa, "{s}/bin:{s}", .{ root, testPath() });
    defer gpa.free(path);
    const count = try std.fs.path.join(gpa, &.{ root, "count" });
    defer gpa.free(count);
    const cfg = try std.fs.path.join(gpa, &.{ root, "cfg.zon" });
    defer gpa.free(cfg);
    const env: Env = &.{ .{ "PATH", path }, .{ "XDG_CACHE_HOME", root }, .{ "COUNT", count }, .{ "BUTA_CONFIG", cfg } };

    for (0..3) |_| {
        const r = try run(&.{ try butaPath(), "prompt" }, proj, env);
        defer r.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("node v1.2.3", visible(r.stdout, &buf));
    }
    var count_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("run\n", try tmp.dir.readFile(io, "count", &count_buf));

    // A new binary at the same path is asked again.
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/node", .data = "#!/bin/sh\necho run >> \"$COUNT\"\necho v22.0.0\n", .flags = .{ .permissions = .executable_file } });
    const r = try run(&.{ try butaPath(), "prompt" }, proj, env);
    defer r.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("node v22.0.0", visible(r.stdout, &buf));
    try testing.expectEqualStrings("run\nrun\n", try tmp.dir.readFile(io, "count", &count_buf));
}

test "an active virtual environment shows its version and name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "venv");
    try tmp.dir.writeFile(io, .{ .sub_path = "venv/pyvenv.cfg", .data = "home = /usr/bin\nversion_info = 3.11.4.final.0\nprompt = demo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg.zon", .data = ".{ .glyphs = .ascii, .order = .{ .python }, .daemon = .off, .timeout_ms = 2000 }" });
    const venv = try std.fs.path.join(gpa, &.{ root, "venv" });
    defer gpa.free(venv);
    const cfg = try std.fs.path.join(gpa, &.{ root, "cfg.zon" });
    defer gpa.free(cfg);
    // No project files here: the environment alone shows the module.
    const r = try run(&.{ try butaPath(), "prompt" }, root, &.{ .{ "VIRTUAL_ENV", venv }, .{ "BUTA_CONFIG", cfg } });
    defer r.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("py v3.11.4 (demo)", visible(r.stdout, &buf));
}

test "docker, kubernetes and aws contexts come from their config files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "docker");
    try tmp.dir.writeFile(io, .{ .sub_path = "docker/config.json", .data = "{\"auths\":{},\"currentContext\":\"remote\"}" });
    // The first file sets current-context; the second defines that context.
    try tmp.dir.writeFile(io, .{ .sub_path = "kube-a", .data = "apiVersion: v1\ncurrent-context: prod\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kube-b", .data = "contexts:\n- context:\n    cluster: c\n    namespace: payments\n  name: prod\ncurrent-context: other\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "aws-config", .data = "[default]\nregion = us-east-1\n[profile ops]\nregion = eu-west-1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg.zon", .data = ".{ .glyphs = .ascii, .order = .{ .docker_context, .kubernetes, .aws }, .daemon = .off, .timeout_ms = 2000 }" });

    const docker = try std.fs.path.join(gpa, &.{ root, "docker" });
    defer gpa.free(docker);
    const kube = try std.fmt.allocPrint(gpa, "{s}/kube-a{s}{s}/kube-b", .{ root, if (builtin.os.tag == .windows) ";" else ":", root });
    defer gpa.free(kube);
    const aws = try std.fs.path.join(gpa, &.{ root, "aws-config" });
    defer gpa.free(aws);
    const cfg = try std.fs.path.join(gpa, &.{ root, "cfg.zon" });
    defer gpa.free(cfg);

    const r = try run(&.{ try butaPath(), "prompt" }, root, &.{
        .{ "DOCKER_CONFIG", docker }, .{ "KUBECONFIG", kube }, .{ "AWS_CONFIG_FILE", aws },
        .{ "AWS_PROFILE", "ops" },    .{ "BUTA_CONFIG", cfg },
    });
    defer r.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("docker remote k8s prod (payments) aws ops (eu-west-1)", visible(r.stdout, &buf));

    // Nothing set: all three stay hidden.
    const quiet = try run(&.{ try butaPath(), "prompt" }, root, &.{.{ "BUTA_CONFIG", cfg }});
    defer quiet.deinit();
    try testing.expectEqualStrings("", visible(quiet.stdout, &buf));
}

/// One HTTP request to `buta config`; returns the response body.
fn httpRequest(port: u16, method: []const u8, path: []const u8, token: []const u8, host: []const u8, body: ?[]const u8) ![]u8 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nx-buta-token: {s}\r\n", .{ method, path, host, token });
    if (body) |b| try w.interface.print("content-type: application/json\r\ncontent-length: {d}\r\n", .{b.len});
    try w.interface.writeAll("\r\n");
    if (body) |b| try w.interface.writeAll(b);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const response = try r.interface.allocRemaining(gpa, .limited(1 << 20));
    defer gpa.free(response);
    const start = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.BadResponse) + 4;
    return gpa.dupe(u8, response[start..]);
}

test "buta config serves the editor, previews and saves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeFixture(&tmp);
    defer gpa.free(root);
    const cfg = try std.fs.path.join(gpa, &.{ root, "config.zon" });
    defer gpa.free(cfg);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = "// mine\n.{ .glyphs = .ascii }\n" });

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("PATH", testPath());
    try map.put("HOME", root);
    try map.put("BUTA_CONFIG", cfg);
    if (builtin.os.tag == .windows) {
        // Winsock needs it.
        var parent = try testing.environ.createMap(gpa);
        defer parent.deinit();
        if (parent.get("SystemRoot")) |v| try map.put("SystemRoot", v);
    }
    var child = try std.process.spawn(io, .{
        .argv = &.{ try butaPath(), "config", "--no-open" },
        .cwd = .{ .path = root },
        .environ_map = &map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    // The first line is `buta config: http://127.0.0.1:<port>/#<token>`.
    var lbuf: [512]u8 = undefined;
    var lr = child.stdout.?.readerStreaming(io, &lbuf);
    const line = try lr.interface.takeDelimiterExclusive('\n');
    const url = line[std.mem.indexOf(u8, line, "http://").?..];
    const port_start = "http://127.0.0.1:".len;
    const port_end = std.mem.indexOfScalarPos(u8, url, port_start, '/').?;
    const port = try std.fmt.parseInt(u16, url[port_start..port_end], 10);
    const token = url[std.mem.indexOfScalar(u8, url, '#').? + 1 ..];
    var host_buf: [32]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{port});

    const page = try httpRequest(port, "GET", "/", "", host, null);
    defer gpa.free(page);
    try testing.expect(std.mem.indexOf(u8, page, "<title>buta config</title>") != null);

    // Without the token, or under another name, nothing is answered.
    const denied = try httpRequest(port, "GET", "/api/state", "nope", host, null);
    defer gpa.free(denied);
    try testing.expect(std.mem.indexOf(u8, denied, "bad token") != null);
    const rebound = try httpRequest(port, "GET", "/api/state", token, "evil.example:80", null);
    defer gpa.free(rebound);
    try testing.expectEqualStrings("", rebound);

    const state = try httpRequest(port, "GET", "/api/state", token, host, null);
    defer gpa.free(state);
    try testing.expect(std.mem.indexOf(u8, state, "\"glyphs\":\"ascii\"") != null);
    try testing.expect(std.mem.indexOf(u8, state, "\"name\":\"carpet\"") != null);

    // A preview is the real prompt, drawn with the edited config.
    const preview = try httpRequest(port, "POST", "/api/preview", token, host,
        \\{"config":{"glyphs":"ascii","order":["status","character"],"character":{"failure_symbol":"FAIL"}},"runs":[{"status":3}]}
    );
    defer gpa.free(preview);
    var vbuf: [256]u8 = undefined;
    const parsed = std.json.parseFromSlice(struct { runs: []const struct { prompt: []const u8 } }, gpa, preview, .{ .ignore_unknown_fields = true }) catch |e| {
        std.debug.print("preview answered: {s}\n", .{preview});
        return e;
    };
    defer parsed.deinit();
    try testing.expectEqualStrings("x 3 FAIL ", visible(parsed.value.runs[0].prompt, &vbuf));

    // Saving writes the file (and keeps the old one), and the prompt uses it.
    const saved = try httpRequest(port, "POST", "/api/save", token, host,
        \\{"config":{"glyphs":"ascii","order":["character"],"character":{"success_symbol":"$$"}}}
    );
    defer gpa.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "\"backup\":") != null);
    var fbuf: [1024]u8 = undefined;
    try testing.expectEqualStrings("// mine\n.{ .glyphs = .ascii }\n", try tmp.dir.readFile(io, "config.zon.bak", &fbuf));
    const r = try run(&.{ try butaPath(), "prompt" }, root, &.{.{ "BUTA_CONFIG", cfg }});
    defer r.deinit();
    try testing.expectEqualStrings("$$ ", visible(r.stdout, &vbuf));

    const bye = try httpRequest(port, "POST", "/api/quit", token, host, "{}");
    defer gpa.free(bye);
    try testing.expect(std.mem.indexOf(u8, bye, "\"ok\":true") != null);
    _ = try child.wait(io);
}
