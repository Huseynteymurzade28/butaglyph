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
    /// A system config file, for git ($GIT_CONFIG_SYSTEM) and for us.
    system: ?[]const u8 = null,

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
        try env.put("PATH", testPath());
        try env.put("HOME", f.root);
        if (f.system) |p| try env.put("GIT_CONFIG_SYSTEM", p) else try env.put("GIT_CONFIG_NOSYSTEM", "1");
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
        // The same global files git sees: none but the fixture's own.
        return git.status.compute(io, f.arena(), repo, .{ .global = .{ .home = f.root, .config_global = "/dev/null", .system = f.system } });
    }

    /// git's view, from porcelain v2 (renames and untracked files as the
    /// repository's config says).
    fn theirs(f: *Fixture, sub: []const u8) !git.Status {
        const out = try f.run(sub, &.{ "--no-optional-locks", "status", "--porcelain=v2", "--branch" });
        var st: git.Status = .{};
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "# branch.ab ")) {
                var it = std.mem.tokenizeScalar(u8, line["# branch.ab ".len..], ' ');
                st.ahead = try std.fmt.parseInt(u32, it.next().?[1..], 10);
                st.behind = try std.fmt.parseInt(u32, it.next().?[1..], 10);
            } else if (std.mem.startsWith(u8, line, "1 ") or std.mem.startsWith(u8, line, "2 ")) {
                const x = line[2];
                const y = line[3];
                if (x == 'R') {
                    st.renamed += 1;
                } else if (x != '.') st.staged += 1;
                switch (y) {
                    'M', 'T', 'A' => st.modified += 1,
                    'D' => st.deleted += 1,
                    else => {},
                }
            } else if (std.mem.startsWith(u8, line, "u ")) {
                st.conflicted += 1;
            } else if (std.mem.startsWith(u8, line, "? ")) {
                st.untracked += 1;
            }
        }
        return st;
    }

    fn expectSame(f: *Fixture, sub: []const u8, label: []const u8) !void {
        const a = try f.ours(sub); // first: git status may refresh the index
        const b = try f.theirs(sub);
        if (!std.meta.eql(a, b)) {
            std.debug.print("[{s}] ours:   {any}\n[{s}] theirs: {any}\n", .{ label, a, label, b });
            const raw = f.run(sub, &.{ "status", "--porcelain=v2" }) catch "";
            const files = f.run(sub, &.{ "ls-files", "-s" }) catch "";
            std.debug.print("git status:\n{s}git ls-files -s:\n{s}\n", .{ raw, files });
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
    // No automatic gc or maintenance: the tests decide when to pack.
    _ = try f.run("r", &.{ "config", "gc.auto", "0" });
    _ = try f.run("r", &.{ "config", "maintenance.auto", "false" });
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
    defer db.close();
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

test "untracked files and .gitignore rules match git" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
    try f.write("r/tracked.txt", "t\n");
    try f.write("r/src/main.c", "int main;\n");
    try f.write("r/src/lib/util.c", "u\n");
    try f.write("r/build/keep.txt", "force-added\n");
    try f.write("r/.gitignore",
        \\# build output
        \\*.o
        \\/build/
        \\logs/
        \\!logs/important.log
        \\doc/**/*.tmp
        \\**/cache
        \\/anchored.txt
        \\trailing\\ 
        \\[Tt]emp*
        \\
    );
    try f.write("r/src/.gitignore", "*.gen\n!keep.gen\nlib/*.c\n");
    _ = try f.run("r", &.{ "add", ".gitignore", "src/.gitignore", "tracked.txt", "src/main.c" });
    _ = try f.run("r", &.{ "add", "-f", "build/keep.txt", "src/lib/util.c" });
    _ = try f.run("r", &.{ "commit", "-qm", "base" });
    try f.expectSame("r", "clean");

    const files = [_][]const u8{
        "r/new.txt", // untracked
        "r/a.o", "r/src/b.o", // ignored by *.o
        "r/build/out.bin", // inside an ignored directory with a tracked file
        "r/logs/x.log",    "r/logs/important.log", // can't re-include below an ignored dir
        "r/doc/a/b/c.tmp", "r/doc/x.tmp",
        "r/doc/readme.md",
        "r/deep/er/cache/f", "r/cache/g", // **/cache
        "r/anchored.txt",    "r/sub/anchored.txt",
        "r/trailing ",       "r/Temporary",
        "r/temp.txt",        "r/xtemp",
        "r/src/x.gen",       "r/src/keep.gen",
        "r/src/lib/new.c",   "r/src/lib/new.h",
        "r/untracked-dir/a/b/c.txt", // collapses to one entry
        "r/only-ignored/z.o", // holds nothing countable
        "r/src/newdir/f.txt",
    };
    for (files) |p| try f.write(p, "x\n");
    try f.tmp.dir.createDirPath(io, "r/empty/inner"); // empty directories don't count
    try f.expectSame("r", "gitignore rules");
    try f.expectSame("r/src", "from a subdirectory");

    // A nested repository counts once, and is not looked into.
    _ = try f.run("", &.{ "init", "-q", "r/nested" });
    try f.write("r/nested/inside.txt", "x\n");
    try f.expectSame("r", "nested repository");

    // Repository-wide rules: info/exclude and core.excludesFile.
    try f.write("r/.git/info/exclude", "new.txt\n");
    try f.write("r/global-ignore", "*.md\n");
    _ = try f.run("r", &.{ "config", "core.excludesFile", try f.path("r/global-ignore") });
    try f.expectSame("r", "info/exclude and core.excludesFile");

    _ = try f.run("r", &.{ "config", "status.showUntrackedFiles", "all" });
    try f.expectSame("r", "showUntrackedFiles=all");
    _ = try f.run("r", &.{ "config", "status.showUntrackedFiles", "no" });
    try f.expectSame("r", "showUntrackedFiles=no");
    try testing.expectEqual(@as(u32, 0), (try f.ours("r")).untracked);
}

test "untracked files: random trees and rules match git" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
    var prng: std.Random.DefaultPrng = .init(0x6275746167);
    const rand = prng.random();
    const names = [_][]const u8{ "a", "b", "ab", "a.c", "b.o", "x.log", "doc", "Temp", "cache", "z-1" };
    const patterns = [_][]const u8{ "*.o", "a", "/a", "a/", "!b", "**/doc", "doc/**", "*/b", "[ab]", "!*.c", "x*", "/doc/a", "cache/", "**/a/**", "?", "!ab", "*", "!a/" };

    for (0..12) |round| {
        // A fresh random tree: some files tracked, the rest left untracked.
        try f.tmp.dir.deleteTree(io, "r");
        _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
        for (0..40) |_| {
            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(f.arena(), "r");
            const depth = rand.intRangeAtMost(usize, 1, 4);
            for (0..depth) |_| {
                try path.append(f.arena(), '/');
                try path.appendSlice(f.arena(), names[rand.uintLessThan(usize, names.len)]);
            }
            try path.appendSlice(f.arena(), ".f");
            f.write(path.items, "x\n") catch continue; // a file where a directory is needed
        }
        for (0..3) |_| {
            var rules: std.ArrayList(u8) = .empty;
            for (0..rand.intRangeAtMost(usize, 1, 5)) |_| {
                try rules.appendSlice(f.arena(), patterns[rand.uintLessThan(usize, patterns.len)]);
                try rules.append(f.arena(), '\n');
            }
            const where = [_][]const u8{ "r/.gitignore", "r/a/.gitignore", "r/doc/.gitignore", "r/b/a/.gitignore" };
            f.write(where[rand.uintLessThan(usize, where.len)], rules.items) catch {};
        }
        _ = f.runAllowFail("r", &.{ "add", "--", "a" }) catch {};
        const label = try std.fmt.allocPrint(f.arena(), "random tree {d}", .{round});
        try f.expectSame("r", label);
        _ = try f.run("r", &.{ "config", "status.showUntrackedFiles", "all" });
        try f.expectSame("r", label);
    }
}

test "config includes and the system config match git" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
    try f.write("r/tracked.txt", "t\n");
    _ = try f.run("r", &.{ "add", "-A" });
    _ = try f.run("r", &.{ "commit", "-qm", "base" });
    try f.write("r/new/a.txt", "x\n");
    try f.write("r/new/b.md", "x\n");
    try f.write("r/c.md", "x\n");
    try f.expectSame("r", "no includes");
    const base = try f.ours("r");

    // A plain include, relative to the including file; later settings win.
    try f.write("r/.git/no.inc", "[status]\n\tshowUntrackedFiles = no\n");
    try f.write("r/.git/all.inc", "[status]\n\tshowUntrackedFiles = all\n");
    const config = try f.tmp.dir.readFileAlloc(io, "r/.git/config", f.arena(), .unlimited);
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ config, "[include]\n\tpath = no.inc\n" }));
    try f.expectSame("r", "include");
    try testing.expectEqual(@as(u32, 0), (try f.ours("r")).untracked);
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ config, "[include]\n\tpath = no.inc\n[status]\n\tshowUntrackedFiles = all\n" }));
    try f.expectSame("r", "set after the include");
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ config, "[status]\n\tshowUntrackedFiles = all\n[include]\n\tpath = no.inc\n" }));
    try f.expectSame("r", "set before the include");
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ config, "[include]\n\tpath = missing.inc\n\tpath = all.inc\n" }));
    try f.expectSame("r", "missing include, then another");
    try testing.expect((try f.ours("r")).untracked > base.untracked);

    // Nested, through ~/.
    try f.write("home.inc", "[include]\n\tpath = .git/no.inc\n");
    try f.write("r/.git/nest.inc", "[include]\n\tpath = ~/home.inc\n");
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "h" }); // for ~/.git/no.inc
    try f.write(".git/no.inc", "[status]\n\tshowUntrackedFiles = no\n");
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ config, "[include]\n\tpath = nest.inc\n" }));
    try f.expectSame("r", "nested via ~/");
    try testing.expectEqual(@as(u32, 0), (try f.ours("r")).untracked);

    // includeIf conditions, each one holding and failing.
    const root_r = try f.path("r");
    const conds = [_][]const u8{
        try std.fmt.allocPrint(f.arena(), "gitdir:{s}/", .{root_r}),
        try std.fmt.allocPrint(f.arena(), "gitdir:{s}/.git", .{root_r}),
        "gitdir:r/",
        "gitdir:other/",
        "gitdir:R/",
        "gitdir/i:R/",
        "gitdir:**/r/.git",
        "gitdir:./",
        "gitdir:~/r/",
        "onbranch:main",
        "onbranch:ma*",
        "onbranch:feature/",
        "onbranch:other",
        "hasconfig:remote.*.url:https://example.com/**",
        "hasconfig:remote.*.url:https://elsewhere/**",
        "nosuchcondition:x",
    };
    try f.write("r/.git/config", config);
    _ = try f.run("r", &.{ "remote", "add", "origin", "https://example.com/r.git" });
    const with_remote = try f.tmp.dir.readFileAlloc(io, "r/.git/config", f.arena(), .unlimited);
    var held: usize = 0;
    for (conds) |c| {
        const inc = try std.fmt.allocPrint(f.arena(), "[includeIf \"{s}\"]\n\tpath = no.inc\n", .{c});
        try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ with_remote, inc }));
        try f.expectSame("r", c);
        if ((try f.ours("r")).untracked == 0) held += 1;
    }
    // Held: both absolute gitdirs, r/, gitdir/i:R/, **/r/.git, ~/r/, main, ma*, example.com.
    try testing.expectEqual(@as(usize, 9), held);
    _ = try f.run("r", &.{ "checkout", "-qb", "feature/x" });
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ with_remote, "[includeIf \"onbranch:feature/\"]\n\tpath = no.inc\n" }));
    try f.expectSame("r", "onbranch: a branch directory");
    try testing.expectEqual(@as(u32, 0), (try f.ours("r")).untracked);

    // A linked worktree has its own git dir.
    _ = try f.run("r", &.{ "worktree", "add", "-q", "-b", "wt", "../w" });
    try f.write("w/u.txt", "x\n");
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ with_remote, "[includeIf \"gitdir:**/worktrees/**\"]\n\tpath = no.inc\n" }));
    try f.expectSame("w", "worktree gitdir");
    try f.expectSame("r", "main gitdir");
    try testing.expectEqual(@as(u32, 0), (try f.ours("w")).untracked);

    // The system config, read first, and its includes.
    try f.write("r/.git/config", with_remote);
    try f.write("sys/gitconfig", "[core]\n\texcludesFile = ~/sys.ignore\n[include]\n\tpath = sys.inc\n");
    try f.write("sys/sys.inc", "[status]\n\tshowUntrackedFiles = all\n");
    try f.write("sys.ignore", "*.md\n");
    f.system = try f.path("sys/gitconfig");
    try f.expectSame("r", "system config");
    try f.write("r/.git/config", try std.mem.concat(f.arena(), u8, &.{ with_remote, "[status]\n\tshowUntrackedFiles = normal\n" }));
    try f.expectSame("r", "repository config over the system's");
}

test "staged renames match git" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
    var text: std.ArrayList(u8) = .empty;
    for (0..30) |i| try text.print(f.arena(), "line {d} of the original file\n", .{i});
    try f.write("r/a.txt", text.items);
    try f.write("r/b.txt", "short\n");
    try f.write("r/empty", "");
    try f.write("r/dir/keep.txt", "keep\n");
    try f.tmp.dir.symLink(io, "a.txt", "r/link", .{});
    _ = try f.run("r", &.{ "add", "-A" });
    _ = try f.run("r", &.{ "commit", "-qm", "base" });

    _ = try f.run("r", &.{ "mv", "b.txt", "dir/b2.txt" });
    try f.expectSame("r", "exact rename");
    try testing.expectEqual(@as(u32, 1), (try f.ours("r")).renamed);

    _ = try f.run("r", &.{ "mv", "a.txt", "moved.txt" });
    const edited = try std.mem.replaceOwned(u8, f.arena(), text.items, "line 3 ", "LINE three ");
    try f.write("r/moved.txt", edited);
    _ = try f.run("r", &.{ "add", "moved.txt" });
    try f.write("r/moved.txt", "and modified in the work tree\n");
    try f.expectSame("r", "edited rename, then modified");

    _ = try f.run("r", &.{ "mv", "empty", "empty2" });
    _ = try f.run("r", &.{ "mv", "link", "link2" });
    try f.expectSame("r", "empty file and symlink");

    _ = try f.run("r", &.{ "config", "status.renameLimit", "1" });
    try f.expectSame("r", "rename limit");
    _ = try f.run("r", &.{ "config", "status.renames", "false" });
    try f.expectSame("r", "renames off");
    try testing.expectEqual(@as(u32, 0), (try f.ours("r")).renamed);
    _ = try f.run("r", &.{ "config", "--unset", "status.renames" });
    _ = try f.run("r", &.{ "config", "diff.renames", "false" });
    try f.expectSame("r", "diff.renames off");
}

test "staged renames: random edits match git" {
    var f = try Fixture.init();
    defer f.deinit();
    var prng: std.Random.DefaultPrng = .init(0x72656e616d65);
    const rand = prng.random();
    const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "x", "", "fn main() {}", "}", "    return 0;", "a much longer line that takes most of a piece on its own" };
    const dirs = [_][]const u8{ "", "src/", "lib/", "src/deep/", "doc/" };
    const bases = [_][]const u8{ "a.c", "b.c", "util.h", "readme", "main.zig", "x.txt", "y.txt" };

    for (0..25) |round| {
        try f.tmp.dir.deleteTree(io, "r");
        _ = try f.run("", &.{ "init", "-q", "-b", "main", "r" });
        // Files of random lines, some sharing content, some with CRLF or NUL.
        var paths: std.ArrayList([]const u8) = .empty;
        var contents: std.ArrayList([]const u8) = .empty;
        for (0..rand.intRangeAtMost(usize, 4, 14)) |_| {
            const p = try std.fmt.allocPrint(f.arena(), "{s}{s}", .{ dirs[rand.uintLessThan(usize, dirs.len)], bases[rand.uintLessThan(usize, bases.len)] });
            var dup = false;
            for (paths.items) |q| dup = dup or std.mem.eql(u8, p, q);
            if (dup) continue;
            var c: std.ArrayList(u8) = .empty;
            if (contents.items.len > 0 and rand.uintLessThan(u8, 6) == 0) {
                try c.appendSlice(f.arena(), contents.items[rand.uintLessThan(usize, contents.items.len)]);
            } else for (0..rand.intRangeAtMost(usize, 0, 40)) |_| {
                try c.appendSlice(f.arena(), words[rand.uintLessThan(usize, words.len)]);
                if (rand.uintLessThan(u8, 10) == 0) try c.append(f.arena(), if (rand.boolean()) '\r' else 0);
                try c.append(f.arena(), '\n');
            }
            f.write(try std.fmt.allocPrint(f.arena(), "r/{s}", .{p}), c.items) catch continue;
            try paths.append(f.arena(), p);
            try contents.append(f.arena(), c.items);
        }
        _ = try f.run("r", &.{ "add", "-A" });
        _ = try f.run("r", &.{ "commit", "-qm", "base" });

        // Delete files, re-add some elsewhere with edits, add new ones.
        for (paths.items, contents.items) |p, c| {
            if (rand.uintLessThan(u8, 3) == 0) continue;
            try f.tmp.dir.deleteFile(io, try std.fmt.allocPrint(f.arena(), "r/{s}", .{p}));
            if (rand.uintLessThan(u8, 4) == 0) continue;
            var lines = std.mem.splitScalar(u8, c, '\n');
            var out: std.ArrayList(u8) = .empty;
            const keep = rand.uintLessThan(u8, 10);
            while (lines.next()) |line| {
                if (rand.uintLessThan(u8, 10) < keep) try out.appendSlice(f.arena(), line) else try out.appendSlice(f.arena(), words[rand.uintLessThan(usize, words.len)]);
                try out.append(f.arena(), '\n');
            }
            const base = std.fs.path.basename(p);
            const name = if (rand.boolean()) base else bases[rand.uintLessThan(usize, bases.len)];
            const np = try std.fmt.allocPrint(f.arena(), "r/new/{s}{d}/{s}", .{ dirs[rand.uintLessThan(usize, dirs.len)], rand.uintLessThan(u8, 3), name });
            f.write(np, out.items) catch {};
        }
        _ = try f.run("r", &.{ "add", "-A" });
        const label = try std.fmt.allocPrint(f.arena(), "random renames {d}", .{round});
        try f.expectSame("r", label);
    }
}

/// The test runner's $PATH, for finding git and the shells.
fn testPath() []const u8 {
    const S = struct {
        var map: ?std.process.Environ.Map = null;
    };
    if (S.map == null) S.map = testing.environ.createMap(std.heap.page_allocator) catch return "/usr/bin:/bin";
    return S.map.?.get("PATH") orelse "/usr/bin:/bin";
}
