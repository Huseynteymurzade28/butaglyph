//! Java version, inside a Maven or Gradle project. Read from the JDK's
//! `release` file ($JAVA_HOME, else the directory above the `java`
//! binary's real location), so no JVM starts; `java -version` is the
//! fallback, kept in the version cache (see lang.zig).

const std = @import("std");
const Io = std.Io;
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .java;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "red", .bold = true },
    symbol: ?[]const u8 = null,
    version_prefix: []const u8 = "v",
    detect: lang.Detect = .{
        .files = &.{ "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", ".java-version", ".sdkmanrc" },
        .extensions = &.{"java"},
    },
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct { version: ?[]const u8 };

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    _ = try lang.findProject(ctx, arena, cfg.detect) orelse return null;
    if (ctx.getEnv("JAVA_HOME")) |home| if (home.len > 0) {
        if (releaseFile(ctx.io, arena, env.toSlashes(try arena.dupe(u8, std.mem.trimEnd(u8, home, "/\\"))))) |v| return .{ .version = v };
    };
    const exe = try lang.which(ctx, arena, "java") orelse return .{ .version = null };
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().realPathFile(ctx.io, exe, &real_buf)) |n| {
        // <jdk>/bin/java
        const real = env.toSlashes(real_buf[0..n]);
        if (lang.parent(real)) |bin| if (lang.parent(bin)) |jdk| {
            if (releaseFile(ctx.io, arena, jdk)) |v| return .{ .version = v };
        };
    } else |_| {}
    return .{ .version = try lang.probe(ctx, arena, exe, &.{"-version"}) };
}

/// `JAVA_VERSION="21.0.2"` in `<jdk>/release`.
fn releaseFile(io: Io, arena: std.mem.Allocator, jdk: []const u8) ?[]const u8 {
    const p = std.fmt.allocPrint(arena, "{s}/release", .{jdk}) catch return null;
    const content = lang.readSmall(io, arena, p) orelse return null;
    const v = lang.iniValue(content, "JAVA_VERSION") orelse return null;
    return if (v.len > 0) v else null;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.java, cfg.version_prefix, data.version, null);
}

test releaseFile {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jdk = env.toSlashes(try tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
    try std.testing.expectEqual(@as(?[]const u8, null), releaseFile(std.testing.io, a, jdk));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "release", .data = "IMPLEMENTOR=\"Eclipse Adoptium\"\nJAVA_VERSION=\"21.0.2\"\nJAVA_VERSION_DATE=\"2024-01-16\"\n" });
    try std.testing.expectEqualStrings("21.0.2", releaseFile(std.testing.io, a, jdk).?);
}
