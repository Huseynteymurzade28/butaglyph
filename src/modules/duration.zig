//! Duration of the previous command, shown when it exceeds `min_ms`.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .duration;
pub const cost: module.Cost = .cheap;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "yellow", .bold = true },
    symbol: ?[]const u8 = null,
    /// Commands faster than this are not reported.
    min_ms: u64 = 2000,
};

pub const Data = struct { ms: u64 };

pub fn compute(ctx: *const Context, cfg: *const Config, _: std.mem.Allocator) !?Data {
    const ms = ctx.duration_ms orelse return null;
    if (ms < cfg.min_ms) return null;
    return .{ .ms = ms };
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    var buf: [32]u8 = undefined;
    try line.print(cfg.style, "{s}{s}", .{ cfg.symbol orelse g.duration, format(&buf, data.ms) });
}

/// 450ms, 2.5s, 59.9s, 1m 5s, 2h 0m 13s
pub fn format(buf: *[32]u8, ms: u64) []const u8 {
    const s = ms / 1000;
    return (if (ms < 1000)
        std.fmt.bufPrint(buf, "{d}ms", .{ms})
    else if (s < 60)
        std.fmt.bufPrint(buf, "{d}.{d}s", .{ s, (ms % 1000) / 100 })
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m {d}s", .{ s / 60, s % 60 })
    else
        std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ s / 3600, (s % 3600) / 60, s % 60 })) catch unreachable;
}

test format {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("450ms", format(&buf, 450));
    try std.testing.expectEqualStrings("2.0s", format(&buf, 2000));
    try std.testing.expectEqualStrings("2.5s", format(&buf, 2599));
    try std.testing.expectEqualStrings("59.9s", format(&buf, 59_999));
    try std.testing.expectEqualStrings("1m 5s", format(&buf, 65_000));
    try std.testing.expectEqualStrings("2h 0m 13s", format(&buf, 7_213_000));
    try std.testing.expectEqualStrings("5124095576030h 25m 51s", format(&buf, std.math.maxInt(u64)));
}

test "threshold" {
    var ctx: Context = undefined;
    ctx.duration_ms = 1999;
    try std.testing.expectEqual(@as(?Data, null), try compute(&ctx, &.{}, undefined));
    ctx.duration_ms = 2000;
    try std.testing.expectEqual(@as(u64, 2000), (try compute(&ctx, &.{}, undefined)).?.ms);
    ctx.duration_ms = null;
    try std.testing.expectEqual(@as(?Data, null), try compute(&ctx, &.{}, undefined));
}
