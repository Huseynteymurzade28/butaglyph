//! Object database: loose objects and packfiles (with OFS/REF deltas).
//!
//! Pack and index files are memory-mapped, so a lookup touches only the
//! pages it needs. All returned object data is allocated from the arena the
//! database was opened with and lives as long as that arena. A short-lived
//! process may simply exit; a long-lived one (the daemon) calls `close` to
//! unmap the packs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Oid = @import("oid.zig").Oid;
const delta = @import("delta.zig");

pub const Kind = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,

    pub fn name(k: Kind) []const u8 {
        return @tagName(k);
    }

    fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

pub const Object = struct {
    kind: Kind,
    data: []const u8,
};

pub const Error = error{
    ObjectNotFound,
    CorruptObject,
    UnsupportedPackVersion,
    DeltaChainTooDeep,
} || delta.Error || Allocator.Error || Io.Cancelable;

/// Deltas deeper than this are treated as corruption (git's default max is 50).
const max_delta_depth = 4096;
/// Objects larger than this are not inflated (prompt data never needs them).
const max_object_size = 256 * 1024 * 1024;

pub const Odb = struct {
    io: Io,
    arena: Allocator,
    objects_dir: []const u8,
    packs: []Pack,
    /// flate history window, reused for every inflate.
    window: []u8,
    /// Resolved delta bases by (pack, offset). Tree walks hit the same bases
    /// over and over; caching them avoids re-applying whole delta chains.
    base_cache: std.AutoHashMapUnmanaged(CacheKey, Object) = .empty,
    /// Delta entries resolved so far, by kind (diagnostics and tests).
    stats: struct { ofs_deltas: u32 = 0, ref_deltas: u32 = 0 } = .{},

    const CacheKey = struct { pack: u32, offset: u64 };

    pub fn open(io: Io, arena: Allocator, objects_dir: []const u8) !Odb {
        var packs: std.ArrayList(Pack) = .empty;
        errdefer for (packs.items) |*p| p.close(io);
        const pack_dir_path = try std.fmt.allocPrint(arena, "{s}/pack", .{objects_dir});
        if (Io.Dir.cwd().openDir(io, pack_dir_path, .{ .iterate = true })) |pack_dir_const| {
            var pack_dir = pack_dir_const;
            defer pack_dir.close(io);
            var it = pack_dir.iterate();
            while (try it.next(io)) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
                const base = entry.name[0 .. entry.name.len - ".idx".len];
                var pack = Pack.open(io, pack_dir, base, arena) catch continue; // skip unusable packs
                packs.append(arena, pack) catch |e| {
                    pack.close(io);
                    return e;
                };
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        return .{
            .io = io,
            .arena = arena,
            .objects_dir = objects_dir,
            .packs = packs.items,
            .window = try arena.alloc(u8, flate.max_window_len),
        };
    }

    /// Unmaps the packfiles. Object data already returned stays valid (it
    /// lives in the arena); the database must not be used afterwards.
    pub fn close(odb: *Odb) void {
        for (odb.packs) |*p| p.close(odb.io);
        odb.packs = &.{};
    }

    pub fn read(odb: *Odb, oid: Oid) Error!Object {
        for (odb.packs, 0..) |*pack, i| {
            if (pack.find(oid)) |offset| return odb.readPacked(@intCast(i), offset, 0);
        }
        return odb.readLoose(oid);
    }

    pub fn contains(odb: *Odb, oid: Oid) bool {
        for (odb.packs) |*pack| if (pack.find(oid) != null) return true;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = loosePath(&path_buf, odb.objects_dir, oid) catch return false;
        Io.Dir.cwd().access(odb.io, path, .{}) catch return false;
        return true;
    }

    fn readLoose(odb: *Odb, oid: Oid) Error!Object {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = loosePath(&path_buf, odb.objects_dir, oid) catch return error.ObjectNotFound;
        const compressed = Io.Dir.cwd().readFileAlloc(odb.io, path, odb.arena, .limited(max_object_size)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.ObjectNotFound,
        };
        var input: Io.Reader = .fixed(compressed);
        var z: flate.Decompress = .init(&input, .zlib, odb.window);
        const header = z.reader.takeDelimiterExclusive(0) catch return error.CorruptObject;
        z.reader.toss(1);
        const space = std.mem.indexOfScalar(u8, header, ' ') orelse return error.CorruptObject;
        const kind = Kind.parse(header[0..space]) orelse return error.CorruptObject;
        const size = std.fmt.parseInt(usize, header[space + 1 ..], 10) catch return error.CorruptObject;
        if (size > max_object_size) return error.CorruptObject;
        const data = try odb.arena.alloc(u8, size);
        z.reader.readSliceAll(data) catch return error.CorruptObject;
        return .{ .kind = kind, .data = data };
    }

    fn readPacked(odb: *Odb, pack_index: u32, offset: u64, depth: usize) Error!Object {
        if (depth > max_delta_depth) return error.DeltaChainTooDeep;
        const key: CacheKey = .{ .pack = pack_index, .offset = offset };
        if (odb.base_cache.get(key)) |cached| return cached;

        const pack = &odb.packs[pack_index];
        const entry = try pack.entryHeader(offset);
        const obj: Object = switch (entry.type) {
            1...4 => .{
                .kind = @enumFromInt(entry.type),
                .data = try odb.inflate(pack.data, entry.data_offset, entry.size),
            },
            6, 7 => blk: {
                const base: Object = if (entry.type == 6)
                    try odb.readPacked(pack_index, entry.base_offset, depth + 1)
                else
                    try odb.readRefBase(entry.base_oid, depth + 1);
                if (entry.type == 6) odb.stats.ofs_deltas += 1 else odb.stats.ref_deltas += 1;
                const d = try odb.inflate(pack.data, entry.data_offset, entry.size);
                const out = try odb.arena.alloc(u8, try delta.resultSize(d));
                try delta.apply(base.data, d, out);
                break :blk .{ .kind = base.kind, .data = out };
            },
            else => return error.CorruptObject,
        };
        // Only cache objects that are likely to be reused as bases.
        if (obj.kind != .blob) try odb.base_cache.put(odb.arena, key, obj);
        return obj;
    }

    fn readRefBase(odb: *Odb, oid: Oid, depth: usize) Error!Object {
        for (odb.packs, 0..) |*pack, i| {
            if (pack.find(oid)) |offset| return odb.readPacked(@intCast(i), offset, depth);
        }
        return odb.readLoose(oid);
    }

    fn inflate(odb: *Odb, data: []const u8, offset: u64, size: u64) Error![]u8 {
        if (size > max_object_size or offset >= data.len) return error.CorruptObject;
        var input: Io.Reader = .fixed(data[@intCast(offset)..]);
        var z: flate.Decompress = .init(&input, .zlib, odb.window);
        const out = try odb.arena.alloc(u8, @intCast(size));
        z.reader.readSliceAll(out) catch return error.CorruptObject;
        return out;
    }
};

fn loosePath(buf: []u8, objects_dir: []const u8, oid: Oid) ![]const u8 {
    const hex = oid.toHex();
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ objects_dir, hex[0..2], hex[2..] });
}

/// A packfile and its version-2 index, both memory-mapped.
const Pack = struct {
    idx: []const u8,
    data: []const u8,
    count: u32,
    /// The mappings behind `idx` and `data` (null when the file was read
    /// into the arena instead, or is empty).
    maps: [2]?Io.File.MemoryMap = .{ null, null },

    const idx_magic = "\xfftOc";

    fn open(io: Io, dir: Io.Dir, base: []const u8, arena: Allocator) !Pack {
        var name_buf: [std.fs.max_name_bytes + 8]u8 = undefined;
        var idx_file = try mapFile(io, dir, try std.fmt.bufPrint(&name_buf, "{s}.idx", .{base}), arena);
        errdefer if (idx_file.map) |*mm| mm.destroy(io);
        var data_file = try mapFile(io, dir, try std.fmt.bufPrint(&name_buf, "{s}.pack", .{base}), arena);
        errdefer if (data_file.map) |*mm| mm.destroy(io);
        const idx = idx_file.bytes;
        const data = data_file.bytes;

        // v2 idx: magic, version, 256-entry fanout, then oids, crcs, offsets.
        if (idx.len < 8 + 256 * 4 or !std.mem.eql(u8, idx[0..4], idx_magic)) return error.UnsupportedPackVersion;
        if (std.mem.readInt(u32, idx[4..8], .big) != 2) return error.UnsupportedPackVersion;
        if (data.len < 12 or !std.mem.eql(u8, data[0..4], "PACK")) return error.CorruptObject;
        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedPackVersion;

        const count = std.mem.readInt(u32, idx[8 + 255 * 4 ..][0..4], .big);
        if (idx.len < 8 + 256 * 4 + @as(usize, count) * (20 + 4 + 4)) return error.CorruptObject;
        return .{ .idx = idx, .data = data, .count = count, .maps = .{ idx_file.map, data_file.map } };
    }

    fn close(p: *Pack, io: Io) void {
        for (&p.maps) |*m| if (m.*) |*mm| {
            mm.destroy(io);
            m.* = null;
        };
    }

    fn fanout(p: *const Pack, i: usize) u32 {
        return std.mem.readInt(u32, p.idx[8 + i * 4 ..][0..4], .big);
    }

    fn oidAt(p: *const Pack, i: usize) *const [20]u8 {
        return p.idx[8 + 256 * 4 + i * 20 ..][0..20];
    }

    /// Binary search within the fanout bucket. Returns the pack offset.
    fn find(p: *const Pack, oid: Oid) ?u64 {
        const first = oid.bytes[0];
        var lo: usize = if (first == 0) 0 else p.fanout(first - 1);
        var hi: usize = p.fanout(first);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, p.oidAt(mid), &oid.bytes)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return p.offsetAt(mid),
            }
        }
        return null;
    }

    fn offsetAt(p: *const Pack, i: usize) ?u64 {
        const offsets = 8 + 256 * 4 + @as(usize, p.count) * 24;
        const small = std.mem.readInt(u32, p.idx[offsets + i * 4 ..][0..4], .big);
        if (small & 0x8000_0000 == 0) return small;
        const large_table = offsets + @as(usize, p.count) * 4;
        const j = small & 0x7fff_ffff;
        if (large_table + (j + 1) * 8 > p.idx.len) return null;
        return std.mem.readInt(u64, p.idx[large_table + j * 8 ..][0..8], .big);
    }

    const EntryHeader = struct {
        type: u3,
        size: u64,
        data_offset: u64,
        base_offset: u64 = 0,
        base_oid: Oid = .zero,
    };

    fn entryHeader(p: *const Pack, offset: u64) Error!EntryHeader {
        if (offset >= p.data.len) return error.CorruptObject;
        var pos: usize = @intCast(offset);
        var b = p.data[pos];
        pos += 1;
        const typ: u3 = @truncate(b >> 4);
        var size: u64 = b & 0x0f;
        var shift: u6 = 4;
        while (b & 0x80 != 0) {
            if (pos >= p.data.len or shift > 57) return error.CorruptObject;
            b = p.data[pos];
            pos += 1;
            size |= @as(u64, b & 0x7f) << shift;
            shift += 7;
        }
        var h: EntryHeader = .{ .type = typ, .size = size, .data_offset = 0 };
        switch (typ) {
            6 => {
                // Offset encoding: each continuation adds one before shifting,
                // so there are no redundant encodings.
                if (pos >= p.data.len) return error.CorruptObject;
                b = p.data[pos];
                pos += 1;
                var rel: u64 = b & 0x7f;
                while (b & 0x80 != 0) {
                    if (pos >= p.data.len or rel > (std.math.maxInt(u64) >> 8)) return error.CorruptObject;
                    b = p.data[pos];
                    pos += 1;
                    rel = ((rel + 1) << 7) | (b & 0x7f);
                }
                if (rel == 0 or rel > offset) return error.CorruptObject;
                h.base_offset = offset - rel;
            },
            7 => {
                if (pos + 20 > p.data.len) return error.CorruptObject;
                h.base_oid = Oid.fromSlice(p.data[pos..][0..20]);
                pos += 20;
            },
            else => {},
        }
        h.data_offset = pos;
        return h;
    }
};

const MappedFile = struct { bytes: []const u8, map: ?Io.File.MemoryMap };

fn mapFile(io: Io, dir: Io.Dir, name: []const u8, arena: Allocator) !MappedFile {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const len = try file.length(io);
    if (len == 0) return .{ .bytes = &.{}, .map = null };
    if (Io.File.MemoryMap.create(io, file, .{
        .len = @intCast(len),
        .protection = .{ .read = true, .write = false },
        .populate = false,
    })) |mm| {
        return .{ .bytes = mm.memory[0..@intCast(len)], .map = mm };
    } else |_| {
        const buf = try arena.alloc(u8, @intCast(len));
        if (try file.readPositionalAll(io, buf, 0) != len) return error.CorruptObject;
        return .{ .bytes = buf, .map = null };
    }
}

test "pack entry header and offset encoding" {
    // OFS_DELTA at offset 300: type 6, size 5 (0x65); offset bytes 0x81 0x00
    // decode to ((1 + 1) << 7) | 0 = 256.
    var data: [400]u8 = @splat(0);
    @memcpy(data[0..4], "PACK");
    data[300] = 0x65; // type 6, size 5
    data[301] = 0x81;
    data[302] = 0x00;
    const p: Pack = .{ .idx = &.{}, .data = &data, .count = 0 };
    const h = try p.entryHeader(300);
    try std.testing.expectEqual(@as(u3, 6), h.type);
    try std.testing.expectEqual(@as(u64, 5), h.size);
    try std.testing.expectEqual(@as(u64, 300 - 256), h.base_offset);
    try std.testing.expectEqual(@as(u64, 303), h.data_offset);

    // Multi-byte size: 0xb4 = continue | type 3 | low bits 4, then 0x23 => 4 | 0x23 << 4 = 0x234
    data[350] = 0x80 | (3 << 4) | 0x4;
    data[351] = 0x23;
    const h2 = try p.entryHeader(350);
    try std.testing.expectEqual(@as(u3, 3), h2.type);
    try std.testing.expectEqual(@as(u64, 0x234), h2.size);

    // A base offset pointing before the start of the file is corrupt.
    data[360] = 0x60;
    data[361] = 0x7f; // rel 127 ok
    _ = try p.entryHeader(360);
    data[10] = 0x60;
    data[11] = 0x7f; // rel 127 > offset 10
    try std.testing.expectError(error.CorruptObject, p.entryHeader(10));
}
