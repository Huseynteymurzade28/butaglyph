//! Exit status of the previous command, shown only when non-zero.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .status;
pub const cost: module.Cost = .cheap;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "red", .bold = true },
    symbol: ?[]const u8 = null,
    /// Show "INT" instead of 130 for commands killed by a signal.
    signal_names: bool = true,
};

pub const Data = struct { code: i32 };

pub fn compute(ctx: *const Context, _: *const Config, _: std.mem.Allocator) !?Data {
    if (ctx.status == 0) return null;
    return .{ .code = ctx.status };
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    const symbol = cfg.symbol orelse g.status;
    if (cfg.signal_names) {
        if (signalName(data.code)) |name| return line.print(cfg.style, "{s}{s}", .{ symbol, name });
    }
    try line.print(cfg.style, "{s}{d}", .{ symbol, data.code });
}

/// Shells report "killed by signal N" as 128 + N.
pub fn signalName(code: i32) ?[]const u8 {
    return switch (code - 128) {
        1 => "HUP",
        2 => "INT",
        3 => "QUIT",
        4 => "ILL",
        6 => "ABRT",
        8 => "FPE",
        9 => "KILL",
        11 => "SEGV",
        13 => "PIPE",
        14 => "ALRM",
        15 => "TERM",
        else => null,
    };
}

test "status rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .code = 1 }, &.{}, g, &line);
    try render(&.{ .code = 130 }, &.{}, g, &line);
    try render(&.{ .code = 130 }, &.{ .signal_names = false, .symbol = "!" }, g, &line);
    try std.testing.expectEqualStrings("x 1", line.items()[0].text);
    try std.testing.expectEqualStrings("x INT", line.items()[1].text);
    try std.testing.expectEqualStrings("!130", line.items()[2].text);
}
