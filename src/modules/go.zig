//! Go version, inside a Go module or workspace. Read from the VERSION
//! file of the Go installation ($GOROOT, else the directory above the `go`
//! binary's real location), so nothing runs; `go version` is the fallback.

const std = @import("std");
const Io = std.Io;
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .go;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "cyan", .bold = true },
    symbol: ?[]const u8 = null,
    version_prefix: []const u8 = "v",
    detect: lang.Detect = .{ .files = &.{ "go.mod", "go.work" } },
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct { version: ?[]const u8 };

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    _ = try lang.findProject(ctx, arena, cfg.detect) orelse return null;
    if (ctx.getEnv("GOROOT")) |root| if (root.len > 0) {
        if (versionFile(ctx.io, arena, root)) |v| return .{ .version = v };
    };
    const exe = try lang.which(ctx, arena, "go") orelse return .{ .version = null };
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().realPathFile(ctx.io, exe, &real_buf)) |n| {
        // <goroot>/bin/go
        const real = env.toSlashes(real_buf[0..n]);
        if (lang.parent(real)) |bin| if (lang.parent(bin)) |root| {
            if (versionFile(ctx.io, arena, root)) |v| return .{ .version = v };
        };
    } else |_| {}
    return .{ .version = try lang.probe(ctx, arena, exe, &.{"version"}) };
}

/// `go1.22.1` on the first line of `<root>/VERSION`.
fn versionFile(io: Io, arena: std.mem.Allocator, root: []const u8) ?[]const u8 {
    const p = std.fmt.allocPrint(arena, "{s}/VERSION", .{root}) catch return null;
    const content = lang.readSmall(io, arena, p) orelse return null;
    const first = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    if (!std.mem.startsWith(u8, first, "go")) return null;
    return lang.parseVersion(first);
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.go, cfg.version_prefix, data.version, null);
}

test versionFile {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = env.toSlashes(try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    try std.testing.expectEqual(@as(?[]const u8, null), versionFile(std.testing.io, a, root));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "VERSION", .data = "go1.22.1\ntime 2024-02-29T18:18:48Z\n" });
    try std.testing.expectEqualStrings("1.22.1", versionFile(std.testing.io, a, root).?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "VERSION", .data = "devel +abc\n" });
    try std.testing.expectEqual(@as(?[]const u8, null), versionFile(std.testing.io, a, root));
}
