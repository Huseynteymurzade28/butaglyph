//! Parsing of commit and tree objects.

const std = @import("std");
const Oid = @import("oid.zig").Oid;

pub const Commit = struct {
    tree: Oid,
    /// Raw parent lines region; iterate with `parents()`.
    parent_region: []const u8,
    /// Committer timestamp (seconds since the epoch).
    time: i64,

    pub fn parents(c: Commit) ParentIterator {
        return .{ .rest = c.parent_region };
    }
};

pub const ParentIterator = struct {
    rest: []const u8,

    pub fn next(it: *ParentIterator) ?Oid {
        const prefix = "parent ";
        if (!std.mem.startsWith(u8, it.rest, prefix) or it.rest.len < prefix.len + Oid.hex_len) return null;
        const oid = Oid.parseHex(it.rest[prefix.len..][0..Oid.hex_len]) catch return null;
        it.rest = it.rest[@min(it.rest.len, prefix.len + Oid.hex_len + 1)..];
        return oid;
    }
};

pub const ParseError = error{CorruptObject};

pub fn parseCommit(data: []const u8) ParseError!Commit {
    var rest = data;
    const tree_line = takeLine(&rest) orelse return error.CorruptObject;
    if (!std.mem.startsWith(u8, tree_line, "tree ")) return error.CorruptObject;
    const tree = Oid.parseHex(tree_line["tree ".len..]) catch return error.CorruptObject;

    const parent_start = rest;
    var parent_len: usize = 0;
    var time: i64 = 0;
    while (takeLine(&rest)) |line| {
        if (line.len == 0) break; // end of headers
        if (std.mem.startsWith(u8, line, "parent ")) {
            parent_len += line.len + 1;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            // "committer Name <email> 1700000000 +0100"
            var fields = std.mem.splitBackwardsScalar(u8, line, ' ');
            _ = fields.next(); // timezone
            time = std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0;
        }
    }
    return .{ .tree = tree, .parent_region = parent_start[0..parent_len], .time = time };
}

fn takeLine(rest: *[]const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, rest.*, '\n') orelse rest.len;
    const line = rest.*[0..end];
    rest.* = rest.*[@min(rest.len, end + 1)..];
    return line;
}

pub const TreeEntry = struct {
    /// Octal mode as stored by git (e.g. 0o100644, 0o40000).
    mode: u32,
    name: []const u8,
    oid: Oid,

    pub fn isTree(e: TreeEntry) bool {
        return e.mode == 0o40000;
    }
};

pub const TreeIterator = struct {
    rest: []const u8,

    pub fn init(data: []const u8) TreeIterator {
        return .{ .rest = data };
    }

    /// Entries in git tree order. Returns error on malformed data.
    pub fn next(it: *TreeIterator) ParseError!?TreeEntry {
        if (it.rest.len == 0) return null;
        const space = std.mem.indexOfScalar(u8, it.rest, ' ') orelse return error.CorruptObject;
        const nul = std.mem.indexOfScalarPos(u8, it.rest, space, 0) orelse return error.CorruptObject;
        if (nul + 1 + Oid.len > it.rest.len) return error.CorruptObject;
        const mode = std.fmt.parseInt(u32, it.rest[0..space], 8) catch return error.CorruptObject;
        const entry: TreeEntry = .{
            .mode = mode,
            .name = it.rest[space + 1 .. nul],
            .oid = Oid.fromSlice(it.rest[nul + 1 ..][0..Oid.len]),
        };
        it.rest = it.rest[nul + 1 + Oid.len ..];
        return entry;
    }
};

test parseCommit {
    const data =
        "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
        "parent 3f786850e387550fdab836ed7e6dc881de23001b\n" ++
        "parent 89e6c98d92887913cadf06b2adb97f26cde4849b\n" ++
        "author A U Thor <a@example.com> 1700000000 +0400\n" ++
        "committer C O Mitter <c@example.com> 1700000123 -0130\n" ++
        "\n" ++
        "message\nparent not-a-header\n";
    const c = try parseCommit(data);
    try std.testing.expectEqualStrings("4b825dc642cb6eb9a060e54bf8d69288fbee4904", &c.tree.toHex());
    try std.testing.expectEqual(@as(i64, 1700000123), c.time);
    var it = c.parents();
    try std.testing.expectEqualStrings("3f786850e387550fdab836ed7e6dc881de23001b", &it.next().?.toHex());
    try std.testing.expectEqualStrings("89e6c98d92887913cadf06b2adb97f26cde4849b", &it.next().?.toHex());
    try std.testing.expectEqual(@as(?Oid, null), it.next());

    const root = try parseCommit("tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\ncommitter x <y> 5 +0000\n\nm");
    var none = root.parents();
    try std.testing.expectEqual(@as(?Oid, null), none.next());
    try std.testing.expectError(error.CorruptObject, parseCommit("parent x\n"));
}

test TreeIterator {
    const oid_a = @as([20]u8, @splat(0xaa));
    const oid_b = @as([20]u8, @splat(0xbb));
    const data = "100644 a.txt\x00" ++ oid_a ++ "40000 dir\x00" ++ oid_b;
    var it: TreeIterator = .init(data);
    const e1 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 0o100644), e1.mode);
    try std.testing.expectEqualStrings("a.txt", e1.name);
    try std.testing.expect(!e1.isTree());
    const e2 = (try it.next()).?;
    try std.testing.expect(e2.isTree());
    try std.testing.expectEqualSlices(u8, &oid_b, &e2.oid.bytes);
    try std.testing.expectEqual(@as(?TreeEntry, null), try it.next());

    var bad: TreeIterator = .init("100644 a.txt\x00short");
    try std.testing.expectError(error.CorruptObject, bad.next());
}
