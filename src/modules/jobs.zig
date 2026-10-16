//! Number of background jobs. Not in the default order; add `.jobs` to
//! `order` in config.zon to enable it.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .jobs;
pub const cost: module.Cost = .cheap;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "blue", .bold = true },
    symbol: ?[]const u8 = null,
    /// Hidden below this many jobs.
    min: u32 = 1,
    /// Show the count only when there are at least this many jobs.
    count_from: u32 = 2,
};

pub const Data = struct { count: u32 };

pub fn compute(ctx: *const Context, cfg: *const Config, _: std.mem.Allocator) !?Data {
    if (ctx.jobs == 0 or ctx.jobs < cfg.min) return null;
    return .{ .count = ctx.jobs };
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    const symbol = cfg.symbol orelse g.jobs;
    if (data.count >= cfg.count_from) {
        try line.print(cfg.style, "{s}{d}", .{ symbol, data.count });
    } else {
        try line.text(cfg.style, std.mem.trimEnd(u8, symbol, " "));
    }
}

test "jobs rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .count = 1 }, &.{}, g, &line);
    try render(&.{ .count = 3 }, &.{}, g, &line);
    try std.testing.expectEqualStrings("&", line.items()[0].text);
    try std.testing.expectEqualStrings("&3", line.items()[1].text);
}
