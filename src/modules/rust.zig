//! Rust version, inside a Cargo project. With rustup, the active
//! toolchain is worked out the way rustup does it ($RUSTUP_TOOLCHAIN, then
//! directory overrides and rust-toolchain files from the working directory
//! up, then the default), and that toolchain's own `rustc --version` is
//! asked: the rustup proxy is never run, so a toolchain that is not
//! installed is never installed by a prompt. Without rustup, `rustc` from
//! $PATH. Either way the answer is kept in the version cache (lang.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .rust;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "red", .bold = true },
    symbol: ?[]const u8 = null,
    version_prefix: []const u8 = "v",
    detect: lang.Detect = .{ .files = &.{ "Cargo.toml", "rust-toolchain.toml", "rust-toolchain" } },
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct { version: ?[]const u8 };

const exe_name = if (env.is_windows) "rustc.exe" else "rustc";

pub fn compute(ctx: *const Context, cfg: *const Config, arena: Allocator) !?Data {
    _ = try lang.findProject(ctx, arena, cfg.detect) orelse return null;
    if (try rustupHome(ctx, arena)) |home| {
        const settings = lang.readSmall(ctx.io, arena, try std.fmt.allocPrint(arena, "{s}/settings.toml", .{home}));
        if (settings) |s| {
            const name = try activeToolchain(ctx, arena, s) orelse return .{ .version = null };
            const dir = try toolchainDir(ctx.io, arena, home, name) orelse return .{ .version = null };
            const exe = try std.fmt.allocPrint(arena, "{s}/bin/{s}", .{ dir, exe_name });
            return .{ .version = try lang.probe(ctx, arena, exe, &.{"--version"}) };
        }
    }
    const exe = try lang.which(ctx, arena, "rustc") orelse return .{ .version = null };
    return .{ .version = try lang.probe(ctx, arena, exe, &.{"--version"}) };
}

fn rustupHome(ctx: *const Context, arena: Allocator) !?[]const u8 {
    if (ctx.getEnv("RUSTUP_HOME")) |h| if (h.len > 0) return env.toSlashes(try arena.dupe(u8, h));
    const home = ctx.home orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/.rustup", .{home});
}

/// The toolchain rustup would pick here, as written: `stable`, `1.85`,
/// `nightly-2024-05-01-x86_64-unknown-linux-gnu`.
fn activeToolchain(ctx: *const Context, arena: Allocator, settings: []const u8) !?[]const u8 {
    if (ctx.getEnv("RUSTUP_TOOLCHAIN")) |t| if (t.len > 0) return t;
    var dir: []const u8 = ctx.physical_cwd;
    while (true) {
        if (override(settings, dir)) |t| return t;
        for ([_][]const u8{ "rust-toolchain.toml", "rust-toolchain" }) |file| {
            const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), file });
            if (lang.readSmall(ctx.io, arena, p)) |content| if (toolchainFile(content)) |t| return t;
        }
        dir = lang.parent(dir) orelse break;
    }
    return lang.iniValue(settings, "default_toolchain");
}

/// `rustup override set` stores `"<dir>" = "<toolchain>"` under
/// `[overrides]` in settings.toml.
fn override(settings: []const u8, dir: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, settings, "[overrides]") orelse return null;
    var lines = std.mem.splitScalar(u8, settings[start + "[overrides]".len ..], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') return null; // the next table
        if (line.len < 2 or line[0] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse continue;
        if (!samePath(line[1..end], dir)) continue;
        const rest = std.mem.trimStart(u8, line[end + 1 ..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        return std.mem.trim(u8, rest[1..], " \t\"");
    }
    return null;
}

/// A TOML key holds Windows paths as `C:\\Users\\me`.
fn samePath(toml_key: []const u8, dir: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < toml_key.len) : (i += 1) {
        var c = toml_key[i];
        if (c == '\\' and i + 1 < toml_key.len and toml_key[i + 1] == '\\') i += 1;
        if (c == '\\' and env.is_windows) c = '/';
        if (j >= dir.len) return false;
        const d = dir[j];
        if (if (env.is_windows) std.ascii.toLower(c) != std.ascii.toLower(d) else c != d) return false;
        j += 1;
    }
    return j == dir.len;
}

/// rust-toolchain.toml (`channel = "1.85"` under `[toolchain]`), or the
/// old rust-toolchain file: TOML like that, or just the name.
fn toolchainFile(content: []const u8) ?[]const u8 {
    if (lang.iniValue(content, "channel")) |c| return if (c.len > 0) c else null;
    const t = std.mem.trim(u8, content, " \t\r\n");
    if (t.len == 0 or std.mem.indexOfAny(u8, t, "=[\n") != null) return null;
    return t;
}

/// `<home>/toolchains/<name>`, or `<name>-<host triple>` as rustup
/// installs `stable`. null if it is not installed.
fn toolchainDir(io: Io, arena: Allocator, home: []const u8, name: []const u8) !?[]const u8 {
    // A name is one path component; anything else is a custom toolchain path.
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return null;
    const dir_path = try std.fmt.allocPrint(arena, "{s}/toolchains", .{home});
    const exact = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, name });
    Io.Dir.cwd().access(io, exact, .{}) catch {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.name.len > name.len and std.mem.startsWith(u8, entry.name, name) and entry.name[name.len] == '-') {
                return try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
            }
        }
        return null;
    };
    return exact;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.rust, cfg.version_prefix, data.version, null);
}

test toolchainFile {
    try std.testing.expectEqualStrings("1.85", toolchainFile("[toolchain]\nchannel = \"1.85\"\ncomponents = [\"rustfmt\"]\n").?);
    try std.testing.expectEqualStrings("nightly-2024-05-01", toolchainFile("nightly-2024-05-01\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), toolchainFile("[toolchain]\nprofile = \"minimal\"\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), toolchainFile("\n"));
}

test override {
    const settings =
        \\version = "12"
        \\default_toolchain = "stable-x86_64-unknown-linux-gnu"
        \\
        \\[overrides]
        \\"/home/u/old" = "1.70-x86_64-unknown-linux-gnu"
        \\"/home/u/new" = "nightly-x86_64-unknown-linux-gnu"
        \\
        \\[other]
        \\"/home/u/x" = "beta"
    ;
    try std.testing.expectEqualStrings("nightly-x86_64-unknown-linux-gnu", override(settings, "/home/u/new").?);
    try std.testing.expectEqualStrings("1.70-x86_64-unknown-linux-gnu", override(settings, "/home/u/old").?);
    try std.testing.expectEqual(@as(?[]const u8, null), override(settings, "/home/u"));
    try std.testing.expectEqual(@as(?[]const u8, null), override(settings, "/home/u/x"));
    try std.testing.expectEqualStrings("stable-x86_64-unknown-linux-gnu", lang.iniValue(settings, "default_toolchain").?);
}

test toolchainDir {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "toolchains/stable-x86_64-unknown-linux-gnu");
    try tmp.dir.createDirPath(io, "toolchains/1.85-x86_64-unknown-linux-gnu");
    const home = env.toSlashes(try tmp.dir.realPathFileAlloc(io, ".", a));
    try std.testing.expect(std.mem.endsWith(u8, (try toolchainDir(io, a, home, "stable")).?, "/toolchains/stable-x86_64-unknown-linux-gnu"));
    try std.testing.expect(std.mem.endsWith(u8, (try toolchainDir(io, a, home, "1.85-x86_64-unknown-linux-gnu")).?, "/toolchains/1.85-x86_64-unknown-linux-gnu"));
    try std.testing.expectEqual(@as(?[]const u8, null), try toolchainDir(io, a, home, "1.8"));
    try std.testing.expectEqual(@as(?[]const u8, null), try toolchainDir(io, a, home, "nightly"));
    try std.testing.expectEqual(@as(?[]const u8, null), try toolchainDir(io, a, home, "../x"));
}
