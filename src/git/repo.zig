//! Minimal git repository access: discovery and HEAD.
//!
//! Phase 0 reads only `HEAD`. Phase 2 grows this directory into a full
//! reader (index, loose objects, packfiles + deltas) without changing the
//! git modules' interface: they keep asking for a `Repo` and a `Head`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Repo = struct {
    /// The repository's git dir: `<work_tree>/.git`, or the target of a
    /// `.git` file's `gitdir:` line (worktrees, submodules). Holds HEAD and
    /// the index.
    git_dir: []const u8,
    /// Where objects, shared refs and config live. Equal to `git_dir`
    /// except in linked worktrees, where `<git_dir>/commondir` points to it.
    common_dir: []const u8,
    work_tree: []const u8,
};

pub const Head = union(enum) {
    /// `ref: refs/heads/<name>`, with the prefix removed. Other refs keep
    /// their full name minus `refs/`.
    branch: []const u8,
    /// Detached HEAD: the full hex object id (40 chars for SHA-1, 64 for SHA-256).
    detached: []const u8,
};

pub const ParseError = error{InvalidHead};

/// Walks up from `start` (absolute, physical) looking for `.git`.
/// Returns null when no repository is found.
pub fn discover(io: Io, arena: Allocator, start: []const u8) !?Repo {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir = std.mem.trimEnd(u8, start, "/");
    while (true) {
        const dot_git = std.fmt.bufPrint(&buf, "{s}/.git", .{dir}) catch return error.NameTooLong;
        if (Io.Dir.cwd().statFile(io, dot_git, .{})) |stat| switch (stat.kind) {
            .directory => return try finish(io, arena, try arena.dupe(u8, dot_git), dir),
            .file => {
                var file_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
                const contents = try Io.Dir.cwd().readFile(io, dot_git, &file_buf);
                const target = try parseGitFile(contents);
                const git_dir = if (std.fs.path.isAbsolute(target))
                    try arena.dupe(u8, target)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, target });
                return try finish(io, arena, git_dir, dir);
            },
            else => {},
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => {},
            else => |e| return e,
        }
        if (dir.len == 0) return null;
        dir = dir[0 .. std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null];
    }
}

fn finish(io: Io, arena: Allocator, git_dir: []const u8, dir: []const u8) !Repo {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var content_buf: [std.fs.max_path_bytes]u8 = undefined;
    const commondir_path = std.fmt.bufPrint(&path_buf, "{s}/commondir", .{git_dir}) catch return error.NameTooLong;
    const common_dir: []const u8 = if (Io.Dir.cwd().readFile(io, commondir_path, &content_buf)) |raw| blk: {
        const target = std.mem.trimEnd(u8, raw, " \t\r\n");
        if (target.len == 0) break :blk git_dir;
        break :blk if (std.fs.path.isAbsolute(target))
            try arena.dupe(u8, target)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ git_dir, target });
    } else |_| git_dir;
    return .{
        .git_dir = git_dir,
        .common_dir = common_dir,
        .work_tree = try arena.dupe(u8, if (dir.len == 0) "/" else dir),
    };
}

pub fn readHead(io: Io, arena: Allocator, repo: Repo) !Head {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{repo.git_dir}) catch return error.NameTooLong;
    var buf: [512]u8 = undefined;
    const contents = try Io.Dir.cwd().readFile(io, head_path, &buf);
    return switch (try parseHead(contents)) {
        .branch => |b| .{ .branch = try arena.dupe(u8, b) },
        .detached => |h| .{ .detached = try arena.dupe(u8, h) },
    };
}

/// Parses the contents of a HEAD file. Returned slices point into `contents`.
pub fn parseHead(contents: []const u8) ParseError!Head {
    const line = std.mem.trimEnd(u8, contents, " \t\r\n");
    if (std.mem.startsWith(u8, line, "ref:")) {
        const ref = std.mem.trim(u8, line["ref:".len..], " \t");
        if (ref.len == 0) return error.InvalidHead;
        if (std.mem.startsWith(u8, ref, "refs/heads/") and ref.len > "refs/heads/".len) {
            return .{ .branch = ref["refs/heads/".len..] };
        }
        return .{ .branch = if (std.mem.startsWith(u8, ref, "refs/")) ref["refs/".len..] else ref };
    }
    if ((line.len == 40 or line.len == 64) and isHex(line)) return .{ .detached = line };
    return error.InvalidHead;
}

/// Parses a `.git` file ("gitdir: <path>"). The path may be relative to
/// the directory containing the file.
pub fn parseGitFile(contents: []const u8) error{InvalidGitFile}![]const u8 {
    const line = std.mem.trimEnd(u8, contents, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return error.InvalidGitFile;
    const target = std.mem.trim(u8, line["gitdir:".len..], " \t");
    if (target.len == 0) return error.InvalidGitFile;
    return target;
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

test "HEAD on a branch" {
    try std.testing.expectEqualStrings("main", (try parseHead("ref: refs/heads/main\n")).branch);
    try std.testing.expectEqualStrings("feature/x-1", (try parseHead("ref: refs/heads/feature/x-1")).branch);
    try std.testing.expectEqualStrings("main", (try parseHead("ref:refs/heads/main\r\n")).branch);
    try std.testing.expectEqualStrings("remotes/origin/main", (try parseHead("ref: refs/remotes/origin/main\n")).branch);
}

test "detached HEAD" {
    const sha1 = "3f786850e387550fdab836ed7e6dc881de23001b";
    try std.testing.expectEqualStrings(sha1, (try parseHead(sha1 ++ "\n")).detached);
    const sha256 = "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b";
    try std.testing.expectEqualStrings(sha256, (try parseHead(sha256)).detached);
}

test "invalid HEAD" {
    try std.testing.expectError(error.InvalidHead, parseHead(""));
    try std.testing.expectError(error.InvalidHead, parseHead("ref: \n"));
    try std.testing.expectError(error.InvalidHead, parseHead("3f786850e387"));
    try std.testing.expectError(error.InvalidHead, parseHead("zz786850e387550fdab836ed7e6dc881de23001b"));
}

test "gitdir file (worktrees, submodules)" {
    try std.testing.expectEqualStrings("/r/.git/worktrees/wt", try parseGitFile("gitdir: /r/.git/worktrees/wt\n"));
    try std.testing.expectEqualStrings("../.git/modules/sub", try parseGitFile("gitdir: ../.git/modules/sub"));
    try std.testing.expectError(error.InvalidGitFile, parseGitFile("nonsense"));
    try std.testing.expectError(error.InvalidGitFile, parseGitFile("gitdir:  \n"));
}

test "discover: plain repo, subdirectory, worktree file, no repo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.createDirPath(io, "repo/.git/worktrees/wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/worktrees/wt/HEAD", .data = "3f786850e387550fdab836ed7e6dc881de23001b\n" });
    try tmp.dir.createDirPath(io, "wt/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: ../repo/.git/worktrees/wt\n" });
    try tmp.dir.createDirPath(io, "plain");

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const sub = try std.fs.path.join(arena, &.{ root, "repo/a/b" });
    const repo = (try discover(io, arena, sub)).?;
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "repo" }), repo.work_tree);
    try std.testing.expectEqualStrings("main", (try readHead(io, arena, repo)).branch);

    const wt_src = try std.fs.path.join(arena, &.{ root, "wt/src" });
    const wt = (try discover(io, arena, wt_src)).?;
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "wt" }), wt.work_tree);
    try std.testing.expectEqualStrings("3f786850e387550fdab836ed7e6dc881de23001b", (try readHead(io, arena, wt)).detached);

    // tmpDir lives under .zig-cache inside this project. If the project is
    // itself a git repo, discovery from "plain" correctly finds it, so only
    // assert that it does not stop at "plain" itself.
    const plain = try std.fs.path.join(arena, &.{ root, "plain" });
    if (try discover(io, arena, plain)) |found| {
        try std.testing.expect(!std.mem.startsWith(u8, found.work_tree, plain));
    }
}
