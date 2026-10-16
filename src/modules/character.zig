//! The prompt symbol, colored by the previous command's success.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .character;
pub const cost: module.Cost = .cheap;

pub const Config = struct {
    success_style: render_mod.Style = .{ .fg = "green", .bold = true },
    failure_style: render_mod.Style = .{ .fg = "red", .bold = true },
    success_symbol: ?[]const u8 = null,
    failure_symbol: ?[]const u8 = null,
    /// Unstyled text after the symbol, before the cursor.
    suffix: []const u8 = " ",
};

pub const Data = struct { success: bool };

pub fn compute(ctx: *const Context, _: *const Config, _: std.mem.Allocator) !?Data {
    return .{ .success = ctx.status == 0 };
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    if (data.success) {
        try line.text(cfg.success_style, cfg.success_symbol orelse g.character_success);
    } else {
        try line.text(cfg.failure_style, cfg.failure_symbol orelse g.character_failure);
    }
    try line.text(.{}, cfg.suffix);
}

test "character picks style by status" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .success = true }, &.{}, g, &line);
    try render(&.{ .success = false }, &.{ .failure_symbol = "!" }, g, &line);
    const s = line.items();
    try std.testing.expectEqualStrings(">", s[0].text);
    try std.testing.expectEqualStrings("green", s[0].style.fg.?);
    try std.testing.expectEqualStrings(" ", s[1].text);
    try std.testing.expectEqualStrings("!", s[2].text);
    try std.testing.expectEqualStrings("red", s[2].style.fg.?);
}
