//! Current git branch, or the short hash on a detached HEAD.
//! Phase 0 reads `.git/HEAD` only; there is no dirty check yet.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const repo = @import("git").repo;

pub const id: module.Id = .git_branch;
pub const cost: module.Cost = .expensive;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "magenta", .bold = true },
    symbol: ?[]const u8 = null,
    detached_symbol: ?[]const u8 = null,
    /// Hex digits shown for a detached HEAD.
    hash_length: u8 = 7,
    /// Branch names longer than this are cut and end in `truncation_symbol`; 0 disables.
    max_length: u16 = 0,
    truncation_symbol: []const u8 = "…",
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct { head: repo.Head };

pub fn compute(ctx: *const Context, _: *const Config, arena: std.mem.Allocator) !?Data {
    const r = try repo.discover(ctx.io, arena, ctx.physical_cwd) orelse return null;
    return .{ .head = try repo.readHead(ctx.io, arena, r) };
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    switch (data.head) {
        .branch => |name| {
            const symbol = cfg.symbol orelse g.git_branch;
            const cut = truncate(name, cfg.max_length);
            const ellipsis = if (cut.len < name.len) cfg.truncation_symbol else "";
            try line.print(cfg.style, "{s}{s}{s}", .{ symbol, cut, ellipsis });
        },
        .detached => |hash| {
            const symbol = cfg.detached_symbol orelse g.git_detached;
            try line.print(cfg.style, "{s}{s}", .{ symbol, hash[0..@min(hash.len, cfg.hash_length)] });
        },
    }
}

/// First `max` code points of `s` (0 = no limit).
fn truncate(s: []const u8, max: usize) []const u8 {
    if (max == 0) return s;
    var end: usize = 0;
    var n: usize = 0;
    while (end < s.len and n < max) : (n += 1) {
        end += std.unicode.utf8ByteSequenceLength(s[end]) catch 1;
    }
    return s[0..@min(end, s.len)];
}

test "git_branch rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .head = .{ .branch = "main" } }, &.{}, g, &line);
    try render(&.{ .head = .{ .detached = "3f786850e387550fdab836ed7e6dc881de23001b" } }, &.{}, g, &line);
    try render(&.{ .head = .{ .branch = "feature/very-long" } }, &.{ .max_length = 7, .symbol = "" }, g, &line);
    try render(&.{ .head = .{ .branch = "düzəliş" } }, &.{ .max_length = 7, .symbol = "" }, g, &line);
    try std.testing.expectEqualStrings("git:main", line.items()[0].text);
    try std.testing.expectEqualStrings("git:@3f78685", line.items()[1].text);
    try std.testing.expectEqualStrings("feature…", line.items()[2].text);
    try std.testing.expectEqualStrings("düzəliş", line.items()[3].text);
}
