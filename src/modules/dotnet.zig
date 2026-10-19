//! .NET SDK version, inside a .NET project or solution. A `global.json`
//! that pins the SDK (`"sdk": { "version": "8.0.100" }`) is read; otherwise
//! `dotnet --version`, kept in the version cache (see lang.zig).

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .dotnet;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "blue", .bold = true },
    symbol: ?[]const u8 = null,
    version_prefix: []const u8 = "v",
    detect: lang.Detect = .{
        .files = &.{ "global.json", "Directory.Build.props", "Directory.Build.targets", "Directory.Packages.props" },
        .extensions = &.{ "csproj", "fsproj", "vbproj", "sln", "slnx" },
    },
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct { version: ?[]const u8 };

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    const root = try lang.findProject(ctx, arena, cfg.detect) orelse return null;
    // The pin applies from the project's directory up, like the SDK resolves it.
    var dir: ?[]const u8 = root;
    while (dir) |d| : (dir = lang.parent(d)) {
        const p = try std.fmt.allocPrint(arena, "{s}/global.json", .{std.mem.trimEnd(u8, d, "/")});
        if (lang.readSmall(ctx.io, arena, p)) |json| {
            if (pinnedSdk(arena, json)) |v| return .{ .version = v };
            break;
        }
    }
    const exe = try lang.which(ctx, arena, "dotnet") orelse return .{ .version = null };
    return .{ .version = try lang.probe(ctx, arena, exe, &.{"--version"}) };
}

fn pinnedSdk(arena: std.mem.Allocator, json: []const u8) ?[]const u8 {
    const G = struct { sdk: ?struct { version: ?[]const u8 = null } = null };
    const g = std.json.parseFromSliceLeaky(G, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return (g.sdk orelse return null).version;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.dotnet, cfg.version_prefix, data.version, null);
}

test pinnedSdk {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("8.0.100", pinnedSdk(a, "{ \"sdk\": { \"version\": \"8.0.100\", \"rollForward\": \"latestFeature\" } }").?);
    try std.testing.expectEqual(@as(?[]const u8, null), pinnedSdk(a, "{ \"msbuild-sdks\": {} }"));
    try std.testing.expectEqual(@as(?[]const u8, null), pinnedSdk(a, "not json"));
}
