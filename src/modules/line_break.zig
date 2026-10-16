//! A newline, for multi-line prompts. Resets the separator logic.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const Line = @import("../render.zig").Line;

pub const id: module.Id = .line_break;
pub const cost: module.Cost = .cheap;

pub const Config = struct {};
pub const Data = struct {};

pub fn compute(_: *const Context, _: *const Config, _: std.mem.Allocator) !?Data {
    return .{};
}

pub fn render(_: *const Data, _: *const Config, _: *const Glyphs, line: *Line) Line.Error!void {
    try line.newline();
}
