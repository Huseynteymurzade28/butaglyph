//! Node.js version, inside a JavaScript project: `node --version`, from the
//! version cache once asked (see lang.zig).

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .node;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "green", .bold = true },
    symbol: ?[]const u8 = null,
    version_prefix: []const u8 = "v",
    detect: lang.Detect = .{ .files = &.{ "package.json", ".nvmrc", ".node-version" } },
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct { version: ?[]const u8 };

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    _ = try lang.findProject(ctx, arena, cfg.detect) orelse return null;
    const exe = try lang.which(ctx, arena, "node") orelse return .{ .version = null };
    return .{ .version = try lang.probe(ctx, arena, exe, &.{"--version"}) };
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.node, cfg.version_prefix, data.version, null);
}

test "node rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .version = "20.11.1" }, &.{}, g, &line);
    try render(&.{ .version = null }, &.{}, g, &line);
    try std.testing.expectEqualStrings("node v20.11.1", line.items()[0].text);
    try std.testing.expectEqualStrings("node", line.items()[1].text);
}
