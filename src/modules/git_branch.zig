//! Placeholder; implemented in the git step.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .git_branch;
pub const cost: module.Cost = .expensive;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "magenta", .bold = true },
    symbol: ?[]const u8 = null,
};

pub const Data = struct {};

pub fn compute(_: *const Context, _: *const Config, _: std.mem.Allocator) !?Data {
    return null;
}

pub fn render(_: *const Data, _: *const Config, _: *const Glyphs, _: *Line) Line.Error!void {}
