//! The active Docker context, when it isn't `default`: $DOCKER_CONTEXT,
//! else `currentContext` in the Docker CLI's config.json ($DOCKER_CONFIG,
//! else ~/.docker). Not in the default order.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .docker_context;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "blue", .bold = true },
    symbol: ?[]const u8 = null,
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct { name: []const u8 };

pub fn compute(ctx: *const Context, _: *const Config, arena: std.mem.Allocator) !?Data {
    const name = ctx.getEnv("DOCKER_CONTEXT") orelse try fromConfig(ctx, arena) orelse return null;
    if (name.len == 0 or std.mem.eql(u8, name, "default")) return null;
    return .{ .name = name };
}

fn fromConfig(ctx: *const Context, arena: std.mem.Allocator) !?[]const u8 {
    const dir = if (ctx.getEnv("DOCKER_CONFIG")) |d|
        env.toSlashes(try arena.dupe(u8, d))
    else
        try std.fmt.allocPrint(arena, "{s}/.docker", .{ctx.home orelse return null});
    const json = lang.readSmall(ctx.io, arena, try std.fmt.allocPrint(arena, "{s}/config.json", .{dir})) orelse return null;
    return currentContext(arena, json);
}

fn currentContext(arena: std.mem.Allocator, json: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(struct { currentContext: ?[]const u8 = null }, arena, json, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.currentContext;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.docker, "", data.name, null);
}

test currentContext {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("desktop-linux", currentContext(a,
        \\{
        \\  "auths": { "ghcr.io": {} },
        \\  "credsStore": "desktop",
        \\  "currentContext": "desktop-linux"
        \\}
    ).?);
    try std.testing.expectEqual(@as(?[]const u8, null), currentContext(a, "{\"auths\": {}}"));
    try std.testing.expectEqual(@as(?[]const u8, null), currentContext(a, "not json"));
}

test "docker_context rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .name = "prod" }, &.{}, g, &line);
    try std.testing.expectEqualStrings("docker prod", line.items()[0].text);
}
