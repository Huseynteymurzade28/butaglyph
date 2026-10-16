//! Working tree status without running git:
//!
//! * staged:     HEAD tree vs index (cache-tree shortcuts skip unchanged dirs)
//! * modified / deleted: index vs working tree (lstat, then content hash
//!   when the stat data is inconclusive, as git does)
//! * conflicted: paths with stage 1-3 index entries
//! * ahead / behind: commits on each side of HEAD...upstream
//!
//! Untracked files are not reported (that needs .gitignore handling and a
//! full tree walk; it belongs with the Phase 3 daemon's inotify cache).
//! Rename detection is not done: a staged rename counts as two paths, as
//! with `git status --no-renames`. Clean/smudge filters (autocrlf, LFS) are
//! not applied when hashing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Oid = @import("oid.zig").Oid;
const Repo = @import("repo.zig").Repo;
const refs = @import("refs.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const odb_mod = @import("odb.zig");
const GitConfig = @import("config.zig").Config;

pub const Status = struct {
    staged: u32 = 0,
    modified: u32 = 0,
    deleted: u32 = 0,
    conflicted: u32 = 0,
    /// null when there is no upstream or the history walk gave up.
    ahead: ?u32 = null,
    behind: ?u32 = null,
};

pub const Options = struct {
    worktree: bool = true,
    ahead_behind: bool = true,
    /// Give up on ahead/behind after visiting this many commits.
    max_commits: u32 = 20_000,
};

pub fn compute(io: Io, arena: Allocator, repo: Repo, opts: Options) !Status {
    const config = try loadConfig(io, arena, repo);
    var buf: [256]u8 = undefined;
    if (config.get("extensions", null, "objectformat", &buf)) |fmt| {
        if (!std.ascii.eqlIgnoreCase(fmt, "sha1")) return error.UnsupportedObjectFormat;
    }
    if (config.get("extensions", null, "refstorage", &buf)) |rs| {
        if (!std.ascii.eqlIgnoreCase(rs, "files")) return error.UnsupportedRefStorage;
    }

    var odb = try odb_mod.Odb.open(io, arena, try std.fmt.allocPrint(arena, "{s}/objects", .{repo.common_dir}));
    const head = try refs.resolve(io, repo, "HEAD");
    const loaded = try loadIndex(io, arena, repo);

    var st: Status = .{};
    const head_tree: ?Oid = if (head) |h| (try object.parseCommit((try readKind(&odb, h, .commit)).data)).tree else null;
    try compareHeadToIndex(&odb, arena, head_tree, loaded.index, &st);
    if (opts.worktree) try compareIndexToWorktree(io, repo, loaded, &st);
    if (opts.ahead_behind) if (head) |h| {
        if (try upstreamOid(io, repo, config)) |up| {
            if (try aheadBehind(&odb, arena, h, up, opts.max_commits)) |ab| {
                st.ahead = ab[0];
                st.behind = ab[1];
            }
        }
    };
    return st;
}

fn loadConfig(io: Io, arena: Allocator, repo: Repo) !GitConfig {
    const path = try std.fmt.allocPrint(arena, "{s}/config", .{repo.common_dir});
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => |e| return e,
    };
    return .{ .text = text };
}

const LoadedIndex = struct {
    index: index_mod.Index,
    /// mtime of the index file itself, for racy-git detection.
    mtime_ns: i96,
};

fn loadIndex(io: Io, arena: Allocator, repo: Repo) !LoadedIndex {
    const path = try std.fmt.allocPrint(arena, "{s}/index", .{repo.git_dir});
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .index = .{ .version = 2, .entries = &.{}, .tree = null }, .mtime_ns = 0 },
        else => |e| return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const data = try arena.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, data, 0) != data.len) return error.InvalidIndex;
    return .{ .index = try index_mod.parse(arena, data), .mtime_ns = stat.mtime.nanoseconds };
}

fn readKind(odb: *odb_mod.Odb, oid: Oid, kind: odb_mod.Kind) odb_mod.Error!odb_mod.Object {
    const obj = try odb.read(oid);
    if (obj.kind != kind) return error.CorruptObject;
    return obj;
}

// ---------------------------------------------------------------- staged

/// Merge-walks the HEAD tree (depth first, in git tree order, which yields
/// paths in the same byte order as the index) against the index entries.
const TreeWalk = struct {
    odb: *odb_mod.Odb,
    arena: Allocator,
    entries: []const index_mod.Entry,
    cursor: usize = 0,
    st: *Status,
    path: std.ArrayList(u8) = .empty,

    const WalkError = odb_mod.Error || object.ParseError;

    fn walk(w: *TreeWalk, tree_oid: Oid, cache: ?*const index_mod.CacheTree) WalkError!void {
        const tree = try readKind(w.odb, tree_oid, .tree);
        var it: object.TreeIterator = .init(tree.data);
        while (try it.next()) |e| {
            const mark = w.path.items.len;
            defer w.path.shrinkRetainingCapacity(mark);
            try w.path.appendSlice(w.arena, e.name);
            if (e.isTree()) {
                try w.path.append(w.arena, '/');
                w.flushBefore(w.path.items);
                const sub = if (cache) |c| c.child(e.name) else null;
                if (sub) |s| if (s.entry_count >= 0 and s.oid != null and s.oid.?.eql(e.oid)) {
                    // Cache tree says the index matches this subtree exactly.
                    w.skipPrefix(w.path.items);
                    continue;
                };
                try w.walk(e.oid, sub);
            } else {
                w.flushBefore(w.path.items);
                if (w.cursor < w.entries.len and std.mem.eql(u8, w.entries[w.cursor].path, w.path.items)) {
                    w.matchPath(e);
                } else {
                    w.st.staged += 1; // in HEAD, not in the index: staged deletion
                }
            }
        }
    }

    /// Index entries sorting before `bound` are not in HEAD: staged additions.
    fn flushBefore(w: *TreeWalk, bound: []const u8) void {
        while (w.cursor < w.entries.len and std.mem.order(u8, w.entries[w.cursor].path, bound) == .lt) {
            w.consumePath(null);
        }
    }

    fn skipPrefix(w: *TreeWalk, prefix: []const u8) void {
        while (w.cursor < w.entries.len and std.mem.startsWith(u8, w.entries[w.cursor].path, prefix)) w.cursor += 1;
    }

    fn matchPath(w: *TreeWalk, head_entry: object.TreeEntry) void {
        w.consumePath(head_entry);
    }

    /// Consumes all index entries for the path at the cursor (one, or up to
    /// three conflict stages) and classifies it.
    fn consumePath(w: *TreeWalk, head_entry: ?object.TreeEntry) void {
        const first = &w.entries[w.cursor];
        var conflicted = false;
        while (w.cursor < w.entries.len and std.mem.eql(u8, w.entries[w.cursor].path, first.path)) : (w.cursor += 1) {
            if (w.entries[w.cursor].stage != 0) conflicted = true;
        }
        if (conflicted) {
            w.st.conflicted += 1;
        } else if (first.intent_to_add) {
            // Shown by git as a worktree addition, not as staged.
        } else if (head_entry) |h| {
            if (h.mode != first.mode or !h.oid.eql(first.oid)) w.st.staged += 1;
        } else {
            w.st.staged += 1;
        }
    }
};

fn compareHeadToIndex(odb: *odb_mod.Odb, arena: Allocator, head_tree: ?Oid, index: index_mod.Index, st: *Status) !void {
    var w: TreeWalk = .{ .odb = odb, .arena = arena, .entries = index.entries, .st = st };
    if (head_tree) |t| {
        const root = if (index.tree) |*c| c else null;
        if (root) |r| if (r.entry_count >= 0 and r.oid != null and r.oid.?.eql(t)) {
            // Whole index matches HEAD; only conflicts (none, or the cache
            // tree would be invalid) could remain.
            return;
        };
        try w.walk(t, root);
    }
    while (w.cursor < w.entries.len) w.consumePath(null);
}

// ---------------------------------------------------------------- worktree

/// Below this many entries a single thread is faster than spawning more.
const parallel_threshold = 2048;
const max_workers = 8;

fn compareIndexToWorktree(io: Io, repo: Repo, loaded: LoadedIndex, st: *Status) !void {
    var dir = try Io.Dir.cwd().openDir(io, repo.work_tree, .{});
    defer dir.close(io);
    const entries = loaded.index.entries;

    // lstat dominates on large trees and every entry is independent, so
    // split the index into chunks checked concurrently.
    const cpus = std.Thread.getCpuCount() catch 1;
    const workers = @max(1, @min(max_workers, cpus, entries.len / (parallel_threshold / 2)));
    if (entries.len < parallel_threshold or workers == 1) {
        const r = try checkEntries(io, dir, entries, loaded.mtime_ns);
        st.modified += r.modified;
        st.deleted += r.deleted;
        return;
    }
    var futures: [max_workers]?Io.Future(anyerror!Counts) = @splat(null);
    const chunk = std.math.divCeil(usize, entries.len, workers) catch unreachable;
    var inline_counts: Counts = .{};
    for (0..workers) |w| {
        const part = entries[@min(entries.len, w * chunk)..@min(entries.len, (w + 1) * chunk)];
        if (w == 0) continue; // this thread takes chunk 0 below
        futures[w] = io.concurrent(checkEntries, .{ io, dir, part, loaded.mtime_ns }) catch blk: {
            const r = try checkEntries(io, dir, part, loaded.mtime_ns);
            inline_counts.modified += r.modified;
            inline_counts.deleted += r.deleted;
            break :blk null;
        };
    }
    var first_err: ?anyerror = null;
    const r0 = checkEntries(io, dir, entries[0..@min(entries.len, chunk)], loaded.mtime_ns) catch |e| e;
    // Always await every task before returning: they use `dir` and this frame.
    for (&futures) |*f| if (f.*) |*fut| {
        if (fut.await(io)) |r| {
            inline_counts.modified += r.modified;
            inline_counts.deleted += r.deleted;
        } else |e| first_err = first_err orelse e;
    };
    const c0 = r0 catch |e| return e;
    if (first_err) |e| return e;
    st.modified += c0.modified + inline_counts.modified;
    st.deleted += c0.deleted + inline_counts.deleted;
}

const Counts = struct { modified: u32 = 0, deleted: u32 = 0 };

fn checkEntries(io: Io, dir: Io.Dir, entries: []const index_mod.Entry, index_mtime_ns: i96) anyerror!Counts {
    var c: Counts = .{};
    for (entries) |*e| {
        if (e.stage != 0) continue; // counted as conflicted
        if (e.skip_worktree or e.assume_valid) continue;
        if (e.intent_to_add) {
            c.modified += 1;
            continue;
        }
        if (e.mode == 0o160000) continue; // submodule: not inspected
        switch (try worktreeState(io, dir, e, index_mtime_ns)) {
            .clean => {},
            .modified => c.modified += 1,
            .deleted => c.deleted += 1,
        }
    }
    return c;
}

const WorktreeState = enum { clean, modified, deleted };

fn worktreeState(io: Io, dir: Io.Dir, e: *const index_mod.Entry, index_mtime_ns: i96) !WorktreeState {
    const stat = dir.statFile(io, e.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .deleted,
        else => |x| return x,
    };
    const is_link = e.mode == 0o120000;
    switch (stat.kind) {
        .file => if (is_link) return .modified,
        .sym_link => if (!is_link) return .modified,
        .directory => return .deleted,
        else => return .modified,
    }
    if (!is_link) {
        const exec = stat.permissions.toMode() & 0o100 != 0;
        if (exec != (e.mode == 0o100755)) return .modified;
    }
    // A size change is decisive, except for entries git stored with size 0
    // to force a content check ("racily clean" entries).
    if (@as(u32, @truncate(stat.size)) != e.size and e.size != 0) return .modified;

    const mtime = splitTime(stat.mtime.nanoseconds);
    const ctime = splitTime(stat.ctime.nanoseconds);
    const stat_matches = mtime[0] == e.mtime_s and mtime[1] == e.mtime_ns and
        ctime[0] == e.ctime_s and ctime[1] == e.ctime_ns and
        @as(u32, @truncate(stat.inode)) == e.ino and
        @as(u32, @truncate(stat.size)) == e.size;
    // Racy git: a file modified in the same timestamp tick as the index was
    // written can look clean by stat alone.
    const entry_mtime_ns = @as(i96, e.mtime_s) * std.time.ns_per_s + e.mtime_ns;
    const racy = entry_mtime_ns >= index_mtime_ns;
    if (stat_matches and !racy) return .clean;

    const oid = if (is_link) try hashLink(io, dir, e.path) else try hashFile(io, dir, e.path, stat.size);
    return if (oid.eql(e.oid)) .clean else .modified;
}

fn splitTime(ns: i96) [2]u32 {
    const s = @divFloor(ns, std.time.ns_per_s);
    return .{ @truncate(@as(u96, @bitCast(s))), @intCast(@mod(ns, std.time.ns_per_s)) };
}

fn hashFile(io: Io, dir: Io.Dir, path: []const u8, size: u64) !Oid {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var h = std.crypto.hash.Sha1.init(.{});
    var header_buf: [32]u8 = undefined;
    h.update(try std.fmt.bufPrint(&header_buf, "blob {d}\x00", .{size}));
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const n = try file.readPositional(io, &.{&buf}, offset);
        if (n == 0) break;
        h.update(buf[0..n]);
        offset += n;
    }
    if (offset != size) return Oid.zero; // file changed while hashing: treat as modified
    return .{ .bytes = h.finalResult() };
}

fn hashLink(io: Io, dir: Io.Dir, path: []const u8) !Oid {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.readLink(io, path, &buf);
    return Oid.hashObject("blob", buf[0..n]);
}

// ---------------------------------------------------------------- ahead/behind

fn upstreamOid(io: Io, repo: Repo, config: GitConfig) !?Oid {
    var head_buf: [512]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = try std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{repo.git_dir});
    const head = std.mem.trimEnd(u8, Io.Dir.cwd().readFile(io, head_path, &head_buf) catch return null, " \r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, head, prefix)) return null; // detached
    const branch = head[prefix.len..];

    var remote_buf: [256]u8 = undefined;
    var merge_buf: [512]u8 = undefined;
    const remote = config.get("branch", branch, "remote", &remote_buf) orelse return null;
    const merge = config.get("branch", branch, "merge", &merge_buf) orelse return null;
    if (std.mem.eql(u8, remote, ".")) return refs.resolve(io, repo, merge);
    const heads = "refs/heads/";
    if (!std.mem.startsWith(u8, merge, heads)) return null;
    var ref_buf: [1024]u8 = undefined;
    const tracking = std.fmt.bufPrint(&ref_buf, "refs/remotes/{s}/{s}", .{ remote, merge[heads.len..] }) catch return null;
    return refs.resolve(io, repo, tracking);
}

const Node = struct {
    flags: u2 = 0,
    propagated: u2 = 0,
    time: i64,
    commit: object.Commit,
};

const QueueItem = struct { oid: Oid, time: i64 };

fn newerFirst(_: void, a: QueueItem, b: QueueItem) std.math.Order {
    return std.math.order(b.time, a.time);
}

/// Paints commits reachable from `a` with 1 and from `b` with 2, newest
/// first (like git's merge-base walk), until every queued commit is
/// reachable from both ("stale"). With commit dates that never go
/// backwards, any commit still painted with one side only at that point is
/// not an ancestor of the other side. Returns {only-a, only-b} counts.
pub fn aheadBehind(odb: *odb_mod.Odb, arena: Allocator, a: Oid, b: Oid, max_commits: u32) !?[2]u32 {
    if (a.eql(b)) return .{ 0, 0 };
    var nodes: std.AutoHashMapUnmanaged(Oid, Node) = .empty;
    var queue: std.PriorityQueue(QueueItem, void, newerFirst) = .empty;

    const Paint = struct {
        fn add(o: *odb_mod.Odb, al: Allocator, n: *std.AutoHashMapUnmanaged(Oid, Node), q: anytype, oid: Oid, flag: u2) !void {
            const gop = try n.getOrPut(al, oid);
            if (!gop.found_existing) {
                const c = try object.parseCommit((try readKind(o, oid, .commit)).data);
                gop.value_ptr.* = .{ .time = c.time, .commit = c };
            }
            const node = gop.value_ptr;
            if (node.flags | flag == node.flags) return;
            node.flags |= flag;
            try q.push(al, .{ .oid = oid, .time = node.time });
        }
    };

    try Paint.add(odb, arena, &nodes, &queue, a, 1);
    try Paint.add(odb, arena, &nodes, &queue, b, 2);

    // A few extra rounds after everything is stale tolerate small clock skew.
    var slop: u32 = 5;
    while (queue.pop()) |item| {
        if (nodes.count() > max_commits) return null;
        const node = nodes.getPtr(item.oid).?;
        if (node.propagated == node.flags) continue;
        node.propagated = node.flags;
        const flags = node.flags;
        var parents = node.commit.parents();
        while (parents.next()) |p| try Paint.add(odb, arena, &nodes, &queue, p, flags);

        if (allStale(&queue, &nodes)) {
            if (slop == 0) break;
            slop -= 1;
        } else slop = 5;
    }

    var ahead: u32 = 0;
    var behind: u32 = 0;
    var it = nodes.valueIterator();
    while (it.next()) |n| switch (n.flags) {
        1 => ahead += 1,
        2 => behind += 1,
        else => {},
    };
    return .{ ahead, behind };
}

fn allStale(queue: anytype, nodes: *std.AutoHashMapUnmanaged(Oid, Node)) bool {
    for (queue.items) |item| {
        if (nodes.get(item.oid).?.flags != 3) return false;
    }
    return true;
}

test splitTime {
    const t = splitTime(1_700_000_000 * std.time.ns_per_s + 123);
    try std.testing.expectEqual(@as(u32, 1_700_000_000), t[0]);
    try std.testing.expectEqual(@as(u32, 123), t[1]);
}
