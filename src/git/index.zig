//! The index (`.git/index`): versions 2, 3 and 4, plus the TREE (cache
//! tree) extension. Split and sparse indexes are rejected as unsupported.
//!
//! Format: "DIRC" version:u32 count:u32, then `count` entries, then
//! extensions (4-byte signature + u32 size), then a trailing hash.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Oid = @import("oid.zig").Oid;

pub const Entry = struct {
    ctime_s: u32,
    ctime_ns: u32,
    mtime_s: u32,
    mtime_ns: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u32,
    oid: Oid,
    /// 0 for normal entries, 1-3 for the sides of a merge conflict.
    stage: u2,
    assume_valid: bool,
    skip_worktree: bool,
    intent_to_add: bool,
    path: []const u8,
};

/// One node of the cache tree. `entry_count` < 0 means invalidated.
pub const CacheTree = struct {
    name: []const u8,
    entry_count: i32,
    oid: ?Oid,
    children: []CacheTree,

    pub fn child(t: *const CacheTree, name: []const u8) ?*const CacheTree {
        for (t.children) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

pub const Index = struct {
    version: u32,
    entries: []Entry,
    tree: ?CacheTree,
};

pub const Error = error{ InvalidIndex, UnsupportedIndex } || Allocator.Error;

pub fn parse(arena: Allocator, data: []const u8) Error!Index {
    if (data.len < 12 + Oid.len or !std.mem.eql(u8, data[0..4], "DIRC")) return error.InvalidIndex;
    const version = std.mem.readInt(u32, data[4..8], .big);
    if (version < 2 or version > 4) return error.UnsupportedIndex;
    const count = std.mem.readInt(u32, data[8..12], .big);
    const body_end = data.len - Oid.len; // trailing checksum
    if (count > body_end / 62) return error.InvalidIndex;

    const entries = try arena.alloc(Entry, count);
    var pos: usize = 12;
    var prev_path: []const u8 = "";
    for (entries) |*e| {
        if (pos + 62 > body_end) return error.InvalidIndex;
        const start = pos;
        const w = struct {
            fn u(d: []const u8, p: usize) u32 {
                return std.mem.readInt(u32, d[p..][0..4], .big);
            }
        }.u;
        const flags = std.mem.readInt(u16, data[pos + 60 ..][0..2], .big);
        e.* = .{
            .ctime_s = w(data, pos),
            .ctime_ns = w(data, pos + 4),
            .mtime_s = w(data, pos + 8),
            .mtime_ns = w(data, pos + 12),
            .dev = w(data, pos + 16),
            .ino = w(data, pos + 20),
            .mode = w(data, pos + 24),
            .uid = w(data, pos + 28),
            .gid = w(data, pos + 32),
            .size = w(data, pos + 36),
            .oid = Oid.fromSlice(data[pos + 40 ..][0..20]),
            .stage = @truncate(flags >> 12),
            .assume_valid = flags & 0x8000 != 0,
            .skip_worktree = false,
            .intent_to_add = false,
            .path = "",
        };
        pos += 62;
        if (flags & 0x4000 != 0) {
            if (version < 3 or pos + 2 > body_end) return error.InvalidIndex;
            const ext = std.mem.readInt(u16, data[pos..][0..2], .big);
            e.skip_worktree = ext & 0x4000 != 0;
            e.intent_to_add = ext & 0x2000 != 0;
            pos += 2;
        }
        if (version == 4) {
            // Path = previous path minus N trailing bytes, plus a NUL-terminated suffix.
            const strip = try readVarint(data[0..body_end], &pos);
            if (strip > prev_path.len) return error.InvalidIndex;
            const nul = std.mem.indexOfScalarPos(u8, data[0..body_end], pos, 0) orelse return error.InvalidIndex;
            const keep = prev_path[0 .. prev_path.len - strip];
            const path = try arena.alloc(u8, keep.len + (nul - pos));
            @memcpy(path[0..keep.len], keep);
            @memcpy(path[keep.len..], data[pos..nul]);
            e.path = path;
            pos = nul + 1;
        } else {
            const nul = std.mem.indexOfScalarPos(u8, data[0..body_end], pos, 0) orelse return error.InvalidIndex;
            e.path = data[pos..nul];
            // Entries are padded with 1-8 NULs to a multiple of 8 bytes.
            pos = start + std.mem.alignForward(usize, nul - start + 1, 8);
        }
        if (e.mode == 0o40000) return error.UnsupportedIndex; // sparse-index directory entry
        prev_path = e.path;
    }

    var tree: ?CacheTree = null;
    while (pos + 8 <= body_end) {
        const sig = data[pos..][0..4];
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;
        if (pos + size > body_end) return error.InvalidIndex;
        const ext = data[pos..][0..size];
        if (std.mem.eql(u8, sig, "TREE")) {
            var tpos: usize = 0;
            tree = parseCacheTree(arena, ext, &tpos) catch null; // a bad cache tree is just ignored
        } else if (std.mem.eql(u8, sig, "link") or std.mem.eql(u8, sig, "sdir")) {
            return error.UnsupportedIndex; // split index / sparse index
        }
        // Other extensions (REUC, UNTR, FSMN, EOIE, IEOT, ...) are optional for readers.
        pos += size;
    }
    return .{ .version = version, .entries = entries, .tree = tree };
}

/// "path\0<entry_count> <subtree_count>\n[oid]" followed by subtrees, recursively.
fn parseCacheTree(arena: Allocator, d: []const u8, pos: *usize) Error!CacheTree {
    const nul = std.mem.indexOfScalarPos(u8, d, pos.*, 0) orelse return error.InvalidIndex;
    const name = d[pos.*..nul];
    const space = std.mem.indexOfScalarPos(u8, d, nul + 1, ' ') orelse return error.InvalidIndex;
    const nl = std.mem.indexOfScalarPos(u8, d, space + 1, '\n') orelse return error.InvalidIndex;
    const entry_count = std.fmt.parseInt(i32, d[nul + 1 .. space], 10) catch return error.InvalidIndex;
    const subtrees = std.fmt.parseInt(u32, d[space + 1 .. nl], 10) catch return error.InvalidIndex;
    pos.* = nl + 1;
    var oid: ?Oid = null;
    if (entry_count >= 0) {
        if (pos.* + Oid.len > d.len) return error.InvalidIndex;
        oid = Oid.fromSlice(d[pos.*..][0..Oid.len]);
        pos.* += Oid.len;
    }
    if (subtrees > d.len) return error.InvalidIndex;
    const children = try arena.alloc(CacheTree, subtrees);
    for (children) |*c| c.* = try parseCacheTree(arena, d, pos);
    return .{ .name = name, .entry_count = entry_count, .oid = oid, .children = children };
}

/// Big-endian "offset" varint used by index v4 (same scheme as OFS_DELTA).
fn readVarint(d: []const u8, pos: *usize) Error!usize {
    if (pos.* >= d.len) return error.InvalidIndex;
    var b = d[pos.*];
    pos.* += 1;
    var v: usize = b & 0x7f;
    while (b & 0x80 != 0) {
        if (pos.* >= d.len or v > (std.math.maxInt(usize) >> 8)) return error.InvalidIndex;
        b = d[pos.*];
        pos.* += 1;
        v = ((v + 1) << 7) | (b & 0x7f);
    }
    return v;
}

fn testEntry(buf: *std.ArrayList(u8), gpa: Allocator, path: []const u8, flags_extra: ?u16, version: u32, strip: ?u8) !void {
    const start = buf.items.len;
    var fixed: [62]u8 = @splat(0);
    std.mem.writeInt(u32, fixed[24..28], 0o100644, .big);
    std.mem.writeInt(u32, fixed[36..40], 7, .big);
    @memset(fixed[40..60], 0xab);
    var flags: u16 = @intCast(@min(path.len, 0xfff));
    if (flags_extra != null) flags |= 0x4000;
    std.mem.writeInt(u16, fixed[60..62], flags, .big);
    try buf.appendSlice(gpa, &fixed);
    if (flags_extra) |x| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, x, .big);
        try buf.appendSlice(gpa, &b);
    }
    if (version == 4) {
        try buf.append(gpa, strip.?);
        try buf.appendSlice(gpa, path);
        try buf.append(gpa, 0);
    } else {
        try buf.appendSlice(gpa, path);
        const len = buf.items.len - start + 1;
        try buf.appendNTimes(gpa, 0, std.mem.alignForward(usize, len, 8) - len + 1);
    }
}

test "parse v2 and v3 entries with extended flags and a cache tree" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "DIRC\x00\x00\x00\x03\x00\x00\x00\x02");
    try testEntry(&buf, gpa, "a.txt", null, 3, null);
    try testEntry(&buf, gpa, "dir/b", 0x4000, 3, null);
    // TREE: root (2 entries, 1 subtree) + "dir" (1 entry, invalid -1 → no oid)
    const tree_ext = "\x002 1\n" ++ ([_]u8{0x11} ** 20) ++ "dir\x00-1 0\n";
    try buf.appendSlice(gpa, "TREE");
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, tree_ext.len, .big);
    try buf.appendSlice(gpa, &size);
    try buf.appendSlice(gpa, tree_ext);
    try buf.appendNTimes(gpa, 0, 20); // checksum (not verified)

    const idx = try parse(arena_state.allocator(), buf.items);
    try std.testing.expectEqual(@as(usize, 2), idx.entries.len);
    try std.testing.expectEqualStrings("a.txt", idx.entries[0].path);
    try std.testing.expectEqualStrings("dir/b", idx.entries[1].path);
    try std.testing.expect(idx.entries[1].skip_worktree);
    try std.testing.expectEqual(@as(u32, 7), idx.entries[0].size);
    const t = idx.tree.?;
    try std.testing.expectEqual(@as(i32, 2), t.entry_count);
    try std.testing.expectEqual(@as(u8, 0x11), t.oid.?.bytes[0]);
    try std.testing.expectEqual(@as(?Oid, null), t.child("dir").?.oid);
}

test "parse v4 prefix-compressed paths" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "DIRC\x00\x00\x00\x04\x00\x00\x00\x03");
    try testEntry(&buf, gpa, "src/main.zig", null, 4, 0);
    try testEntry(&buf, gpa, "odule.zig", null, 4, 7); // "src/main.zig" - "ain.zig" => "src/m" + "odule.zig"
    try testEntry(&buf, gpa, "tests/x", null, 4, 14);
    try buf.appendNTimes(gpa, 0, 20);
    const idx = try parse(arena_state.allocator(), buf.items);
    try std.testing.expectEqualStrings("src/main.zig", idx.entries[0].path);
    try std.testing.expectEqualStrings("src/module.zig", idx.entries[1].path);
    try std.testing.expectEqualStrings("tests/x", idx.entries[2].path);
}

test "rejects garbage and unsupported indexes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.InvalidIndex, parse(a, "nope"));
    try std.testing.expectError(error.UnsupportedIndex, parse(a, "DIRC\x00\x00\x00\x05\x00\x00\x00\x00" ++ [_]u8{0} ** 20));
    try std.testing.expectError(error.InvalidIndex, parse(a, "DIRC\x00\x00\x00\x02\x00\x00\x00\x09" ++ [_]u8{0} ** 20));
}
