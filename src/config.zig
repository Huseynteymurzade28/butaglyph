//! Configuration: $BUTA_CONFIG, else $XDG_CONFIG_HOME/butaglyph/config.zon,
//! else ~/.config/butaglyph/config.zon. Every field has a default, so a
//! missing file (or a missing field) means "use the defaults".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const module = @import("module.zig");
const glyphs = @import("glyphs.zig");
const env = @import("env.zig");
const m = module.impls;

pub const Config = struct {
    /// Glyph set: .unicode (any font), .nerd (icons, needs a Nerd Font)
    /// or .ascii.
    glyphs: glyphs.Set = .unicode,
    /// Modules in display order. A module not listed here is never computed.
    order: []const module.Id = &default_order,
    /// Inserted between two non-empty modules on the same line.
    separator: []const u8 = " ",
    /// Deadline for expensive modules (git), in ms from prompt start. A
    /// module that misses it is left out of this prompt. Modules can
    /// override it with their own `timeout_ms`.
    timeout_ms: u32 = 100,
    /// The cache daemon (`buta daemon`, Linux and macOS): `.auto` uses it
    /// and starts it in the background when it isn't running, `.manual`
    /// uses it only when it runs, `.off` never asks it.
    daemon: DaemonMode = .auto,
    /// Draws modules that have a background color as joined segments
    /// (powerline style). The joints take their colors from the
    /// neighboring segments. null: modules are just separated.
    segments: ?Segments = null,

    dir: m.dir.Config = .{},
    git_branch: m.git_branch.Config = .{},
    git_status: m.git_status.Config = .{},
    status: m.status.Config = .{},
    duration: m.duration.Config = .{},
    character: m.character.Config = .{},
    jobs: m.jobs.Config = .{},
    line_break: m.line_break.Config = .{},
    text: m.text.Config = .{},
    python: m.python.Config = .{},
    node: m.node.Config = .{},
    rust: m.rust.Config = .{},
    go: m.go.Config = .{},
    zig: m.zig.Config = .{},
    docker_context: m.docker_context.Config = .{},
    kubernetes: m.kubernetes.Config = .{},
    aws: m.aws.Config = .{},
    os: m.os.Config = .{},
    user: m.user.Config = .{},
};

pub const DaemonMode = enum { auto, manual, off };

/// Segment shapes. The defaults are half blocks, which every font has;
/// see docs/configuration.md for others.
pub const Segments = struct {
    /// Before a run of segments, in the first one's background color.
    open: []const u8 = "\u{2590}", // ▐
    /// Between two segments: the left one's background on the right one's.
    /// null draws every segment on its own (close, separator, open): pills.
    join: ?[]const u8 = "\u{258c}", // ▌
    /// After a run of segments, in the last one's background color.
    close: []const u8 = "\u{258c}", // ▌
    /// Inside each segment, on both sides of its text.
    padding: []const u8 = " ",
};

pub const default_order = [_]module.Id{ .dir, .git_branch, .git_status, .python, .node, .rust, .go, .zig, .aws, .duration, .status, .jobs, .line_break, .character };

/// Largest config file we accept; larger files are reported and ignored.
const max_file_size = 64 * 1024;

/// Returns the configured path or null if no location can be determined.
pub fn path(buf: []u8, getenv: anytype, home: ?[]const u8) ?[]const u8 {
    if (getenv.get("BUTA_CONFIG")) |p| if (p.len > 0) return p;
    if (getenv.get("XDG_CONFIG_HOME")) |x| {
        // The XDG spec says relative values must be ignored.
        if (env.isAbsolute(x)) return std.fmt.bufPrint(buf, "{s}/butaglyph/config.zon", .{x}) catch null;
    }
    const h = home orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/butaglyph/config.zon", .{h}) catch null;
}

pub const LoadResult = struct {
    config: Config,
    /// Human-readable problem with the file, if it existed but was unusable.
    /// The returned config is then the default one.
    problem: ?[]const u8 = null,
};

/// Never fails: any problem yields the default config plus a message.
pub fn load(io: Io, arena: Allocator, file_path: []const u8) LoadResult {
    const source = Io.Dir.cwd().readFileAllocOptions(io, file_path, arena, .limited(max_file_size), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return .{ .config = .{} },
        else => return .{ .config = .{}, .problem = std.fmt.allocPrint(arena, "{s}: {s}", .{ file_path, @errorName(err) }) catch "config: out of memory" },
    };
    return parse(arena, source, file_path);
}

pub fn parse(arena: Allocator, raw: [:0]const u8, file_path: []const u8) LoadResult {
    const source = decode(arena, raw) orelse return .{
        .config = .{},
        .problem = std.fmt.allocPrint(arena, "{s}: not valid UTF-16", .{file_path}) catch "config: bad encoding",
    };
    var diag: std.zon.parse.Diagnostics = .{};
    // The ZON parser unrolls a loop per Config field at compile time.
    @setEvalBranchQuota(4000);
    const cfg = std.zon.parse.fromSliceAlloc(Config, arena, source, &diag, .{ .free_on_error = false }) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            error.ParseZon => std.fmt.allocPrint(arena, "{f}", .{diag}) catch "parse error",
        };
        return .{
            .config = .{},
            .problem = std.fmt.allocPrint(arena, "{s}:{s}", .{ file_path, std.mem.trimEnd(u8, msg, "\n") }) catch "config: parse error",
        };
    };
    return .{ .config = cfg };
}

/// UTF-8, without a byte order mark. Windows editors and PowerShell 5.1's
/// `>` write a BOM, or UTF-16: both are accepted.
fn decode(arena: Allocator, raw: [:0]const u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) return raw[3.. :0];
    if (!std.mem.startsWith(u8, raw, "\xFF\xFE") or raw.len % 2 != 0) return raw;
    const units = arena.alloc(u16, raw.len / 2 - 1) catch return null;
    for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, raw[2 + 2 * i ..][0..2], .little);
    return std.unicode.utf16LeToUtf8AllocZ(arena, units) catch null;
}

const TestEnv = struct {
    map: []const [2][]const u8,
    pub fn get(e: TestEnv, k: []const u8) ?[]const u8 {
        for (e.map) |kv| if (std.mem.eql(u8, kv[0], k)) return kv[1];
        return null;
    }
};

test "config path resolution" {
    const r = if (env.is_windows) "C:" else ""; // an absolute path's root
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/c.zon", path(&buf, TestEnv{ .map = &.{ .{ "BUTA_CONFIG", "/c.zon" }, .{ "XDG_CONFIG_HOME", r ++ "/x" } } }, r ++ "/h").?);
    try std.testing.expectEqualStrings(r ++ "/x/butaglyph/config.zon", path(&buf, TestEnv{ .map = &.{.{ "XDG_CONFIG_HOME", r ++ "/x" }} }, r ++ "/h").?);
    try std.testing.expectEqualStrings(r ++ "/h/.config/butaglyph/config.zon", path(&buf, TestEnv{ .map = &.{.{ "XDG_CONFIG_HOME", "rel" }} }, r ++ "/h").?);
    try std.testing.expectEqual(@as(?[]const u8, null), path(&buf, TestEnv{ .map = &.{} }, null));
}

test "empty config gives defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = parse(arena.allocator(), ".{}", "t.zon");
    try std.testing.expectEqual(@as(?[]const u8, null), r.problem);
    try std.testing.expectEqual(glyphs.Set.unicode, r.config.glyphs);
    try std.testing.expectEqualSlices(module.Id, &default_order, r.config.order);
    try std.testing.expectEqual(@as(u64, 2000), r.config.duration.min_ms);
    try std.testing.expectEqual(@as(u32, 100), r.config.timeout_ms);
    try std.testing.expectEqual(@as(?u32, null), r.config.git_branch.timeout_ms);
}

test "config overrides order, glyphs, colors and symbols" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = parse(arena.allocator(),
        \\.{
        \\    .glyphs = .ascii,
        \\    .order = .{ .git_branch, .dir, .character },
        \\    .separator = " | ",
        \\    .dir = .{ .style = .{ .fg = "#ff8800", .bold = false }, .max_length = 0 },
        \\    .git_branch = .{ .symbol = "on ", .timeout_ms = 10 },
        \\    .timeout_ms = 40,
        \\    .duration = .{ .min_ms = 500 },
        \\    .character = .{ .success_symbol = "$" },
        \\}
    , "t.zon");
    try std.testing.expectEqual(@as(?[]const u8, null), r.problem);
    const c = r.config;
    try std.testing.expectEqual(glyphs.Set.ascii, c.glyphs);
    try std.testing.expectEqualSlices(module.Id, &.{ .git_branch, .dir, .character }, c.order);
    try std.testing.expectEqualStrings(" | ", c.separator);
    try std.testing.expectEqualStrings("#ff8800", c.dir.style.fg.?);
    try std.testing.expect(!c.dir.style.bold);
    try std.testing.expectEqual(@as(u16, 0), c.dir.max_length);
    try std.testing.expectEqualStrings("on ", c.git_branch.symbol.?);
    try std.testing.expectEqual(@as(u32, 40), c.timeout_ms);
    try std.testing.expectEqual(@as(?u32, 10), c.git_branch.timeout_ms);
    try std.testing.expectEqual(@as(u64, 500), c.duration.min_ms);
    try std.testing.expectEqualStrings("$", c.character.success_symbol.?);
    // Untouched sections keep their defaults.
    try std.testing.expectEqualStrings("red", c.status.style.fg.?);
}

test "configs saved with a BOM or as UTF-16 (Windows) are read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = ".{ .separator = \"❧\" }";
    const bom = parse(a, "\xEF\xBB\xBF" ++ text, "t.zon");
    try std.testing.expectEqual(@as(?[]const u8, null), bom.problem);
    try std.testing.expectEqualStrings("❧", bom.config.separator);

    var utf16: std.ArrayList(u8) = .empty;
    try utf16.appendSlice(a, "\xFF\xFE");
    const units = try std.unicode.utf8ToUtf16LeAlloc(a, text);
    for (units) |u| try utf16.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, u)));
    const r = parse(a, try a.dupeZ(u8, utf16.items), "t.zon");
    try std.testing.expectEqual(@as(?[]const u8, null), r.problem);
    try std.testing.expectEqualStrings("❧", r.config.separator);
}

test "invalid config falls back to defaults with a located message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = parse(arena.allocator(), ".{\n  .glyphs = .emoji,\n}", "t.zon");
    try std.testing.expectEqual(glyphs.Set.unicode, r.config.glyphs);
    try std.testing.expect(std.mem.startsWith(u8, r.problem.?, "t.zon:2:"));

    const typo = parse(arena.allocator(), ".{ .dirr = .{} }", "t.zon");
    try std.testing.expect(typo.problem != null);

    const syntax = parse(arena.allocator(), ".{ .glyphs = ", "t.zon");
    try std.testing.expect(syntax.problem != null);
}
