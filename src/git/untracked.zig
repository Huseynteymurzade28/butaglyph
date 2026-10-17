//! Untracked files: what `git status` lists as `??`, and how many.
//!
//! The work tree is walked from the root, skipping `.git`, ignored
//! directories (nothing below one can be re-included) and tracked paths.
//! `status.showUntrackedFiles` decides what counts:
//!
//! * `normal` (git's default): a directory with no tracked files counts
//!   once, as `dir/`, if it holds anything untracked and not ignored.
//! * `all`: every untracked file counts.
//! * `no`: nothing is counted and nothing is walked.
//!
//! A directory holding a `.git` (a nested repository) counts once in both
//! modes and is never entered. Only regular files and symlinks count;
//! symlinks to directories are not followed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const index_mod = @import("index.zig");
const ignore = @import("ignore.zig");

pub const Mode = enum { no, normal, all };

pub const Options = struct {
    mode: Mode = .normal,
    ignore_case: bool = false,
    /// For the daemon: every directory that is not ignored (relative to the
    /// work tree, with a trailing `/`, "" for the root). Untracked
    /// directories are then walked completely rather than only until their
    /// first untracked file.
    dirs: ?*std.ArrayList([]const u8) = null,
    /// For the daemon: every `.gitignore` read (relative to the work tree).
    ignore_files: ?*std.ArrayList([]const u8) = null,
};

/// Counts untracked paths in `work_tree`. `entries` is the index, in index
/// order; `repo_wide` holds `info/exclude` and `core.excludesFile`.
pub fn count(io: Io, arena: Allocator, work_tree: []const u8, entries: []const index_mod.Entry, repo_wide: [2]?ignore.List, opts: Options) !u32 {
    if (opts.mode == .no) return 0;
    var root = try Io.Dir.cwd().openDir(io, work_tree, .{ .iterate = true });
    defer root.close(io);
    var w: Walker = .{
        .io = io,
        .arena = arena,
        .entries = entries,
        .rules = .{ .repo_wide = repo_wide, .ignore_case = opts.ignore_case },
        .opts = opts,
    };
    _ = try w.visit(root, false);
    return w.count;
}

const Walker = struct {
    io: Io,
    arena: Allocator,
    entries: []const index_mod.Entry,
    rules: ignore.Stack,
    opts: Options,
    count: u32 = 0,
    /// The directory being visited, relative to the work tree, with a
    /// trailing `/` ("" at the root).
    path: std.ArrayList(u8) = .empty,

    /// Visits the directory `w.path` (open as `dir`). `untracked`: it has no
    /// tracked files (an untracked directory or one inside it). Returns
    /// whether it holds anything untracked.
    fn visit(w: *Walker, dir: Io.Dir, untracked: bool) anyerror!bool {
        if (w.opts.dirs) |d| try d.append(w.arena, try w.arena.dupe(u8, w.path.items));
        const pushed = try w.pushRules(dir);
        defer if (pushed) {
            _ = w.rules.dirs.pop();
        };

        const collapse = untracked and w.opts.mode == .normal;
        const exhaustive = w.opts.dirs != null;
        var found = false;
        var it = dir.iterate();
        while (try it.next(w.io)) |entry| {
            if (isDotGit(entry.name, w.opts.ignore_case)) continue;
            const mark = w.path.items.len;
            defer w.path.shrinkRetainingCapacity(mark);
            try w.path.appendSlice(w.arena, entry.name);
            const rel = w.path.items;

            const kind = if (entry.kind == .unknown)
                (dir.statFile(w.io, entry.name, .{ .follow_symlinks = false }) catch continue).kind
            else
                entry.kind;
            switch (kind) {
                .directory => {
                    // A tracked gitlink (submodule) is not ours to look into.
                    if (!untracked and w.isTracked(rel)) continue;
                    if (w.rules.isIgnored(rel, true)) continue;
                    const has_tracked = !untracked and w.hasTrackedBelow(rel);
                    if (!has_tracked and isRepository(w.io, dir, entry.name)) {
                        found = true;
                        if (!collapse) w.count += 1;
                    } else {
                        var sub = dir.openDir(w.io, entry.name, .{ .iterate = true }) catch continue;
                        defer sub.close(w.io);
                        try w.path.append(w.arena, '/');
                        const sub_found = try w.visit(sub, !has_tracked);
                        // In normal mode an untracked directory is one entry.
                        if (sub_found and !has_tracked and !untracked and w.opts.mode == .normal) w.count += 1;
                        found = found or sub_found;
                    }
                },
                .file, .sym_link => {
                    if (!untracked and w.isTracked(rel)) continue;
                    if (w.rules.isIgnored(rel, false)) continue;
                    found = true;
                    if (!collapse) w.count += 1;
                },
                else => continue, // fifos, sockets, devices: git skips them
            }
            // In normal mode one untracked file decides an untracked directory.
            if (found and collapse and !exhaustive) return true;
        }
        return found;
    }

    /// Pushes the rules of `w.path`/.gitignore, if there is one.
    fn pushRules(w: *Walker, dir: Io.Dir) !bool {
        const text = dir.readFileAlloc(w.io, ".gitignore", w.arena, .limited(1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir, error.IsDir, error.AccessDenied, error.PermissionDenied => return false,
            else => |x| return x,
        };
        if (w.opts.ignore_files) |list| try list.append(w.arena, try std.fmt.allocPrint(w.arena, "{s}.gitignore", .{w.path.items}));
        const base = try w.arena.dupe(u8, w.path.items);
        try w.rules.dirs.append(w.arena, try ignore.List.parse(w.arena, base, text));
        return true;
    }

    fn isTracked(w: *const Walker, path: []const u8) bool {
        const i = lowerBound(w.entries, path);
        return i < w.entries.len and std.mem.eql(u8, w.entries[i].path, path);
    }

    /// Some index entry lies below the directory `path` (given without a
    /// trailing slash).
    fn hasTrackedBelow(w: *const Walker, path: []const u8) bool {
        var i = lowerBound(w.entries, path);
        // Entries equal to `path` itself or sorting between `path` and
        // `path/` (such as `path-x` or `path.c`) come first; skip them.
        while (i < w.entries.len) : (i += 1) {
            const p = w.entries[i].path;
            if (!std.mem.startsWith(u8, p, path)) return false;
            if (p.len > path.len and p[path.len] == '/') return true;
            if (p.len > path.len and p[path.len] > '/') return false;
        }
        return false;
    }
};

/// First entry whose path is not less than `path`.
fn lowerBound(entries: []const index_mod.Entry, path: []const u8) usize {
    var lo: usize = 0;
    var hi = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, entries[mid].path, path) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn isDotGit(name: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(name, ".git") else std.mem.eql(u8, name, ".git");
}

/// `name` (a directory in `parent`) holds a `.git`: a nested repository.
fn isRepository(io: Io, parent: Io.Dir, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.git", .{name}) catch return false;
    parent.access(io, p, .{}) catch return false;
    return true;
}

test lowerBound {
    const E = index_mod.Entry;
    var entries: [4]E = undefined;
    for (&entries, [_][]const u8{ "a-b", "a/b", "a/c", "b" }) |*e, p| e.path = p;
    var w: Walker = .{ .io = undefined, .arena = undefined, .entries = &entries, .rules = .{}, .opts = .{} };
    try std.testing.expect(w.isTracked("a/b"));
    try std.testing.expect(!w.isTracked("a"));
    try std.testing.expect(w.hasTrackedBelow("a"));
    try std.testing.expect(!w.hasTrackedBelow("a-b"));
    try std.testing.expect(!w.hasTrackedBelow("b"));
    try std.testing.expect(!w.hasTrackedBelow("c"));
}
