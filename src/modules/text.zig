//! Fixed, styled text: ornaments, frames, labels. Each piece has its own
//! style, so one module can draw a whole motif. List `.text` in `order`
//! more than once to draw it in several places.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .text;
pub const cost: module.Cost = .cheap;

pub const Piece = struct {
    text: []const u8 = "",
    style: render_mod.Style = .{},
};

pub const Config = struct {
    pieces: []const Piece = &.{},
};

pub const Data = struct {};

pub fn compute(_: *const Context, cfg: *const Config, _: std.mem.Allocator) !?Data {
    return if (cfg.pieces.len == 0) null else .{};
}

pub fn render(_: *const Data, cfg: *const Config, _: *const Glyphs, line: *Line) Line.Error!void {
    for (cfg.pieces) |p| try line.text(p.style, p.text);
}

test "text pieces keep their styles" {
    var line: Line = .{};
    try render(&.{}, &.{ .pieces = &.{ .{ .text = "╭─", .style = .{ .fg = "red" } }, .{ .text = "❦" } } }, @import("../glyphs.zig").get(.ascii), &line);
    try std.testing.expectEqual(@as(usize, 2), line.len);
    try std.testing.expectEqualStrings("red", line.items()[0].style.fg.?);
    try std.testing.expectEqualStrings("❦", line.items()[1].text);
}
