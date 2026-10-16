//! Daemon tests: run the real `buta daemon` and check every prompt it
//! serves against what `buta prompt` computes on its own, across a long
//! sequence of git operations. The daemon may only ever be faster, never
//! different. Linux only; the git-driven tests are skipped without git.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const testing = std.testing;
const linux = std.os.linux;
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
        if (builtin.os.tag != .linux) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(root);
        const socket = try std.fs.path.join(gpa, &.{ root, "d.sock" });
        errdefer gpa.free(socket);
        if (socket.len >= 108) return error.SkipZigTest; // sun_path limit
        try tmp.dir.writeFile(io, .{ .sub_path = "c.zon", .data = config });
        return .{ .tmp = tmp, .root = root, .socket = socket, .config = try std.fs.path.join(gpa, &.{ root, "c.zon" }) };
    }

    fn deinit(h: *Harness) void {
        h.stop();
        gpa.free(h.config);
        gpa.free(h.socket);
        gpa.free(h.root);
        h.tmp.cleanup();
    }

    fn env(h: *Harness, map: *std.process.Environ.Map, use_daemon: bool) !void {
        try map.put("PATH", testing.environ.getPosix("PATH") orelse "/usr/bin:/bin");
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
        var map: std.process.Environ.Map = .init(gpa);
        defer map.deinit();
        try h.env(&map, true);
        h.daemon = try std.process.spawn(io, .{
            .argv = &.{ try butaPath(), "daemon" },
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
    const fd = try connectTo(h.socket);
    defer _ = linux.close(fd);
    // Right magic, wrong fingerprint.
    const hello = "BUTA" ++ "\x00" ** 8 ++ "\x01\x00\x00\x00" ++ "\x00";
    try testing.expectEqual(hello.len, linux.write(fd, hello, hello.len));
    var buf: [16]u8 = undefined;
    // No answer: EOF, or a reset because the daemon closed with our bytes unread.
    const rc = linux.read(fd, &buf, buf.len);
    try testing.expect(rc == 0 or linux.errno(rc) == .CONNRESET);
}

test "a daemon that never answers costs at most the deadline" {
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.createDirPath(io, "r/.git");
    try h.write("r/.git/HEAD", "ref: refs/heads/main\n");
    try h.write("c.zon", ".{ .glyphs = .ascii, .order = .{ .dir, .git_branch, .git_status }, .timeout_ms = 80 }");

    // Listens, but never accepts: connecting and sending still succeed.
    const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    defer _ = linux.close(@intCast(fd));
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..h.socket.len], h.socket);
    try testing.expectEqual(@as(usize, 0), linux.bind(@intCast(fd), @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    try testing.expectEqual(@as(usize, 0), linux.listen(@intCast(fd), 8));

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
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(rc);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.Connect;
    return fd;
}
