//! Rename detection for staged changes, as git's diffcore-rename does it
//! for `git status`: a path deleted from HEAD and a path added to the index
//! form one rename when their contents are at least 50% alike.
//!
//! The passes, in git's order:
//!
//! * exact: the same blob (and, unless both are regular files, the same mode)
//! * basename: a source and a destination whose file name is unique among
//!   the remaining sources and destinations alike, and at least halfway
//!   between the minimum score and identical (75% by default)
//! * matrix: every remaining pair is scored, the four best sources kept
//!   per destination, and the best pairs taken first, each path once.
//!   Skipped when sources × destinations exceeds the rename limit squared.
//!
//! Similarity is git's "spanhash" estimate: both blobs are cut into lines
//! (or 64-byte pieces), and the score is the number of bytes of the
//! source found again in the destination, over the larger size. Only
//! regular files are compared this way; symlinks and submodules are
//! renamed only on an exact match. Copy detection is not done.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Oid = @import("oid.zig").Oid;

pub const max_score = 60000;
/// git's default `-M50%`.
pub const default_score = max_score / 2;
/// git's default `diff.renameLimit`.
pub const default_limit = 1000;

pub const File = struct {
    path: []const u8,
    mode: u32,
    oid: Oid,
};

pub const Options = struct {
    min_score: u32 = default_score,
    /// 0 means unlimited.
    limit: u32 = default_limit,
};

/// Counts the renames between `sources` (deleted paths) and `dests` (added
/// paths), each in index order. `blobs.read(oid)` returns a blob's content;
/// it is only called for regular files.
pub fn count(arena: Allocator, blobs: anytype, sources: []const File, dests: []const File, opts: Options) !u32 {
    if (sources.len == 0 or dests.len == 0) return 0;
    var r: Renamer(@TypeOf(blobs)) = .{
        .arena = arena,
        .blobs = blobs,
        .sources = sources,
        .dests = dests,
        .src_used = try arena.alloc(bool, sources.len),
        .dst_done = try arena.alloc(bool, dests.len),
        .src_spans = try arena.alloc(?Spans, sources.len),
        .dst_spans = try arena.alloc(?Spans, dests.len),
        .min_score = opts.min_score,
    };
    @memset(r.src_used, false);
    @memset(r.dst_done, false);
    @memset(r.src_spans, null);
    @memset(r.dst_spans, null);

    try r.exact();
    if (r.min_score >= max_score) return r.renames;
    try r.basenames();

    var n_src: u64 = 0;
    for (r.src_used) |u| n_src += @intFromBool(!u);
    var n_dst: u64 = 0;
    for (r.dst_done) |d| n_dst += @intFromBool(!d);
    if (n_src == 0 or n_dst == 0) return r.renames;
    if (opts.limit > 0 and n_src * n_dst > @as(u64, opts.limit) * opts.limit) return r.renames;
    try r.matrix();
    return r.renames;
}

fn Renamer(comptime Blobs: type) type {
    return struct {
        arena: Allocator,
        blobs: Blobs,
        sources: []const File,
        dests: []const File,
        src_used: []bool,
        dst_done: []bool,
        src_spans: []?Spans,
        dst_spans: []?Spans,
        min_score: u32,
        renames: u32 = 0,

        const Self = @This();

        fn pair(r: *Self, src: usize, dst: usize) void {
            r.src_used[src] = true;
            r.dst_done[dst] = true;
            r.renames += 1;
        }

        fn exact(r: *Self) !void {
            var by_oid: std.AutoHashMapUnmanaged(Oid, std.ArrayList(u32)) = .empty;
            for (r.sources, 0..) |s, i| {
                const gop = try by_oid.getOrPut(r.arena, s.oid);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(r.arena, @intCast(i));
            }
            for (r.dests, 0..) |d, di| {
                const list = by_oid.get(d.oid) orelse continue;
                var best: ?u32 = null;
                var best_score: u32 = 0;
                // Like git, look at no more than 100 unused alternatives.
                var budget: u32 = 100;
                for (list.items) |si| {
                    const s = r.sources[si];
                    if ((!isRegular(s.mode) or !isRegular(d.mode)) and s.mode != d.mode) continue;
                    if (r.src_used[si]) continue;
                    const score = 1 + @intFromBool(basenameSame(s.path, d.path));
                    if (best == null or score > best_score) {
                        best = si;
                        best_score = score;
                        if (score == 2) break;
                    }
                    budget -= 1;
                    if (budget == 0) break;
                }
                if (best) |si| r.pair(si, di);
            }
        }

        /// Pairs sources and destinations whose file name is unique on both
        /// sides (most renames move a file and keep its name).
        fn basenames(r: *Self) !void {
            const none = std.math.maxInt(u32);
            const min_score = r.min_score + (max_score - r.min_score) / 2;
            var src_names: std.StringHashMapUnmanaged(u32) = .empty;
            for (r.sources, 0..) |s, i| {
                if (r.src_used[i]) continue;
                const gop = try src_names.getOrPut(r.arena, basename(s.path));
                gop.value_ptr.* = if (gop.found_existing) none else @intCast(i);
            }
            var dst_names: std.StringHashMapUnmanaged(u32) = .empty;
            for (r.dests, 0..) |d, i| {
                if (r.dst_done[i]) continue;
                const gop = try dst_names.getOrPut(r.arena, basename(d.path));
                gop.value_ptr.* = if (gop.found_existing) none else @intCast(i);
            }
            for (r.sources, 0..) |s, si| {
                if (r.src_used[si]) continue;
                const name = basename(s.path);
                const di = dst_names.get(name) orelse continue;
                if (di == none or src_names.get(name).? == none) continue;
                if (r.dst_done[di]) continue;
                if (try r.similarity(si, di) < min_score) continue;
                r.pair(si, di);
            }
        }

        const Candidate = struct {
            score: u32 = 0,
            name_score: u1 = 0,
            /// null: an empty slot.
            dst: ?u32 = null,
            src: u32 = 0,

            /// git's score_compare: < 0 when `a` is the better pair.
            fn compare(a: Candidate, b: Candidate) i64 {
                if (a.dst == null) return @intFromBool(b.dst != null);
                if (b.dst == null) return -1;
                if (a.score == b.score) return @as(i64, b.name_score) - a.name_score;
                return @as(i64, b.score) - a.score;
            }

            fn better(_: void, a: Candidate, b: Candidate) bool {
                return compare(a, b) < 0;
            }
        };

        const per_dst = 4;

        fn matrix(r: *Self) !void {
            var mx: std.ArrayList(Candidate) = .empty;
            for (r.dests, 0..) |d, di| {
                if (r.dst_done[di]) continue;
                var best: [per_dst]Candidate = @splat(.{});
                for (r.sources, 0..) |s, si| {
                    if (r.src_used[si]) continue;
                    const c: Candidate = .{
                        .score = try r.similarity(si, di),
                        .name_score = @intFromBool(basenameSame(s.path, d.path)),
                        .dst = @intCast(di),
                        .src = @intCast(si),
                    };
                    var worst: usize = 0;
                    for (1..per_dst) |k| if (Candidate.compare(best[k], best[worst]) > 0) {
                        worst = k;
                    };
                    if (Candidate.compare(best[worst], c) > 0) best[worst] = c;
                }
                try mx.appendSlice(r.arena, &best);
            }
            std.sort.block(Candidate, mx.items, {}, Candidate.better);
            for (mx.items) |c| {
                const di = c.dst orelse break;
                if (c.score < r.min_score) break;
                if (r.dst_done[di] or r.src_used[c.src]) continue;
                r.pair(c.src, di);
            }
        }

        fn similarity(r: *Self, si: usize, di: usize) !u32 {
            const s = r.sources[si];
            const d = r.dests[di];
            if (!isRegular(s.mode) or !isRegular(d.mode)) return 0;
            const src = try r.spans(&r.src_spans[si], s.oid);
            const dst = try r.spans(&r.dst_spans[di], d.oid);
            const max_size = @max(src.size, dst.size);
            const delta_size = max_size - @min(src.size, dst.size);
            // Too different in size to reach the minimum score.
            if (max_size * (max_score - r.min_score) < delta_size * max_score) return 0;
            if (dst.size == 0) return 0;
            return @intCast(copied(src.counts, dst.counts) * max_score / max_size);
        }

        fn spans(r: *Self, slot: *?Spans, oid: Oid) !Spans {
            if (slot.*) |s| return s;
            slot.* = try hashSpans(r.arena, try r.blobs.read(oid));
            return slot.*.?;
        }
    };
}

fn isRegular(mode: u32) bool {
    return mode & 0o170000 == 0o100000;
}

fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

fn basenameSame(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, basename(a), basename(b));
}

const Span = struct { hash: u32, bytes: u32 };

/// A blob's pieces: total bytes per piece hash, sorted by hash.
const Spans = struct {
    size: u64,
    counts: []const Span,
};

const hash_base = 107927;
/// git treats a blob as binary when its first 8000 bytes hold a NUL.
const binary_probe = 8000;

/// git's hash_chars: pieces end at a newline or after 64 bytes; CR before
/// LF is skipped in text.
fn hashSpans(arena: Allocator, data: []const u8) !Spans {
    const text = std.mem.indexOfScalar(u8, data[0..@min(data.len, binary_probe)], 0) == null;
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var n: u32 = 0;
    var accum1: u32 = 0;
    var accum2: u32 = 0;
    for (data, 0..) |c, i| {
        if (text and c == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
        const old1 = accum1;
        accum1 = (accum1 << 7) ^ (accum2 >> 25);
        accum2 = (accum2 << 7) ^ (old1 >> 25);
        accum1 +%= c;
        n += 1;
        if (n < 64 and c != '\n') continue;
        try addSpan(arena, &map, accum1, accum2, n);
        n = 0;
        accum1 = 0;
        accum2 = 0;
    }
    if (n > 0) try addSpan(arena, &map, accum1, accum2, n);

    const counts = try arena.alloc(Span, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) counts[i] = .{ .hash = e.key_ptr.*, .bytes = e.value_ptr.* };
    std.sort.pdq(Span, counts, {}, struct {
        fn lt(_: void, a: Span, b: Span) bool {
            return a.hash < b.hash;
        }
    }.lt);
    return .{ .size = data.len, .counts = counts };
}

fn addSpan(arena: Allocator, map: *std.AutoHashMapUnmanaged(u32, u32), accum1: u32, accum2: u32, n: u32) !void {
    const gop = try map.getOrPut(arena, (accum1 +% accum2 *% 0x61) % hash_base);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + n else n;
}

/// Bytes of the source found again in the destination.
fn copied(src: []const Span, dst: []const Span) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len and j < dst.len) {
        if (src[i].hash < dst[j].hash) {
            i += 1;
        } else if (src[i].hash > dst[j].hash) {
            j += 1;
        } else {
            total += @min(src[i].bytes, dst[j].bytes);
            i += 1;
            j += 1;
        }
    }
    return total;
}

const TestBlobs = struct {
    map: std.AutoHashMapUnmanaged(Oid, []const u8) = .empty,

    fn add(b: *TestBlobs, arena: Allocator, data: []const u8) !Oid {
        const oid = Oid.hashObject("blob", data);
        try b.map.put(arena, oid, data);
        return oid;
    }

    fn read(b: *const TestBlobs, oid: Oid) ![]const u8 {
        return b.map.get(oid) orelse error.ObjectNotFound;
    }
};

test "exact, basename and similarity renames" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var blobs: TestBlobs = .{};

    var long: std.ArrayList(u8) = .empty;
    for (0..20) |i| try long.print(arena, "line {d}\n", .{i});
    const edited = try std.mem.replaceOwned(u8, arena, long.items, "line 7\n", "line seven\n");
    const other = "something else entirely\n";

    const a = try blobs.add(arena, long.items);
    const b = try blobs.add(arena, edited);
    const c = try blobs.add(arena, other);
    const sources = [_]File{
        .{ .path = "old/a.txt", .mode = 0o100644, .oid = a },
        .{ .path = "x.txt", .mode = 0o100644, .oid = c },
    };
    // a.txt moved and edited (basename pass), x.txt copied verbatim (exact).
    const dests = [_]File{
        .{ .path = "new/a.txt", .mode = 0o100644, .oid = b },
        .{ .path = "y.txt", .mode = 0o100644, .oid = c },
    };
    try std.testing.expectEqual(@as(u32, 2), try count(arena, &blobs, &sources, &dests, .{}));
    // Edited and renamed (matrix pass).
    const dests2 = [_]File{.{ .path = "b.txt", .mode = 0o100644, .oid = b }};
    try std.testing.expectEqual(@as(u32, 1), try count(arena, &blobs, sources[0..1], &dests2, .{}));
    // 2 × 2 candidates: within the default limit, over a limit of 1.
    const d = try blobs.add(arena, "new\n");
    const dests4 = [_]File{ dests2[0], .{ .path = "d.txt", .mode = 0o100644, .oid = d } };
    try std.testing.expectEqual(@as(u32, 1), try count(arena, &blobs, &sources, &dests4, .{}));
    try std.testing.expectEqual(@as(u32, 0), try count(arena, &blobs, &sources, &dests4, .{ .limit = 1 }));
    // Unrelated content is not a rename; a symlink never matches a file inexactly.
    const dests3 = [_]File{.{ .path = "z.txt", .mode = 0o100644, .oid = c }};
    try std.testing.expectEqual(@as(u32, 0), try count(arena, &blobs, sources[0..1], &dests3, .{}));
    const link = [_]File{.{ .path = "old/a.txt", .mode = 0o120000, .oid = a }};
    try std.testing.expectEqual(@as(u32, 0), try count(arena, &blobs, &link, &dests2, .{}));
}

test "spans: CRLF counts as LF in text, not in binary" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lf = try hashSpans(arena, "one\ntwo\n");
    const crlf = try hashSpans(arena, "one\r\ntwo\r\n");
    try std.testing.expectEqual(@as(u64, 8), copied(lf.counts, crlf.counts));
    const bin = try hashSpans(arena, "\x00ne\r\ntwo\r\n");
    try std.testing.expectEqual(@as(u64, 0), copied(lf.counts, bin.counts));
}
