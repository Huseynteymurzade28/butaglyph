//! User and host: `me@laptop`, in its own style when the user is root.
//! Not in the default order.

const std = @import("std");
const env = @import("../env.zig");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .user;
pub const cost: module.Cost = .cheap;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "yellow", .bold = true },
    /// Used instead of `style` when the user is root.
    root_style: render_mod.Style = .{ .fg = "red", .bold = true },
    symbol: ?[]const u8 = null,
    show_user: bool = true,
    show_host: bool = true,
    /// Between user and host.
    separator: []const u8 = "@",
    /// Only in an SSH session ($SSH_CONNECTION or $SSH_TTY set).
    ssh_only: bool = false,
};

pub const Data = struct {
    user: ?[]const u8,
    host: ?[]const u8,
    root: bool,
};

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    if (cfg.ssh_only and !ctx.env.flag("SSH_CONNECTION") and !ctx.env.flag("SSH_TTY")) return null;
    const user = ctx.getEnv(if (env.is_windows) "USERNAME" else "USER") orelse ctx.getEnv("LOGNAME");
    const host = if (cfg.show_host) try hostName(ctx, arena) else null;
    const data: Data = .{
        .user = if (cfg.show_user) user else null,
        .host = host,
        .root = if (user) |u| std.mem.eql(u8, u, "root") else false,
    };
    if (data.user == null and data.host == null) return null;
    return data;
}

/// The short host name: `laptop`, not `laptop.example.com`.
fn hostName(ctx: *const Context, arena: std.mem.Allocator) !?[]const u8 {
    const full = if (env.is_windows)
        ctx.getEnv("COMPUTERNAME") orelse return null
    else blk: {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        break :blk try arena.dupe(u8, std.posix.gethostname(&buf) catch return null);
    };
    return full[0 .. std.mem.indexOfScalar(u8, full, '.') orelse full.len];
}

pub fn render(data: *const Data, cfg: *const Config, _: *const Glyphs, line: *Line) Line.Error!void {
    const style = if (data.root) cfg.root_style else cfg.style;
    const sep = if (data.user != null and data.host != null) cfg.separator else "";
    try line.print(style, "{s}{s}{s}{s}", .{ cfg.symbol orelse "", data.user orelse "", sep, data.host orelse "" });
}

test "user rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .user = "huso", .host = "arch", .root = false }, &.{}, g, &line);
    try render(&.{ .user = "root", .host = null, .root = true }, &.{}, g, &line);
    try render(&.{ .user = null, .host = "arch", .root = false }, &.{ .symbol = "on " }, g, &line);
    try std.testing.expectEqualStrings("huso@arch", line.items()[0].text);
    try std.testing.expectEqualStrings("yellow", line.items()[0].style.fg.?);
    try std.testing.expectEqualStrings("root", line.items()[1].text);
    try std.testing.expectEqualStrings("red", line.items()[1].style.fg.?);
    try std.testing.expectEqualStrings("on arch", line.items()[2].text);
}
