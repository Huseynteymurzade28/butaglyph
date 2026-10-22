//! A small binary codec for the plain data that crosses the daemon socket:
//! module `Config`s (client to daemon) and module `Data` (daemon to client).
//!
//! Supported: void, bool, integers, enums, optionals, structs, tagged unions,
//! arrays and slices of any of these. Integers are little-endian at their
//! natural size (rounded up to whole bytes), slice lengths are u32, an
//! optional is a 0/1 byte followed by the payload. Anything else (pointers to
//! one, floats, untagged unions) is a compile error, so a module whose types
//! can't cross the socket is caught at build time.
//!
//! `fingerprint` hashes the shape of a type (field names, types, enum
//! values). Client and daemon compare fingerprints of the whole protocol
//! before talking, so binaries built from different sources never decode
//! each other's bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodeError = error{ EndOfStream, InvalidValue, OutOfMemory };

pub fn encode(comptime T: type, value: *const T, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try w.writeByte(@intFromBool(value.*)),
        .int => try w.writeInt(Wide(T), value.*, .little),
        .@"enum" => |e| try encode(e.tag_type, &@backingInt(value.*), w),
        .optional => |o| if (value.*) |*v| {
            try w.writeByte(1);
            try encode(o.child, v, w);
        } else try w.writeByte(0),
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, F| try encode(F, &@field(value.*, name), w),
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("wire: untagged union " ++ @typeName(T));
            try encode(Tag, &std.meta.activeTag(value.*), w);
            switch (value.*) {
                inline else => |*payload| try encode(@TypeOf(payload.*), payload, w),
            }
        },
        .array => |a| for (value) |*item| try encode(a.child, item, w),
        .pointer => |p| {
            if (p.size != .slice) @compileError("wire: unsupported pointer " ++ @typeName(T));
            try w.writeInt(u32, @intCast(value.len), .little);
            if (p.child == u8) return w.writeAll(value.*);
            for (value.*) |*item| try encode(p.child, item, w);
        },
        else => @compileError("wire: unsupported type " ++ @typeName(T)),
    }
}

/// Decodes a `T` from `r`, which must be a fixed reader (see
/// `decodeSlice`). Slices are allocated from `arena` (never freed
/// individually). Every length is checked against the bytes that are left,
/// so hostile input can't make it allocate more than it sent.
pub fn decode(comptime T: type, r: *std.Io.Reader, arena: Allocator) DecodeError!T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return switch (try takeByte(r)) {
            0 => false,
            1 => true,
            else => error.InvalidValue,
        },
        .int => {
            const wide = r.takeInt(Wide(T), .little) catch return error.EndOfStream;
            return std.math.cast(T, wide) orelse error.InvalidValue;
        },
        .@"enum" => |e| {
            const raw = try decode(e.tag_type, r, arena);
            return std.enums.fromInt(T, raw) orelse error.InvalidValue;
        },
        .optional => |o| return switch (try takeByte(r)) {
            0 => null,
            1 => try decode(o.child, r, arena),
            else => error.InvalidValue,
        },
        .@"struct" => |s| {
            var value: T = undefined;
            inline for (s.field_names, s.field_types) |name, F| @field(value, name) = try decode(F, r, arena);
            return value;
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse @compileError("wire: untagged union " ++ @typeName(T));
            switch (try decode(Tag, r, arena)) {
                inline else => |tag| {
                    const Payload = @FieldType(T, @tagName(tag));
                    return @unionInit(T, @tagName(tag), try decode(Payload, r, arena));
                },
            }
        },
        .array => |a| {
            var value: T = undefined;
            for (&value) |*item| item.* = try decode(a.child, r, arena);
            return value;
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("wire: unsupported pointer " ++ @typeName(T));
            const len = r.takeInt(u32, .little) catch return error.EndOfStream;
            // Every element of a sized type takes at least one byte on the wire.
            if (@sizeOf(p.child) > 0 and len > r.bufferedLen()) return error.EndOfStream;
            const items = try arena.alloc(p.child, len);
            if (p.child == u8) {
                r.readSliceAll(items) catch return error.EndOfStream;
            } else {
                for (items) |*item| item.* = try decode(p.child, r, arena);
            }
            return items;
        },
        else => @compileError("wire: unsupported type " ++ @typeName(T)),
    }
}

/// Decodes a `T` that must fill `bytes` exactly.
pub fn decodeSlice(comptime T: type, bytes: []const u8, arena: Allocator) DecodeError!T {
    var r: std.Io.Reader = .fixed(bytes);
    const value = try decode(T, &r, arena);
    if (r.bufferedLen() != 0) return error.InvalidValue;
    return value;
}

fn takeByte(r: *std.Io.Reader) error{EndOfStream}!u8 {
    return r.takeByte() catch error.EndOfStream;
}

/// Integers travel at their size rounded up to whole bytes.
fn Wide(comptime T: type) type {
    const info = @typeInfo(T).int;
    return @Int(info.signedness, std.mem.alignForward(u16, info.bits, 8));
}

/// A hash of `T`'s shape: two types with the same fingerprint encode the
/// same way. Field and tag names are included, so a renamed field changes
/// it even when the layout does not (its meaning probably changed too).
pub fn fingerprint(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var h = std.hash.Wyhash.init(0);
        shape(T, &h);
        break :blk h.final();
    };
}

fn shape(comptime T: type, h: *std.hash.Wyhash) void {
    const info = @typeInfo(T);
    h.update(@tagName(info));
    switch (info) {
        .void, .bool => {},
        .int => |i| h.update(&.{ @backingInt(i.signedness), @truncate(i.bits), @truncate(i.bits >> 8) }),
        .@"enum" => |e| {
            shape(e.tag_type, h);
            for (e.field_names, e.field_values) |name, value| {
                h.update(name);
                h.update(std.mem.asBytes(&@as(i64, value)));
            }
        },
        .optional => |o| shape(o.child, h),
        .@"struct" => |s| for (s.field_names, s.field_types) |name, F| {
            h.update(name);
            shape(F, h);
        },
        .@"union" => |u| {
            shape(u.tag_type orelse @compileError("wire: untagged union " ++ @typeName(T)), h);
            for (u.field_names, u.field_types) |name, F| {
                h.update(name);
                shape(F, h);
            }
        },
        .array => |a| {
            h.update(std.mem.asBytes(&@as(u64, a.len)));
            shape(a.child, h);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("wire: unsupported pointer " ++ @typeName(T));
            shape(p.child, h);
        },
        else => @compileError("wire: unsupported type " ++ @typeName(T)),
    }
}

const testing = std.testing;

const Sample = struct {
    flag: bool = true,
    small: u3 = 5,
    signed: i32 = -7,
    name: []const u8 = "düzəliş",
    maybe: ?u16 = null,
    color: enum(u8) { red = 1, green = 2 } = .green,
    list: []const ?[]const u8 = &.{ "a", null, "" },
    head: union(enum) { branch: []const u8, detached: [4]u8 } = .{ .detached = "abcd".* },
};

test "round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const in: Sample = .{ .maybe = 300, .head = .{ .branch = "main" } };
    try encode(Sample, &in, &w);
    const out = try decodeSlice(Sample, w.buffered(), arena.allocator());
    try testing.expectEqual(in.flag, out.flag);
    try testing.expectEqual(in.small, out.small);
    try testing.expectEqual(in.signed, out.signed);
    try testing.expectEqualStrings(in.name, out.name);
    try testing.expectEqual(in.maybe, out.maybe);
    try testing.expectEqual(in.color, out.color);
    try testing.expectEqual(@as(usize, 3), out.list.len);
    try testing.expectEqualStrings("a", out.list[0].?);
    try testing.expectEqual(@as(?[]const u8, null), out.list[1]);
    try testing.expectEqualStrings("", out.list[2].?);
    try testing.expectEqualStrings("main", out.head.branch);
}

test "decode rejects malformed input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode(Sample, &.{}, &w);
    const good = w.buffered();

    // Every truncation fails cleanly.
    for (0..good.len) |n| try testing.expectError(error.EndOfStream, decodeSlice(Sample, good[0..n], a));
    // Trailing bytes are rejected.
    var long: [257]u8 = undefined;
    @memcpy(long[0..good.len], good);
    long[good.len] = 0;
    try testing.expectError(error.InvalidValue, decodeSlice(Sample, long[0 .. good.len + 1], a));
    // Out-of-range values.
    try testing.expectError(error.InvalidValue, decodeSlice(bool, &.{2}, a));
    try testing.expectError(error.InvalidValue, decodeSlice(u3, &.{8}, a));
    try testing.expectError(error.InvalidValue, decodeSlice(enum(u8) { x = 1 }, &.{2}, a));
    // A huge length can't trigger a huge allocation.
    try testing.expectError(error.EndOfStream, decodeSlice([]const u8, &.{ 0xff, 0xff, 0xff, 0x7f, 'x' }, a));
}

test fingerprint {
    const A = struct { x: u32, y: []const u8 };
    const B = struct { x: u32, y: []const u8 };
    const C = struct { x: u32, z: []const u8 };
    const D = struct { x: u16, y: []const u8 };
    try testing.expectEqual(fingerprint(A), fingerprint(B));
    try testing.expect(fingerprint(A) != fingerprint(C));
    try testing.expect(fingerprint(A) != fingerprint(D));
}
