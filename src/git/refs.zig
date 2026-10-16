//! Ref resolution: loose refs, packed-refs and symbolic refs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Oid = @import("oid.zig").Oid;
const Repo = @import("repo.zig").Repo;

pub const Error = error{ InvalidRef, SymrefLoop, NameTooLong } || Allocator.Error || Io.Cancelable;

const max_symref_depth = 5;

/// Resolves `name` ("HEAD" or a full ref like "refs/heads/main") to an
/// object id, following symbolic refs. Returns null if the ref (or the
/// branch HEAD points to) does not exist yet.
pub fn resolve(io: Io, repo: Repo, name: []const u8) Error!?Oid {
    var current_buf: [1024]u8 = undefined;
    var current: []const u8 = name;
    for (0..max_symref_depth) |_| {
        var content_buf: [1024]u8 = undefined;
        const content = readLoose(io, repo, current, &content_buf) orelse
            return packedLookup(io, repo, current);
        const line = std.mem.trimEnd(u8, content, " \t\r\n");
        if (std.mem.startsWith(u8, line, "ref:")) {
            const target = std.mem.trim(u8, line["ref:".len..], " \t");
            if (target.len > current_buf.len) return error.NameTooLong;
            @memcpy(current_buf[0..target.len], target);
            current = current_buf[0..target.len];
            continue;
        }
        return Oid.parseHex(line) catch error.InvalidRef;
    }
    return error.SymrefLoop;
}

/// Refs that live in the per-worktree git dir rather than the common dir.
fn isPerWorktree(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') == null) return true; // HEAD, ORIG_HEAD, ...
    for ([_][]const u8{ "refs/bisect/", "refs/worktree/", "refs/rewritten/" }) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

fn readLoose(io: Io, repo: Repo, name: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOf(u8, name, "..") != null) return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = if (isPerWorktree(name)) repo.git_dir else repo.common_dir;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    return Io.Dir.cwd().readFile(io, path, buf) catch null;
}

fn packedLookup(io: Io, repo: Repo, name: []const u8) Error!?Oid {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/packed-refs", .{repo.common_dir}) catch return error.NameTooLong;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer file.close(io);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    return findPacked(&reader.interface, name);
}

/// packed-refs lines are "<hex> <refname>", plus "^<hex>" peel lines and a
/// "# pack-refs with: ..." header.
fn findPacked(r: *Io.Reader, name: []const u8) Error!?Oid {
    while (true) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Skip absurdly long lines.
                _ = r.discardDelimiterInclusive('\n') catch return null;
                continue;
            },
            error.ReadFailed => return null,
        } orelse return null;
        if (line.len < Oid.hex_len + 2 or line[0] == '#' or line[0] == '^') continue;
        const refname = std.mem.trimEnd(u8, line[Oid.hex_len + 1 ..], "\r");
        if (std.mem.eql(u8, refname, name)) return Oid.parseHex(line[0..Oid.hex_len]) catch error.InvalidRef;
    }
}

test findPacked {
    const text =
        "# pack-refs with: peeled fully-peeled sorted \n" ++
        "3f786850e387550fdab836ed7e6dc881de23001b refs/heads/main\n" ++
        "89e6c98d92887913cadf06b2adb97f26cde4849b refs/tags/v1\n" ++
        "^4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 refs/remotes/origin/main\n";
    var r: Io.Reader = .fixed(text);
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &(try findPacked(&r, "refs/remotes/origin/main")).?.toHex());
    r = .fixed(text);
    try std.testing.expectEqualStrings("89e6c98d92887913cadf06b2adb97f26cde4849b", &(try findPacked(&r, "refs/tags/v1")).?.toHex());
    r = .fixed(text);
    try std.testing.expectEqual(@as(?Oid, null), try findPacked(&r, "refs/heads/nope"));
}

test isPerWorktree {
    try std.testing.expect(isPerWorktree("HEAD"));
    try std.testing.expect(isPerWorktree("refs/bisect/bad"));
    try std.testing.expect(!isPerWorktree("refs/heads/main"));
}
