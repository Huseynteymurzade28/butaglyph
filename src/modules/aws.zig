//! The AWS profile and region set in this shell: $AWS_PROFILE (or
//! $AWS_DEFAULT_PROFILE, or aws-vault's $AWS_VAULT) and $AWS_REGION (or
//! $AWS_DEFAULT_REGION). Without a region in the environment, the
//! profile's `region` from ~/.aws/config ($AWS_CONFIG_FILE) is shown.
//! Hidden when neither profile nor region is set.

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .aws;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "yellow", .bold = true },
    symbol: ?[]const u8 = null,
    show_region: bool = true,
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct {
    profile: ?[]const u8,
    region: ?[]const u8,
};

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    const profile = firstSet(ctx, &.{ "AWS_VAULT", "AWS_PROFILE", "AWS_DEFAULT_PROFILE" });
    var region = if (cfg.show_region) firstSet(ctx, &.{ "AWS_REGION", "AWS_DEFAULT_REGION" }) else null;
    if (profile == null and region == null) return null;
    if (cfg.show_region and region == null) {
        const path = if (ctx.getEnv("AWS_CONFIG_FILE")) |p|
            env.toSlashes(try arena.dupe(u8, p))
        else
            try std.fmt.allocPrint(arena, "{s}/.aws/config", .{ctx.home orelse return .{ .profile = profile, .region = null }});
        if (lang.readSmall(ctx.io, arena, path)) |content| region = profileRegion(content, profile.?);
    }
    return .{ .profile = profile, .region = region };
}

fn firstSet(ctx: *const Context, names: []const []const u8) ?[]const u8 {
    for (names) |n| if (ctx.getEnv(n)) |v| if (v.len > 0) return v;
    return null;
}

/// `region` in the profile's section: `[profile <name>]`, or `[default]`.
fn profileRegion(config: []const u8, profile: []const u8) ?[]const u8 {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            const header = std.mem.trim(u8, std.mem.trim(u8, line, "[]"), " ");
            in_section = if (std.mem.eql(u8, profile, "default"))
                std.mem.eql(u8, header, "default") or std.mem.eql(u8, header, "profile default")
            else
                std.mem.startsWith(u8, header, "profile ") and
                    std.mem.eql(u8, std.mem.trim(u8, header["profile ".len..], " "), profile);
            continue;
        }
        if (in_section) if (lang.iniValue(line, "region")) |r| if (r.len > 0) return r;
    }
    return null;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    // Profile and region, or the region alone (without parentheses).
    const main = data.profile orelse data.region;
    const extra = if (data.profile != null) data.region else null;
    try lang.draw(line, cfg.style, cfg.symbol orelse g.aws, "", main, extra);
}

test profileRegion {
    const config =
        \\[default]
        \\region = us-east-1
        \\
        \\[profile prod]
        \\role_arn = arn:aws:iam::123:role/admin
        \\region = eu-west-1
        \\
        \\[profile dev]
        \\output = json
    ;
    try std.testing.expectEqualStrings("eu-west-1", profileRegion(config, "prod").?);
    try std.testing.expectEqualStrings("us-east-1", profileRegion(config, "default").?);
    try std.testing.expectEqual(@as(?[]const u8, null), profileRegion(config, "dev"));
    try std.testing.expectEqual(@as(?[]const u8, null), profileRegion(config, "missing"));
}

test "aws rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .profile = "prod", .region = "eu-west-1" }, &.{}, g, &line);
    try render(&.{ .profile = null, .region = "eu-west-1" }, &.{}, g, &line);
    try render(&.{ .profile = "prod", .region = null }, &.{}, g, &line);
    try std.testing.expectEqualStrings("aws prod (eu-west-1)", line.items()[0].text);
    try std.testing.expectEqualStrings("aws eu-west-1", line.items()[1].text);
    try std.testing.expectEqualStrings("aws prod", line.items()[2].text);
}
