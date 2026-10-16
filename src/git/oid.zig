//! Object ids. Only SHA-1 repositories are supported for now; SHA-256
//! repositories are detected (extensions.objectFormat) and rejected.

const std = @import("std");

pub const Oid = struct {
    bytes: [len]u8,

    pub const len = 20;
    pub const hex_len = 40;
    pub const zero: Oid = .{ .bytes = @splat(0) };

    pub fn parseHex(hex: []const u8) error{InvalidOid}!Oid {
        if (hex.len != hex_len) return error.InvalidOid;
        var oid: Oid = undefined;
        _ = std.fmt.hexToBytes(&oid.bytes, hex) catch return error.InvalidOid;
        return oid;
    }

    pub fn fromSlice(raw: []const u8) Oid {
        return .{ .bytes = raw[0..len].* };
    }

    pub fn toHex(oid: Oid) [hex_len]u8 {
        return std.fmt.bytesToHex(oid.bytes, .lower);
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn order(a: Oid, b: Oid) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    /// The id git assigns to an object: SHA-1 of "<kind> <size>\0<data>".
    pub fn hashObject(kind: []const u8, data: []const u8) Oid {
        var h = std.crypto.hash.Sha1.init(.{});
        var header_buf: [32]u8 = undefined;
        h.update(std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ kind, data.len }) catch unreachable);
        h.update(data);
        return .{ .bytes = h.finalResult() };
    }
};

test Oid {
    const hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"; // the empty blob
    const oid = try Oid.parseHex(hex);
    try std.testing.expectEqualStrings(hex, &oid.toHex());
    try std.testing.expect(oid.eql(Oid.hashObject("blob", "")));
    try std.testing.expectError(error.InvalidOid, Oid.parseHex("e69d"));
    try std.testing.expectError(error.InvalidOid, Oid.parseHex("z69de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
}
