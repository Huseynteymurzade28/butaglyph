//! Checks the git reader against the real `git` CLI. git is only used to
//! build fixture repositories and to produce the expected answers; skipped
//! when git is not installed.

const std = @import("std");
const git = @import("git");
const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena_state: std.heap.ArenaAllocator,
    quiet: bool = false,

    fn init() !Fixture {
        if (!haveGit()) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(io, ".", gpa), .arena_state = .init(gpa) };
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        gpa.free(f.root);
        f.tmp.cleanup();
    }

    fn arena(f: *Fixture) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    fn path(f: *Fixture, sub: []const u8) ![]const u8 {
        return std.fs.path.join(f.arena(), &.{ f.root, sub });
    }

    /// Runs git in `sub` with a hermetic environment; returns stdout.
    fn run(f: *Fixture, sub: []const u8, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(f.arena(), "git");
        try argv.appendSlice(f.arena(), args);
        var env: std.process.Environ.Map = .init(f.arena());
        try env.put("PATH", testing.environ.getPosix("PATH") orelse "/usr/bin:/bin");
        try env.put("HOME", f.root);
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try env.put("GIT_AUTHOR_NAME", "T");
        try env.put("GIT_AUTHOR_EMAIL", "t@example.com");
        try env.put("GIT_COMMITTER_NAME", "T");
        try env.put("GIT_COMMITTER_EMAIL", "t@example.com");
        try env.put("GIT_TICK", "1");
        const r = try std.process.run(f.arena(), io, .{
            .argv = argv.items,
            .cwd = .{ .path = try f.path(sub) },
            .environ_map = &env,
        });
        if (r.term != .exited or r.term.exited != 0) {
            if (f.quiet) return error.GitFailed;
            std.debug.print("git {s} failed:\n{s}\n", .{ args[0], r.stderr });
            return error.GitFailed;
        }
        return r.stdout;
    }

    fn runAllowFail(f: *Fixture, sub: []const u8, args: []const []const u8) !void {
        f.quiet = true;
        defer f.quiet = false;
        _ = f.run(sub, args) catch {};
    }

    fn write(f: *Fixture, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |d| try f.tmp.dir.createDirPath(io, d);
        try f.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn ours(f: *Fixture, sub: []const u8) !git.Status {
        const repo = (try git.repo.discover(io, f.arena(), try f.path(sub))).?;
        return git.status.compute(io, f.arena(), repo, .{});
    }

    /// git's view, from porcelain v2 (no renames, no untracked files).
    fn theirs(f: *Fixture, sub: []const u8) !git.Status {
        const out = try f.run(sub, &.{ "--no-optional-locks", "status", "--porcelain=v2", "--branch", "--no-renames", "--untracked-files=no" });
        var st: git.Status = .{};
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "# branch.ab ")) {
                var it = std.mem.tokenizeScalar(u8, line["# branch.ab ".len..], ' ');
                st.ahead = try std.fmt.parseInt(u32, it.next().?[1..], 10);
                st.behind = try std.fmt.parseInt(u32, it.next().?[1..], 10);
            } else if (std.mem.startsWith(u8, line, "1 ")) {
                const x = line[2];
                const y = line[3];
                if (x != '.') st.staged += 1;
                switch (y) {
                    'M', 'T', 'A' => st.modified += 1,
                    'D' => st.deleted += 1,
                    else => {},
                }
            } else if (std.mem.startsWith(u8, line, "u ")) {
                st.conflicted += 1;
            }
        }
        return st;
    }

    fn expectSame(f: *Fixture, sub: []const u8, label: []const u8) !void {
        const a = try f.ours(sub); // first: git status may refresh the index
        const b = try f.theirs(sub);
        if (!std.meta.eql(a, b)) {
            std.debug.print("[{s}] ours:   {any}\n[{s}] theirs: {any}\n", .{ label, a, label, b });
            return error.StatusMismatch;
        }
    }
};

fn haveGit() bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "git", "--version" } }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

/// A repo with enough similar content for git to build long delta chains.
fn buildHistory(f: *Fixture) !void {
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
    var content: std.ArrayList(u8) = .empty;
    for (0..40) |i| {
        try content.print(f.arena(), "line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
        try f.write("r/big.txt", content.items);
        try f.write("r/src/a.zig", try std.fmt.allocPrint(f.arena(), "const v = {d};\n{s}", .{ i, content.items[0..@min(content.items.len, 500)] }));
        if (i % 5 == 0) try f.write(try std.fmt.allocPrint(f.arena(), "r/dir{d}/n.txt", .{i}), "x\n");
        _ = try f.run("r", &.{ "add", "-A" });
        _ = try f.run("r", &.{ "commit", "-q", "-m", try std.fmt.allocPrint(f.arena(), "c{d}", .{i}) });
    }
}

const Verified = struct { objects: usize, ofs_deltas: u32, ref_deltas: u32 };

fn verifyAllObjects(f: *Fixture, label: []const u8) !Verified {
    const repo = (try git.repo.discover(io, f.arena(), try f.path("r"))).?;
    var db = try git.odb.Odb.open(io, f.arena(), try std.fmt.allocPrint(f.arena(), "{s}/objects", .{repo.common_dir}));
    const list = try f.run("r", &.{ "rev-list", "--objects", "--all" });
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const oid = try git.Oid.parseHex(line[0..40]);
        const obj = db.read(oid) catch |err| {
            std.debug.print("[{s}] {s}: {s}\n", .{ label, line[0..40], @errorName(err) });
            return err;
        };
        if (!git.Oid.hashObject(obj.kind.name(), obj.data).eql(oid)) {
            std.debug.print("[{s}] {s}: content hashes to a different id\n", .{ label, line[0..40] });
            return error.HashMismatch;
        }
        n += 1;
    }
    return .{ .objects = n, .ofs_deltas = db.stats.ofs_deltas, .ref_deltas = db.stats.ref_deltas };
}

fn deltaCount(f: *Fixture) !usize {
    const repo_objects = try f.path("r/.git/objects/pack");
    var dir = try std.Io.Dir.cwd().openDir(io, repo_objects, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var deltas: usize = 0;
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".idx")) continue;
        const out = try f.run("r", &.{ "verify-pack", "-v", try std.fs.path.join(f.arena(), &.{ repo_objects, e.name }) });
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            // "<oid> <type> <size> <packed> <offset> <depth> <base>" for deltified objects
            var tok = std.mem.tokenizeScalar(u8, line, ' ');
            var count: usize = 0;
            while (tok.next()) |_| count += 1;
            if (count == 7) deltas += 1;
        }
    }
    return deltas;
}

test "every object reads back and hashes to its id: loose, OFS_DELTA and REF_DELTA packs" {
    var f = try Fixture.init();
    defer f.deinit();
    try buildHistory(&f);

    const loose = try verifyAllObjects(&f, "loose");
    try testing.expect(loose.objects > 100);
    try testing.expectEqual(@as(u32, 0), loose.ofs_deltas + loose.ref_deltas);

    _ = try f.run("r", &.{ "repack", "-adfq", "--depth=50", "--window=50" });
    try testing.expect(try deltaCount(&f) > 20);
    const ofs = try verifyAllObjects(&f, "ofs-delta pack");
    try testing.expectEqual(loose.objects, ofs.objects);
    try testing.expect(ofs.ofs_deltas > 20 and ofs.ref_deltas == 0);

    _ = try f.run("r", &.{ "-c", "repack.useDeltaBaseOffset=false", "repack", "-adfq", "--depth=50", "--window=50" });
    const ref = try verifyAllObjects(&f, "ref-delta pack");
    try testing.expectEqual(loose.objects, ref.objects);
    try testing.expect(ref.ref_deltas > 20 and ref.ofs_deltas == 0);

    // Mixed: packed history plus fresh loose objects.
    try f.write("r/new.txt", "fresh\n");
    _ = try f.run("r", &.{ "add", "new.txt" });
    _ = try f.run("r", &.{ "commit", "-qm", "loose on top" });
    try testing.expectEqual(loose.objects + 3, (try verifyAllObjects(&f, "mixed")).objects);
}

test "worktree and index status matches git" {
    var f = try Fixture.init();
    defer f.deinit();
    try buildHistory(&f);
    try f.expectSame("r", "clean");

    try f.write("r/big.txt", "shorter now\n");
    try f.expectSame("r", "modified (size)");

    _ = try f.run("r", &.{ "checkout", "-q", "--", "big.txt" });
    try f.expectSame("r", "restored");
    const a = try f.tmp.dir.readFileAlloc(io, "r/src/a.zig", f.arena(), .unlimited);
    const same_size = try f.arena().dupe(u8, a);
    same_size[6] = 'w'; // "const v" -> "const w": same length, different content
    try f.write("r/src/a.zig", same_size);
    try f.expectSame("r", "modified (same size)");

    try f.write("r/src/a.zig", a); // same content, new mtime
    try f.expectSame("r", "touched");

    try f.tmp.dir.deleteFile(io, "r/dir5/n.txt");
    try f.expectSame("r", "deleted");

    _ = try f.run("r", &.{ "update-index", "--chmod=+x", "dir10/n.txt" });
    try f.expectSame("r", "mode staged, worktree differs");

    try f.write("r/added.txt", "new\n");
    _ = try f.run("r", &.{ "add", "added.txt" });
    _ = try f.run("r", &.{ "rm", "-q", "dir15/n.txt" });
    try f.write("r/big.txt", "staged change\n");
    _ = try f.run("r", &.{ "add", "big.txt" });
    try f.write("r/big.txt", "staged change, then modified again\n");
    try f.expectSame("r", "staged + modified");

    try f.tmp.dir.deleteFile(io, "r/dir20/n.txt");
    try f.tmp.dir.symLink(io, "../big.txt", "r/dir20/n.txt", .{});
    try f.expectSame("r", "file became symlink");

    try f.write("r/ita.txt", "intent\n");
    _ = try f.run("r", &.{ "add", "-N", "ita.txt" });
    try f.expectSame("r", "intent to add");

    _ = try f.run("r", &.{ "update-index", "--index-version", "4" });
    try f.expectSame("r", "index v4");

    try f.expectSame("r/src", "from a subdirectory");

    _ = try f.run("r", &.{ "add", "-A" });
    _ = try f.run("r", &.{ "commit", "-qm", "everything" });
    try f.expectSame("r", "clean again (cache tree)");
}

test "merge conflicts" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
    try f.write("r/x.txt", "base\n");
    try f.write("r/y.txt", "same\n");
    _ = try f.run("r", &.{ "add", "-A" });
    _ = try f.run("r", &.{ "commit", "-qm", "base" });
    _ = try f.run("r", &.{ "checkout", "-qb", "other" });
    try f.write("r/x.txt", "other\n");
    _ = try f.run("r", &.{ "commit", "-qam", "other" });
    _ = try f.run("r", &.{ "checkout", "-q", "main" });
    try f.write("r/x.txt", "main\n");
    try f.write("r/y.txt", "changed on main\n");
    _ = try f.run("r", &.{ "commit", "-qam", "main" });
    _ = f.runAllowFail("r", &.{ "merge", "-q", "other" }) catch {}; // conflicts, exits 1
    try f.expectSame("r", "conflict");
    try testing.expectEqual(@as(u32, 1), (try f.ours("r")).conflicted);
}

test "ahead/behind against an upstream (clone with packed-refs, and a local branch)" {
    var f = try Fixture.init();
    defer f.deinit();
    try buildHistory(&f);
    _ = try f.run("", &.{ "clone", "-q", "r", "c" });
    try f.expectSame("c", "fresh clone");

    // Two local commits, three upstream commits.
    for (0..2) |i| {
        try f.write("c/local.txt", try std.fmt.allocPrint(f.arena(), "{d}\n", .{i}));
        _ = try f.run("c", &.{ "add", "local.txt" });
        _ = try f.run("c", &.{ "commit", "-qm", "local" });
    }
    for (0..3) |i| {
        try f.write("r/remote.txt", try std.fmt.allocPrint(f.arena(), "{d}\n", .{i}));
        _ = try f.run("r", &.{ "add", "remote.txt" });
        _ = try f.run("r", &.{ "commit", "-qm", "remote" });
    }
    _ = try f.run("c", &.{ "fetch", "-q" });
    try f.expectSame("c", "diverged");
    const st = try f.ours("c");
    try testing.expectEqual(@as(?u32, 2), st.ahead);
    try testing.expectEqual(@as(?u32, 3), st.behind);

    _ = try f.run("c", &.{ "pack-refs", "--all" });
    _ = try f.run("c", &.{ "gc", "-q" });
    try f.expectSame("c", "after gc (packed refs and objects)");

    // Upstream is a local branch (remote = ".").
    _ = try f.run("r", &.{ "branch", "base", "HEAD~4" });
    _ = try f.run("r", &.{ "branch", "-q", "--set-upstream-to=base" });
    try f.expectSame("r", "local upstream");
    try testing.expectEqual(@as(?u32, 4), (try f.ours("r")).ahead);
}

test "linked worktree and unborn branch" {
    var f = try Fixture.init();
    defer f.deinit();
    try buildHistory(&f);
    _ = try f.run("r", &.{ "worktree", "add", "-q", "-b", "wt", "../w" });
    try f.write("w/big.txt", "changed in the worktree\n");
    try f.write("w/src/new.zig", "x");
    _ = try f.run("w", &.{ "add", "src/new.zig" });
    try f.expectSame("w", "linked worktree");
    try f.expectSame("r", "main worktree unaffected");

    _ = try f.run("", &.{ "init", "-q", "-b", "fresh", "u" });
    try f.write("u/a.txt", "a\n");
    try f.write("u/b/c.txt", "c\n");
    _ = try f.run("u", &.{ "add", "-A" });
    try f.expectSame("u", "unborn branch with staged files");
}

test "large index (parallel worktree check) matches git" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
    for (0..3000) |i| {
        try f.write(try std.fmt.allocPrint(f.arena(), "r/d{d}/f{d}.txt", .{ i % 37, i }), try std.fmt.allocPrint(f.arena(), "file {d}\n", .{i}));
    }
    _ = try f.run("r", &.{ "add", "-A" });
    _ = try f.run("r", &.{ "commit", "-qm", "many" });
    try f.expectSame("r", "large clean");

    // Changes spread over every chunk: different size, same size, deletions.
    for (0..3000) |i| {
        const p = try std.fmt.allocPrint(f.arena(), "r/d{d}/f{d}.txt", .{ i % 37, i });
        if (i % 97 == 0) try f.write(p, "changed and longer\n");
        if (i % 89 == 1) try f.write(p, try std.fmt.allocPrint(f.arena(), "fIle {d}\n", .{i}));
        if (i % 101 == 2) try f.tmp.dir.deleteFile(io, p);
    }
    try f.expectSame("r", "large with changes");
    const st = try f.ours("r");
    try testing.expect(st.modified > 50 and st.deleted > 20);
}
