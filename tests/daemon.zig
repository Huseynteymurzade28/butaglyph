//! Daemon tests: run the real `buta daemon` and check every prompt it
//! serves against what `buta prompt` computes on its own, across a long
//! sequence of git operations. The daemon may only ever be faster, never
//! different. Linux and macOS; the git-driven tests are skipped without git.

const std = @import("std");
const build_options = @import("build_options");
const sys = @import("sys");
const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

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

fn haveGit() bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "git", "--version" } }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

const config =
    \\.{ .glyphs = .ascii, .order = .{ .git_branch, .git_status }, .timeout_ms = 5000 }
;

const Harness = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    socket: []const u8,
    config: []const u8,
    daemon: ?std.process.Child = null,

    fn init() !Harness {
        if (!sys.supported) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(root);
        // Socket paths are short (103 bytes on macOS): fall back to /tmp
        // when the test directory is deep.
        var socket = try std.fs.path.join(gpa, &.{ root, "d.sock" });
        if (socket.len > sys.max_socket_path) {
            gpa.free(socket);
            var id: [8]u8 = undefined;
            io.random(&id);
            socket = try std.fmt.allocPrint(gpa, "/tmp/buta-test-{x}.sock", .{std.mem.readInt(u64, &id, .little)});
        }
        errdefer gpa.free(socket);
        try tmp.dir.writeFile(io, .{ .sub_path = "c.zon", .data = config });
        return .{ .tmp = tmp, .root = root, .socket = socket, .config = try std.fs.path.join(gpa, &.{ root, "c.zon" }) };
    }

    fn deinit(h: *Harness) void {
        h.stop();
        if (std.mem.startsWith(u8, h.socket, "/tmp/")) {
            std.Io.Dir.cwd().deleteFile(io, h.socket) catch {};
            const lock = std.fmt.allocPrint(gpa, "{s}.lock", .{h.socket}) catch return;
            defer gpa.free(lock);
            std.Io.Dir.cwd().deleteFile(io, lock) catch {};
        }
        gpa.free(h.config);
        gpa.free(h.socket);
        gpa.free(h.root);
        h.tmp.cleanup();
    }

    fn env(h: *Harness, map: *std.process.Environ.Map, use_daemon: bool) !void {
        try map.put("PATH", testPath());
        try map.put("HOME", h.root);
        try map.put("BUTA_CONFIG", h.config);
        try map.put("BUTA_SOCKET", if (use_daemon) h.socket else "");
        try map.put("GIT_CONFIG_NOSYSTEM", "1");
        try map.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try map.put("GIT_AUTHOR_NAME", "T");
        try map.put("GIT_AUTHOR_EMAIL", "t@example.com");
        try map.put("GIT_COMMITTER_NAME", "T");
        try map.put("GIT_COMMITTER_EMAIL", "t@example.com");
    }

    fn run(h: *Harness, argv: []const []const u8, sub: []const u8, use_daemon: bool) !Result {
        var map: std.process.Environ.Map = .init(gpa);
        defer map.deinit();
        try h.env(&map, use_daemon);
        const cwd = try std.fs.path.join(gpa, &.{ h.root, sub });
        defer gpa.free(cwd);
        try map.put("PWD", cwd);
        const r = try std.process.run(gpa, io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &map,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
        return .{ .stdout = r.stdout, .stderr = r.stderr, .code = switch (r.term) {
            .exited => |c| c,
            else => 255,
        } };
    }

    fn start(h: *Harness) !void {
        return h.startFrom(try butaPath());
    }

    fn startFrom(h: *Harness, exe: []const u8) !void {
        var map: std.process.Environ.Map = .init(gpa);
        defer map.deinit();
        try h.env(&map, true);
        h.daemon = try std.process.spawn(io, .{
            .argv = &.{ exe, "daemon" },
            .environ_map = &map,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        // Wait until it answers.
        for (0..200) |_| {
            const r = try h.run(&.{ try butaPath(), "daemon", "status" }, "", true);
            defer r.deinit();
            if (r.code == 0) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.DaemonDidNotStart;
    }

    fn stop(h: *Harness) void {
        var child = h.daemon orelse return;
        h.daemon = null;
        if (h.run(&.{ butaPath() catch return, "daemon", "stop" }, "", true)) |r| r.deinit() else |_| {}
        _ = child.wait(io) catch child.kill(io);
    }

    fn git(h: *Harness, sub: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "git");
        try argv.appendSlice(gpa, args);
        const r = try h.run(argv.items, sub, false);
        defer r.deinit();
        if (r.code != 0) {
            std.debug.print("git {s} failed:\n{s}\n", .{ args[0], r.stderr });
            return error.GitFailed;
        }
    }

    fn write(h: *Harness, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |d| try h.tmp.dir.createDirPath(io, d);
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn prompt(h: *Harness, sub: []const u8, use_daemon: bool) !Result {
        return h.run(&.{ try butaPath(), "prompt" }, sub, use_daemon);
    }

    /// The daemon's prompt (asked twice: a miss, then normally a hit) must
    /// equal the locally computed one.
    fn check(h: *Harness, sub: []const u8, step: []const u8) !void {
        const local = try h.prompt(sub, false);
        defer local.deinit();
        for (0..2) |_| {
            const served = try h.prompt(sub, true);
            defer served.deinit();
            if (!std.mem.eql(u8, local.stdout, served.stdout)) {
                std.debug.print("after `{s}`:\n  local:  {s}\n  daemon: {s}\n", .{ step, local.stdout, served.stdout });
                return error.DaemonDisagrees;
            }
        }
    }

    /// Whether `buta daemon status` reports a running daemon.
    fn running(h: *Harness) !bool {
        const r = try h.run(&.{ try butaPath(), "daemon", "status" }, "", true);
        defer r.deinit();
        return r.code == 0;
    }

    fn waitUntil(h: *Harness, want_running: bool) !void {
        for (0..300) |_| {
            if (try h.running() == want_running) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.Timeout;
    }

    fn stats(h: *Harness) !struct { hits: u64, misses: u64 } {
        const r = try h.run(&.{ try butaPath(), "daemon", "status" }, "", true);
        defer r.deinit();
        return .{ .hits = try field(r.stdout, "hits:"), .misses = try field(r.stdout, "misses:") };
    }
};

fn field(text: []const u8, name: []const u8) !u64 {
    const at = std.mem.indexOf(u8, text, name) orelse return error.MissingField;
    var it = std.mem.tokenizeAny(u8, text[at + name.len ..], " \n");
    return std.fmt.parseInt(u64, it.next() orelse return error.MissingField, 10);
}

test "the daemon's answers always match a local computation" {
    if (!haveGit()) return error.SkipZigTest;
    var h = try Harness.init();
    defer h.deinit();
    try h.start();

    try h.tmp.dir.createDirPath(io, "r");
    try h.git("r", &.{ "init", "-q", "-b", "main" });
    try h.check("r", "init");
    try h.write("r/a.txt", "one\n");
    try h.write("r/dir/b.txt", "two\n");
    try h.write("r/deep/x/y/z.txt", "three\n");
    try h.check("r", "write untracked files");
    try h.git("r", &.{ "add", "." });
    try h.check("r", "add");
    try h.git("r", &.{ "commit", "-q", "-m", "first" });
    try h.check("r", "commit");
    try h.check("r/deep/x", "subdirectory");

    try h.write("r/a.txt", "one more\n");
    try h.check("r", "modify");
    try h.write("r/deep/x/y/z.txt", "THREE\n");
    try h.check("r", "modify deep (same size)");
    try h.git("r", &.{ "add", "a.txt" });
    try h.check("r", "stage");
    try h.git("r", &.{ "commit", "-q", "-m", "second" });
    try h.check("r", "commit again");

    // A directory that didn't exist when the watches were set up.
    try h.write("r/new/c.txt", "four\n");
    try h.git("r", &.{ "add", "new/c.txt" });
    try h.check("r", "add in a new directory");
    try h.write("r/new/c.txt", "five\n");
    try h.check("r", "modify in the new directory");
    try h.git("r", &.{ "commit", "-q", "-am", "third" });
    try h.check("r", "commit -a");

    try h.tmp.dir.deleteFile(io, "r/dir/b.txt");
    try h.check("r", "delete a file");
    try h.tmp.dir.deleteTree(io, "r/deep");
    try h.check("r", "delete a tree");
    try h.git("r", &.{ "checkout", "-q", "--", "." });
    try h.check("r", "restore");
    // deep/ and deep/x/ hold no files of their own; only their watches see this.
    try h.tmp.dir.rename("r/deep/x", h.tmp.dir, "moved", io);
    try h.check("r", "move an intermediate directory away");
    try h.tmp.dir.rename("moved", h.tmp.dir, "r/deep/x", io);
    try h.check("r", "move it back");

    const file = try h.tmp.dir.openFile(io, "r/a.txt", .{});
    try file.setPermissions(io, .fromMode(0o755));
    file.close(io);
    try h.check("r", "chmod +x");
    try h.git("r", &.{ "checkout", "-q", "--", "a.txt" });
    try h.check("r", "undo chmod");

    try h.write("r/a.txt", "stash me\n");
    try h.git("r", &.{ "stash", "-q" });
    try h.check("r", "stash");
    try h.git("r", &.{ "stash", "pop", "-q" });
    try h.check("r", "stash pop");
    try h.git("r", &.{ "checkout", "-q", "--", "a.txt" });

    try h.git("r", &.{ "checkout", "-q", "-b", "topic/x" });
    try h.check("r", "new branch in a new refs/ directory");
    try h.git("r", &.{ "checkout", "-q", "--detach" });
    try h.check("r", "detach");
    try h.git("r", &.{ "checkout", "-q", "main" });
    try h.check("r", "back to main");

    // Upstream tracking (a local branch as upstream): ahead, then in sync.
    try h.git("r", &.{ "branch", "-q", "base" });
    try h.git("r", &.{ "branch", "-q", "-u", "base" });
    try h.check("r", "set upstream");
    try h.write("r/a.txt", "ahead\n");
    try h.git("r", &.{ "commit", "-q", "-am", "ahead" });
    try h.check("r", "ahead");
    try h.git("r", &.{ "update-ref", "refs/heads/base", "HEAD" });
    try h.check("r", "upstream moved");
    try h.git("r", &.{ "pack-refs", "--all" });
    try h.check("r", "pack-refs");
    try h.git("r", &.{ "reset", "-q", "--soft", "HEAD~1" });
    try h.check("r", "reset --soft");
    try h.git("r", &.{ "reset", "-q", "--hard" });
    try h.check("r", "reset --hard");

    // Linked worktree: shares refs and config with the main repository.
    try h.git("r", &.{ "worktree", "add", "-q", "../wt", "-b", "wt" });
    try h.check("wt", "worktree");
    try h.write("wt/a.txt", "in the worktree\n");
    try h.check("wt", "modify in the worktree");
    try h.check("r", "main repository unaffected");

    // Rapid same-size rewrites: every one must be seen.
    for (0..20) |i| {
        try h.write("r/a.txt", if (i % 2 == 0) "aaaa\n" else "bbbb\n");
        try h.check("r", "rapid rewrite");
    }

    try h.check("", "not a repository");

    const s = try h.stats();
    try testing.expect(s.hits > 0);
    try testing.expect(s.misses > 0);
}

test "untracked files and ignore rules: the daemon sees every change" {
    if (!haveGit()) return error.SkipZigTest;
    var h = try Harness.init();
    defer h.deinit();
    try h.start();

    try h.tmp.dir.createDirPath(io, "r");
    try h.git("r", &.{ "init", "-q", "-b", "main" });
    try h.write("r/.gitignore", "*.o\nbuild/\n");
    try h.write("r/src/a.c", "a\n");
    try h.git("r", &.{ "add", "." });
    try h.git("r", &.{ "commit", "-qm", "base" });
    try h.check("r", "clean");

    try h.write("r/new.txt", "x\n");
    try h.check("r", "untracked file");
    try h.write("r/src/a.o", "x\n");
    try h.check("r", "ignored file");
    try h.write("r/build/out/x.bin", "x\n");
    try h.check("r", "file in an ignored directory");
    try h.tmp.dir.createDirPath(io, "r/u/v/w");
    try h.check("r", "empty untracked directories");
    try h.write("r/u/v/w/deep.txt", "x\n");
    try h.check("r", "file deep in a new untracked directory");
    try h.tmp.dir.deleteFile(io, "r/u/v/w/deep.txt");
    try h.check("r", "and deleted again");

    // Changing the rules changes what is ignored, and what is watched.
    try h.write("r/.gitignore", "*.o\n");
    try h.check("r", "un-ignore build/");
    // Normal mode counts build/ once, so only emptying it changes the count.
    try h.tmp.dir.deleteFile(io, "r/build/out/x.bin");
    try h.check("r", "empty the formerly ignored directory");
    try h.write("r/build/out/y.bin", "y\n");
    try h.check("r", "write in it again");
    try h.write("r/.gitignore", "*.o\nbuild/\nnew.txt\n");
    try h.check("r", "ignore again");
    try h.write("r/src/.gitignore", "!a.o\n");
    try h.check("r", "a nested .gitignore");
    try h.write("r/.git/info/exclude", "u/\n");
    try h.check("r", "info/exclude");
    try h.git("r", &.{ "config", "status.showUntrackedFiles", "all" });
    try h.check("r", "showUntrackedFiles=all");

    // The global excludes file ($HOME/.config/git/ignore; HOME is the
    // harness root), created where not even its directory existed.
    // It hides the untracked src/.gitignore, then lets it show again.
    const before = try h.prompt("r", false);
    defer before.deinit();
    try h.write(".config/git/ignore", ".gitignore\n");
    try h.check("r", "global excludes file created");
    const after = try h.prompt("r", false);
    defer after.deinit();
    try testing.expect(!std.mem.eql(u8, before.stdout, after.stdout)); // the step matters
    try h.write(".config/git/ignore", "*.bin\n");
    try h.check("r", "global excludes file changed");
}

test "without a daemon, and after it stops, prompts are computed locally" {
    if (!haveGit()) return error.SkipZigTest;
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.createDirPath(io, "r");
    try h.git("r", &.{ "init", "-q", "-b", "solo" });
    try h.check("r", "no daemon");
    try h.start();
    try h.check("r", "daemon");
    h.stop();
    try h.check("r", "stopped daemon");
}

test "a second daemon on the same socket refuses to start" {
    var h = try Harness.init();
    defer h.deinit();
    try h.start();
    const r = try h.run(&.{ try butaPath(), "daemon" }, "", true);
    defer r.deinit();
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "already running") != null);

    // Once `stop` returns, a new daemon can start at once.
    h.stop();
    try h.start();
}

test "the daemon hangs up on a client from another build" {
    var h = try Harness.init();
    defer h.deinit();
    try h.start();
    try testing.expect(try sendForeignHello(h.socket));
    try testing.expect(try h.running()); // its executable is unchanged: it stays
}

/// Right magic, wrong fingerprint. True if the daemon closed without answering.
fn sendForeignHello(path: []const u8) !bool {
    const fd = try connectTo(path);
    defer sys.close(fd);
    const hello = "BUTA" ++ "\x00" ** 8 ++ "\x01\x00\x00\x00" ++ "\x00";
    if (!sys.writeAll(fd, hello)) return error.Write;
    var buf: [16]u8 = undefined;
    // No answer: EOF, or a reset because the daemon closed with our bytes unread.
    const n = sys.read(fd, &buf) catch return true;
    return n == 0;
}

test "after an upgrade, the old daemon makes way for the new one" {
    var h = try Harness.init();
    defer h.deinit();
    // Run the daemon from a copy, then replace the copy, as an upgrade does.
    const data = try std.Io.Dir.cwd().readFileAlloc(io, try butaPath(), gpa, .unlimited);
    defer gpa.free(data);
    try h.write("old/buta", data);
    try h.write("new/buta", data);
    for ([_][]const u8{ "old/buta", "new/buta" }) |p| {
        const f = try h.tmp.dir.openFile(io, p, .{});
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0o755));
    }
    const old = try std.fs.path.join(gpa, &.{ h.root, "old/buta" });
    defer gpa.free(old);
    try h.startFrom(old);
    try h.tmp.dir.rename("new/buta", h.tmp.dir, "old/buta", io);

    // A client of another build: the replaced daemon exits.
    try testing.expect(try sendForeignHello(h.socket));
    try h.waitUntil(false);
    var child = h.daemon.?;
    h.daemon = null;
    _ = try child.wait(io);
}

test "a prompt starts the daemon when none runs, and doesn't keep retrying" {
    if (!haveGit()) return error.SkipZigTest;
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.createDirPath(io, "r");
    try h.git("r", &.{ "init", "-q", "-b", "main" });
    defer if (h.run(&.{ butaPath() catch unreachable, "daemon", "stop" }, "", true)) |r| r.deinit() else |_| {};

    try testing.expect(!try h.running());
    const first = try h.prompt("r", true); // computed locally; starts the daemon
    first.deinit();
    try h.waitUntil(true);
    try h.check("r", "served by the started daemon");

    // Stopped by hand: the next prompts don't restart it right away.
    const r = try h.run(&.{ try butaPath(), "daemon", "stop" }, "", true);
    r.deinit();
    for (0..3) |_| {
        const p = try h.prompt("r", true);
        p.deinit();
    }
    try io.sleep(.fromMilliseconds(200), .awake);
    try testing.expect(!try h.running());
}

test "with `.daemon = .off` the prompt never asks or starts one" {
    var h = try Harness.init();
    defer h.deinit();
    try h.write("c.zon", ".{ .glyphs = .ascii, .order = .{ .git_branch }, .daemon = .off }");
    const p = try h.prompt("", true);
    p.deinit();
    try io.sleep(.fromMilliseconds(200), .awake);
    try testing.expect(!try h.running());
}

test "a daemon that never answers costs at most the deadline" {
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.createDirPath(io, "r/.git");
    try h.write("r/.git/HEAD", "ref: refs/heads/main\n");
    try h.write("c.zon", ".{ .glyphs = .ascii, .order = .{ .dir, .git_branch, .git_status }, .timeout_ms = 80 }");

    // Listens, but never accepts: connecting and sending still succeed.
    const fd = try sys.socket(false);
    defer sys.close(fd);
    try sys.listen(fd, h.socket);

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const r = try h.run(&.{ try butaPath(), "prompt" }, "r", true);
    defer r.deinit();
    const took_ms = @divTrunc(t0.untilNow(io).raw.nanoseconds, std.time.ns_per_ms);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "r") != null); // dir still shown
    try testing.expect(std.mem.indexOf(u8, r.stdout, "git:") == null); // git modules left out
    if (took_ms < 80 or took_ms > 80 + 400) {
        std.debug.print("deadline 80 ms, took {d} ms\n", .{took_ms});
        return error.TestUnexpectedResult;
    }
}

fn connectTo(path: []const u8) !i32 {
    const fd = try sys.socket(false);
    errdefer sys.close(fd);
    try sys.connect(fd, path);
    return fd;
}

/// The test runner's $PATH, for finding git and the shells.
fn testPath() []const u8 {
    const S = struct {
        var map: ?std.process.Environ.Map = null;
    };
    if (S.map == null) S.map = testing.environ.createMap(std.heap.page_allocator) catch return "/usr/bin:/bin";
    return S.map.?.get("PATH") orelse "/usr/bin:/bin";
}
