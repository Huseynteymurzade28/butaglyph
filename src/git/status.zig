//! Working tree status without running git:
//!
//! * staged:     HEAD tree vs index (cache-tree shortcuts skip unchanged dirs)
//! * modified / deleted: index vs working tree (lstat, then content hash
//!   when the stat data is inconclusive, as git does)
//! * conflicted: paths with stage 1-3 index entries
//! * untracked:  see untracked.zig
//! * ahead / behind: commits on each side of HEAD...upstream
//!
//! Configuration is read from the repository and the user's global files
//! (`~/.gitconfig`, `$XDG_CONFIG_HOME/git/config`, or `$GIT_CONFIG_GLOBAL`),
//! not from the system file, and `[include]` is not followed.
//! Staged renames are detected as git does (see rename.zig), following
//! `status.renames`/`diff.renames` and `status.renameLimit`/`diff.renameLimit`;
//! `copies` is taken as plain renames. Clean/smudge filters (autocrlf, LFS)
//! are not applied when hashing.

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
const ignore = @import("ignore.zig");
const untracked_mod = @import("untracked.zig");
const rename = @import("rename.zig");
const builtin = @import("builtin");

pub const Status = struct {
    /// Staged changes other than renames.
    staged: u32 = 0,
    /// Staged renames (each one a deleted and an added path).
    renamed: u32 = 0,
    modified: u32 = 0,
    deleted: u32 = 0,
    conflicted: u32 = 0,
    untracked: u32 = 0,
    /// null when there is no upstream or the history walk gave up.
    ahead: ?u32 = null,
    behind: ?u32 = null,
};

pub const Options = struct {
    worktree: bool = true,
    /// Count untracked files (unless `status.showUntrackedFiles` is `no`).
    untracked: bool = true,
    ahead_behind: bool = true,
    /// Give up on ahead/behind after visiting this many commits.
    max_commits: u32 = 20_000,
    global: Global = .{},
    /// For the daemon, see `untracked.Options`.
    dirs: ?*std.ArrayList([]const u8) = null,
    ignore_files: ?*std.ArrayList([]const u8) = null,
};

/// Where the user's global git files are. The caller fills this in from
/// the environment ($HOME, $XDG_CONFIG_HOME, $GIT_CONFIG_GLOBAL), so that
/// the reader itself never looks at the process environment.
pub const Global = struct {
    home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    /// $GIT_CONFIG_GLOBAL: replaces both global config files.
    config_global: ?[]const u8 = null,

    /// The global config files, highest precedence first.
    pub fn configFiles(g: Global, arena: Allocator) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        if (g.config_global) |p| {
            if (p.len > 0) try list.append(arena, p);
            return list.items;
        }
        if (g.home) |h| try list.append(arena, try std.fmt.allocPrint(arena, "{s}/.gitconfig", .{h}));
        if (try g.xdgFile(arena, "config")) |p| try list.append(arena, p);
        return list.items;
    }

    fn xdgFile(g: Global, arena: Allocator, name: []const u8) !?[]const u8 {
        if (g.xdg_config_home) |x| if (x.len > 0) return try std.fmt.allocPrint(arena, "{s}/git/{s}", .{ x, name });
        const h = g.home orelse return null;
        return try std.fmt.allocPrint(arena, "{s}/.config/git/{s}", .{ h, name });
    }

    /// `core.excludesFile` (with `~/` expanded), else `$XDG_CONFIG_HOME/git/ignore`.
    fn excludesFile(g: Global, arena: Allocator, configs: Configs) !?[]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (configs.get("core", null, "excludesfile", &buf)) |v| {
            if (v.len == 0) return null;
            if (std.mem.startsWith(u8, v, "~/")) {
                const h = g.home orelse return null;
                return try std.fmt.allocPrint(arena, "{s}/{s}", .{ h, v[2..] });
            }
            return try arena.dupe(u8, v);
        }
        return g.xdgFile(arena, "ignore");
    }
};

/// The files outside the repository that status depends on: the global
/// config files and the global excludes file (whether or not they exist).
pub fn externalFiles(io: Io, arena: Allocator, repo: Repo, global: Global) ![]const []const u8 {
    const configs = try loadConfigs(io, arena, repo, global);
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, try global.configFiles(arena));
    if (try global.excludesFile(arena, configs)) |p| try list.append(arena, p);
    return list.items;
}

/// The repository's config followed by the global ones; the first file
/// that sets a key wins (git reads them in the opposite order, last wins).
const Configs = struct {
    files: []const GitConfig,

    fn get(c: Configs, section: []const u8, subsection: ?[]const u8, key: []const u8, buf: []u8) ?[]const u8 {
        for (c.files) |f| if (f.get(section, subsection, key, buf)) |v| return v;
        return null;
    }

    fn getBool(c: Configs, section: []const u8, key: []const u8, default: bool) bool {
        var buf: [16]u8 = undefined;
        return parseBool(c.get(section, null, key, &buf) orelse return default) orelse default;
    }
};

fn parseBool(v: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |t| if (std.ascii.eqlIgnoreCase(v, t)) return true;
    for ([_][]const u8{ "false", "no", "off", "0", "" }) |f| if (std.ascii.eqlIgnoreCase(v, f)) return false;
    return null;
}

fn loadConfigs(io: Io, arena: Allocator, repo: Repo, global: Global) !Configs {
    var files: std.ArrayList(GitConfig) = .empty;
    try files.append(arena, try loadConfig(io, arena, repo));
    for (try global.configFiles(arena)) |p| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1024 * 1024)) catch continue;
        try files.append(arena, .{ .text = text });
    }
    return .{ .files = files.items };
}

/// How index stat data is compared with the work tree (core.* settings).
const StatRules = struct {
    /// core.fileMode: the executable bit is meaningful.
    file_mode: bool,
    /// core.symlinks: symlinks are checked out as symlinks (else as files
    /// holding the target). Git's default is true, even on Windows, where
    /// the installer and `git init` set it to false when needed.
    symlinks: bool,
    /// core.trustctime
    trust_ctime: bool,
    /// core.checkStat = minimal: only mtime (seconds) and size.
    minimal: bool,

    fn load(configs: Configs) StatRules {
        var buf: [16]u8 = undefined;
        const windows = builtin.os.tag == .windows;
        return .{
            // Windows has no executable bit, whatever the repository says.
            .file_mode = !windows and configs.getBool("core", "filemode", true),
            .symlinks = configs.getBool("core", "symlinks", true),
            .trust_ctime = configs.getBool("core", "trustctime", true),
            .minimal = if (configs.get("core", null, "checkstat", &buf)) |v| std.ascii.eqlIgnoreCase(v, "minimal") else false,
        };
    }
};

pub fn compute(io: Io, arena: Allocator, repo: Repo, opts: Options) !Status {
    const configs = try loadConfigs(io, arena, repo, opts.global);
    const config = configs.files[0];
    var buf: [256]u8 = undefined;
    if (config.get("extensions", null, "objectformat", &buf)) |fmt| {
        if (!std.ascii.eqlIgnoreCase(fmt, "sha1")) return error.UnsupportedObjectFormat;
    }
    if (config.get("extensions", null, "refstorage", &buf)) |rs| {
        if (!std.ascii.eqlIgnoreCase(rs, "files")) return error.UnsupportedRefStorage;
    }

    var odb = try odb_mod.Odb.open(io, arena, try std.fmt.allocPrint(arena, "{s}/objects", .{repo.common_dir}));
    defer odb.close();
    const head = try refs.resolve(io, repo, "HEAD");
    const loaded = try loadIndex(io, arena, repo);

    var st: Status = .{};
    const head_tree: ?Oid = if (head) |h| (try object.parseCommit((try readKind(&odb, h, .commit)).data)).tree else null;
    try compareHeadToIndex(&odb, arena, head_tree, loaded.index, renameOptions(configs), &st);
    if (opts.worktree) try compareIndexToWorktree(io, repo, loaded, StatRules.load(configs), &st);
    if (opts.untracked) st.untracked = try countUntracked(io, arena, repo, loaded.index.entries, configs, opts);
    if (opts.ahead_behind) if (head) |h| {
        if (try upstreamOid(io, repo, configs)) |up| {
            if (try aheadBehind(&odb, arena, h, up, opts.max_commits)) |ab| {
                st.ahead = ab[0];
                st.behind = ab[1];
            }
        }
    };
    return st;
}

/// null when rename detection is off.
fn renameOptions(configs: Configs) ?rename.Options {
    var buf: [32]u8 = undefined;
    const on = configs.get("status", null, "renames", &buf) orelse configs.get("diff", null, "renames", &buf);
    if (on) |v| {
        const copies = std.ascii.eqlIgnoreCase(v, "copies") or std.ascii.eqlIgnoreCase(v, "copy");
        if (!copies and !(parseBool(v) orelse true)) return null;
    }
    const limit = configs.get("status", null, "renamelimit", &buf) orelse configs.get("diff", null, "renamelimit", &buf);
    return .{ .limit = if (limit) |v| parseLimit(v) orelse rename.default_limit else rename.default_limit };
}

/// A git integer (with an optional k/m/g suffix); 0 or less is unlimited (0).
fn parseLimit(v: []const u8) ?u32 {
    if (v.len == 0) return null;
    const unit: i64 = switch (std.ascii.toLower(v[v.len - 1])) {
        'k' => 1024,
        'm' => 1024 * 1024,
        'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (unit == 1) v else v[0 .. v.len - 1];
    const n = std.math.mul(i64, std.fmt.parseInt(i64, digits, 10) catch return null, unit) catch return null;
    return if (n <= 0) 0 else std.math.cast(u32, n) orelse std.math.maxInt(u32);
}

fn loadConfig(io: Io, arena: Allocator, repo: Repo) !GitConfig {
    const path = try std.fmt.allocPrint(arena, "{s}/config", .{repo.common_dir});
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => |e| return e,
    };
    return .{ .text = text };
}

/// What the daemon must watch so that no change to `status` goes unseen.
/// Paths are absolute.
pub const WatchList = struct {
    /// The work tree directories holding tracked files, and (unless
    /// untracked files are off) every directory that is not ignored.
    dirs: []const []const u8,
    /// Regular tracked files (for watchers that can't see writes to the
    /// files in a watched directory).
    files: []const []const u8,
    /// The `.gitignore` files found.
    ignore_files: []const []const u8,
};

pub fn watchList(io: Io, arena: Allocator, repo: Repo, global: Global, with_files: bool) !WatchList {
    const configs = try loadConfigs(io, arena, repo, global);
    const loaded = try loadIndex(io, arena, repo);
    var dirs: std.ArrayList([]const u8) = .empty;
    var ignore_files: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    // Ancestors of tracked files first: they matter even inside ignored directories.
    try seen.put(arena, "", {});
    for (loaded.index.entries) |e| {
        var end = std.mem.lastIndexOfScalar(u8, e.path, '/') orelse continue;
        while (true) {
            const gop = try seen.getOrPut(arena, e.path[0 .. end + 1]);
            if (gop.found_existing) break; // its ancestors are in already
            end = std.mem.lastIndexOfScalar(u8, e.path[0..end], '/') orelse break;
        }
    }
    _ = try countUntracked(io, arena, repo, loaded.index.entries, configs, .{ .global = global, .dirs = &dirs, .ignore_files = &ignore_files });
    for (dirs.items) |d| try seen.put(arena, d, {});

    var abs_dirs: std.ArrayList([]const u8) = .empty;
    var it = seen.keyIterator();
    while (it.next()) |rel| try abs_dirs.append(arena, try join(arena, repo.work_tree, rel.*));
    for (ignore_files.items) |*f| f.* = try join(arena, repo.work_tree, f.*);

    var files: std.ArrayList([]const u8) = .empty;
    if (with_files) for (loaded.index.entries) |e| {
        // Symlinks and submodules change through their directory's entries.
        if (e.stage != 0 or (e.mode != 0o100644 and e.mode != 0o100755)) continue;
        try files.append(arena, try join(arena, repo.work_tree, e.path));
    };
    return .{ .dirs = abs_dirs.items, .files = files.items, .ignore_files = ignore_files.items };
}

fn join(arena: Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    const r = std.mem.trimEnd(u8, rel, "/");
    if (r.len == 0) return root;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), r });
}

fn countUntracked(io: Io, arena: Allocator, repo: Repo, entries: []const index_mod.Entry, configs: Configs, opts: Options) !u32 {
    var buf: [16]u8 = undefined;
    const mode: untracked_mod.Mode = if (configs.get("status", null, "showuntrackedfiles", &buf)) |v|
        std.meta.stringToEnum(untracked_mod.Mode, v) orelse if (parseBool(v)) |b| (if (b) .normal else .no) else .normal
    else
        .normal;
    var repo_wide: [2]?ignore.List = .{ null, null };
    const info = try std.fmt.allocPrint(arena, "{s}/info/exclude", .{repo.common_dir});
    const sources = [_]?[]const u8{ info, try opts.global.excludesFile(arena, configs) };
    for (&repo_wide, sources) |*list, source| {
        const p = source orelse continue;
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1024 * 1024)) catch continue;
        list.* = try ignore.List.parse(arena, "", text);
    }
    return untracked_mod.count(io, arena, repo.work_tree, entries, repo_wide, .{
        // Watching needs the walk even when nothing is reported.
        .mode = if (mode == .no and opts.dirs != null) .normal else mode,
        .ignore_case = configs.getBool("core", "ignorecase", false),
        .dirs = opts.dirs,
        .ignore_files = opts.ignore_files,
    });
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
    /// Rename candidates, when renames are detected: paths deleted from
    /// HEAD and paths added to the index.
    changes: ?struct {
        deleted: std.ArrayList(rename.File) = .empty,
        added: std.ArrayList(rename.File) = .empty,
    } = null,

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
                try w.flushBefore(w.path.items);
                const sub = if (cache) |c| c.child(e.name) else null;
                if (sub) |s| if (s.entry_count >= 0 and s.oid != null and s.oid.?.eql(e.oid)) {
                    // Cache tree says the index matches this subtree exactly.
                    w.skipPrefix(w.path.items);
                    continue;
                };
                try w.walk(e.oid, sub);
            } else {
                try w.flushBefore(w.path.items);
                if (w.cursor < w.entries.len and std.mem.eql(u8, w.entries[w.cursor].path, w.path.items)) {
                    try w.consumePath(e);
                } else {
                    w.st.staged += 1; // in HEAD, not in the index: staged deletion
                    if (w.changes) |*c| try c.deleted.append(w.arena, .{ .path = try w.arena.dupe(u8, w.path.items), .mode = e.mode, .oid = e.oid });
                }
            }
        }
    }

    /// Index entries sorting before `bound` are not in HEAD: staged additions.
    fn flushBefore(w: *TreeWalk, bound: []const u8) !void {
        while (w.cursor < w.entries.len and std.mem.order(u8, w.entries[w.cursor].path, bound) == .lt) {
            try w.consumePath(null);
        }
    }

    fn skipPrefix(w: *TreeWalk, prefix: []const u8) void {
        while (w.cursor < w.entries.len and std.mem.startsWith(u8, w.entries[w.cursor].path, prefix)) w.cursor += 1;
    }

    /// Consumes all index entries for the path at the cursor (one, or up to
    /// three conflict stages) and classifies it.
    fn consumePath(w: *TreeWalk, head_entry: ?object.TreeEntry) !void {
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
            if (w.changes) |*c| try c.added.append(w.arena, .{ .path = first.path, .mode = first.mode, .oid = first.oid });
        }
    }
};

/// Reads blobs for rename detection.
const Blobs = struct {
    odb: *odb_mod.Odb,

    pub fn read(b: Blobs, oid: Oid) ![]const u8 {
        return (try readKind(b.odb, oid, .blob)).data;
    }
};

fn compareHeadToIndex(odb: *odb_mod.Odb, arena: Allocator, head_tree: ?Oid, index: index_mod.Index, renames: ?rename.Options, st: *Status) !void {
    var w: TreeWalk = .{ .odb = odb, .arena = arena, .entries = index.entries, .st = st };
    if (renames != null) w.changes = .{};
    if (head_tree) |t| {
        const root = if (index.tree) |*c| c else null;
        if (root) |r| if (r.entry_count >= 0 and r.oid != null and r.oid.?.eql(t)) {
            // Whole index matches HEAD; only conflicts (none, or the cache
            // tree would be invalid) could remain.
            return;
        };
        try w.walk(t, root);
    }
    while (w.cursor < w.entries.len) try w.consumePath(null);
    if (w.changes) |c| {
        const n = try rename.count(arena, Blobs{ .odb = odb }, c.deleted.items, c.added.items, renames.?);
        st.renamed = n;
        st.staged -= 2 * n;
    }
}

// ---------------------------------------------------------------- worktree

/// Below this many entries a single thread is faster than spawning more.
const parallel_threshold = 2048;
const max_workers = 8;

fn compareIndexToWorktree(io: Io, repo: Repo, loaded: LoadedIndex, rules: StatRules, st: *Status) !void {
    var dir = try Io.Dir.cwd().openDir(io, repo.work_tree, .{});
    defer dir.close(io);
    const entries = loaded.index.entries;

    // lstat dominates on large trees and every entry is independent, so
    // split the index into chunks checked concurrently.
    const cpus = std.Thread.getCpuCount() catch 1;
    const workers = @max(1, @min(max_workers, cpus, entries.len / (parallel_threshold / 2)));
    if (entries.len < parallel_threshold or workers == 1) {
        const r = try checkEntries(io, dir, entries, loaded.mtime_ns, rules);
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
        futures[w] = io.concurrent(checkEntries, .{ io, dir, part, loaded.mtime_ns, rules }) catch blk: {
            const r = try checkEntries(io, dir, part, loaded.mtime_ns, rules);
            inline_counts.modified += r.modified;
            inline_counts.deleted += r.deleted;
            break :blk null;
        };
    }
    var first_err: ?anyerror = null;
    const r0 = checkEntries(io, dir, entries[0..@min(entries.len, chunk)], loaded.mtime_ns, rules) catch |e| e;
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

fn checkEntries(io: Io, dir: Io.Dir, entries: []const index_mod.Entry, index_mtime_ns: i96, rules: StatRules) anyerror!Counts {
    var c: Counts = .{};
    for (entries) |*e| {
        if (e.stage != 0) continue; // counted as conflicted
        if (e.skip_worktree or e.assume_valid) continue;
        if (e.intent_to_add) {
            c.modified += 1;
            continue;
        }
        if (e.mode == 0o160000) continue; // submodule: not inspected
        switch (try worktreeState(io, dir, e, index_mtime_ns, rules)) {
            .clean => {},
            .modified => c.modified += 1,
            .deleted => c.deleted += 1,
        }
    }
    return c;
}

const WorktreeState = enum { clean, modified, deleted };

fn worktreeState(io: Io, dir: Io.Dir, e: *const index_mod.Entry, index_mtime_ns: i96, rules: StatRules) !WorktreeState {
    const stat = dir.statFile(io, e.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .deleted,
        else => |x| return x,
    };
    const is_link = e.mode == 0o120000;
    // Without core.symlinks a symlink is checked out as a file holding its target.
    const link_as_file = is_link and !rules.symlinks;
    switch (stat.kind) {
        .file => if (is_link and !link_as_file) return .modified,
        .sym_link => if (!is_link) return .modified,
        .directory => return .deleted,
        else => return .modified,
    }
    // Windows' stat data for a symlink (size 0, for one) isn't what Git for
    // Windows records: compare the target itself.
    if (builtin.os.tag == .windows and stat.kind == .sym_link) {
        return if ((try hashLink(io, dir, e.path)).eql(e.oid)) .clean else .modified;
    }
    if (!is_link and rules.file_mode) {
        const exec = executable(stat);
        if (exec != (e.mode == 0o100755)) return .modified;
    }
    // A size change is decisive, except for entries git stored with size 0
    // to force a content check ("racily clean" entries).
    if (@as(u32, @truncate(stat.size)) != e.size and e.size != 0) return .modified;

    const mtime = splitTime(stat.mtime.nanoseconds);
    const ctime = splitTime(stat.ctime.nanoseconds);
    // core.checkStat = minimal drops sub-second times and the inode. Git for
    // Windows stores no inode and uses the creation time as ctime, which
    // Windows' stat doesn't report, so neither is compared there.
    const windows = builtin.os.tag == .windows;
    const check_ctime = rules.trust_ctime and !windows;
    const stat_matches = mtime[0] == e.mtime_s and
        (rules.minimal or mtime[1] == e.mtime_ns) and
        (!check_ctime or (ctime[0] == e.ctime_s and (rules.minimal or ctime[1] == e.ctime_ns))) and
        (rules.minimal or windows or @as(u32, @truncate(stat.inode)) == e.ino) and
        @as(u32, @truncate(stat.size)) == e.size;
    // Racy git: a file modified in the same timestamp tick as the index was
    // written can look clean by stat alone.
    const entry_mtime_ns = @as(i96, e.mtime_s) * std.time.ns_per_s + e.mtime_ns;
    const racy = entry_mtime_ns >= index_mtime_ns;
    if (stat_matches and !racy) return .clean;

    const oid = if (stat.kind == .sym_link) try hashLink(io, dir, e.path) else try hashFile(io, dir, e.path, stat.size);
    return if (oid.eql(e.oid)) .clean else .modified;
}

fn executable(stat: Io.File.Stat) bool {
    if (builtin.os.tag == .windows) return false;
    return stat.permissions.toMode() & 0o100 != 0;
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
    // Windows stores `..\x`; Git for Windows reads it back as `../x`.
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, buf[0..n], '\\', '/');
    return Oid.hashObject("blob", buf[0..n]);
}

// ---------------------------------------------------------------- ahead/behind

fn upstreamOid(io: Io, repo: Repo, config: Configs) !?Oid {
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

test parseLimit {
    try std.testing.expectEqual(@as(?u32, 400), parseLimit("400"));
    try std.testing.expectEqual(@as(?u32, 2048), parseLimit("2k"));
    try std.testing.expectEqual(@as(?u32, 0), parseLimit("-1"));
    try std.testing.expectEqual(@as(?u32, null), parseLimit("lots"));
}

test splitTime {
    const t = splitTime(1_700_000_000 * std.time.ns_per_s + 123);
    try std.testing.expectEqual(@as(u32, 1_700_000_000), t[0]);
    try std.testing.expectEqual(@as(u32, 123), t[1]);
}
