//! Git's binary delta format, used by OFS_DELTA and REF_DELTA pack entries.
//!
//!   delta  := src_size:varint dst_size:varint instruction*
//!   copy   := 1xxxxxxx [offset bytes per bits 0-3] [size bytes per bits 4-6]
//!             (size 0 means 0x10000)
//!   insert := 0nnnnnnn n literal bytes (n = 1..127)

const std = @import("std");

pub const Error = error{InvalidDelta};

/// Size of the object the delta produces, without applying it.
pub fn resultSize(delta: []const u8) Error!usize {
    var pos: usize = 0;
    _ = try varint(delta, &pos);
    return varint(delta, &pos);
}

/// Applies `delta` to `base`, writing exactly `out.len` bytes into `out`
/// (`out.len` must equal `resultSize(delta)`).
pub fn apply(base: []const u8, delta: []const u8, out: []u8) Error!void {
    var pos: usize = 0;
    if (try varint(delta, &pos) != base.len) return error.InvalidDelta;
    if (try varint(delta, &pos) != out.len) return error.InvalidDelta;

    var written: usize = 0;
    while (pos < delta.len) {
        const op = delta[pos];
        pos += 1;
        if (op & 0x80 != 0) {
            var offset: usize = 0;
            var size: usize = 0;
            inline for (0..4) |i| {
                if (op & (1 << i) != 0) {
                    if (pos >= delta.len) return error.InvalidDelta;
                    offset |= @as(usize, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            inline for (0..3) |i| {
                if (op & (0x10 << i) != 0) {
                    if (pos >= delta.len) return error.InvalidDelta;
                    size |= @as(usize, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            if (size == 0) size = 0x10000;
            if (offset + size > base.len or written + size > out.len) return error.InvalidDelta;
            @memcpy(out[written..][0..size], base[offset..][0..size]);
            written += size;
        } else if (op != 0) {
            const n: usize = op;
            if (pos + n > delta.len or written + n > out.len) return error.InvalidDelta;
            @memcpy(out[written..][0..n], delta[pos..][0..n]);
            written += n;
            pos += n;
        } else {
            return error.InvalidDelta; // opcode 0 is reserved
        }
    }
    if (written != out.len) return error.InvalidDelta;
}

/// Little-endian base-128 varint, as used in delta headers.
fn varint(buf: []const u8, pos: *usize) Error!usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= buf.len or shift > 56) return error.InvalidDelta;
        const b = buf[pos.*];
        pos.* += 1;
        result |= @as(usize, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
    }
}

test "copy and insert" {
    const base = "the quick brown fox";
    // src=19, dst=20; copy(4,"quick "->6 bytes at 4); insert "red "; copy(16,3) "fox"; insert "!!" ... build:
    const delta = [_]u8{
        19, 15, // sizes
        0x80 | 0x01 | 0x10, 4, 6, // copy offset 4 size 6: "quick "
        4, 'r', 'e', 'd', ' ', // insert "red "
        0x80 | 0x01 | 0x10, 16, 3, // copy offset 16 size 3: "fox"
        2, '!', '!', // insert "!!"
    };
    try std.testing.expectEqual(@as(usize, 15), try resultSize(&delta));
    var out: [15]u8 = undefined;
    try apply(base, &delta, &out);
    try std.testing.expectEqualStrings("quick red fox!!", &out);
}

test "copy with implicit 0x10000 size and multi-byte offset" {
    const base = try std.testing.allocator.alloc(u8, 0x10100);
    defer std.testing.allocator.free(base);
    for (base, 0..) |*b, i| b.* = @truncate(i);
    // src = 0x10100 (varint 0x80,0x82,0x04), dst = 0x10000 (0x80,0x80,0x04)
    const delta = [_]u8{ 0x80, 0x82, 0x04, 0x80, 0x80, 0x04, 0x80 | 0x01 | 0x02, 0x00, 0x01 };
    const out = try std.testing.allocator.alloc(u8, 0x10000);
    defer std.testing.allocator.free(out);
    try apply(base, &delta, out);
    try std.testing.expectEqualSlices(u8, base[0x100..][0..0x10000], out);
}

test "malformed deltas are rejected" {
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidDelta, apply("abc", &.{ 3, 4, 0 }, &out)); // reserved opcode
    try std.testing.expectError(error.InvalidDelta, apply("abc", &.{ 3, 4, 0x91, 2, 3 }, &out)); // copy past base end
    try std.testing.expectError(error.InvalidDelta, apply("abc", &.{ 2, 4 }, &out)); // wrong base size
    try std.testing.expectError(error.InvalidDelta, apply("abc", &.{ 3, 4, 2, 'x', 'y' }, &out)); // too short
    try std.testing.expectError(error.InvalidDelta, apply("abc", &.{ 3, 4, 9, 'x' }, &out)); // insert past delta end
    try std.testing.expectError(error.InvalidDelta, resultSize(&.{0x80}));
}
