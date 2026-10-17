//! Current directory: $HOME shown as `~`, intermediate directories
//! abbreviated fish-style (`~/d/b/src`) once the path gets long.

const std = @import("std");
const Writer = std.Io.Writer;
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;

pub const id: module.Id = .dir;
pub const cost: module.Cost = .cheap;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "cyan", .bold = true },
    home_symbol: []const u8 = "~",
    abbreviate: bool = true,
    /// Abbreviate only when the full path is longer than this many
    /// characters; 0 abbreviates always.
    max_length: u16 = 30,
    /// Characters kept from each abbreviated directory (a leading `.` is extra).
    abbrev_len: u8 = 1,
    /// Trailing directories that are never abbreviated.
    full_dirs: u8 = 1,
};

pub const Data = struct {
    /// With `home_relative`, the part after $HOME ("" or "/..."); otherwise the absolute path.
    path: []const u8,
    home_relative: bool,
};

pub fn compute(ctx: *const Context, _: *const Config, _: std.mem.Allocator) !?Data {
    return split(ctx.cwd, ctx.home);
}

fn split(cwd: []const u8, home: ?[]const u8) Data {
    if (home) |h| {
        if (env.startsWithPath(cwd, h) and (cwd.len == h.len or cwd[h.len] == '/')) {
            return .{ .path = cwd[h.len..], .home_relative = true };
        }
    }
    return .{ .path = cwd, .home_relative = false };
}

pub fn render(data: *const Data, cfg: *const Config, _: *const Glyphs, line: *Line) Line.Error!void {
    var w: Writer = .fixed(line.scratchBuffer());
    formatPath(&w, data.*, cfg) catch return error.NoSpaceLeft;
    try line.commitScratch(cfg.style, w.end);
}

pub fn formatPath(w: *Writer, data: Data, cfg: *const Config) Writer.Error!void {
    const prefix = if (data.home_relative) cfg.home_symbol else "";
    const long = codepoints(prefix) + codepoints(data.path) > cfg.max_length;
    if (!cfg.abbreviate or (cfg.max_length > 0 and !long)) {
        try w.writeAll(prefix);
        try w.writeAll(if (!data.home_relative and data.path.len == 0) "/" else data.path);
        return;
    }

    try w.writeAll(prefix);
    var total: usize = 0;
    var count_it = std.mem.tokenizeScalar(u8, data.path, '/');
    while (count_it.next()) |_| total += 1;
    if (total == 0 and !data.home_relative) return w.writeAll("/");

    // Windows roots are never abbreviated: the drive (`C:/...`, written
    // without a leading slash) and a UNC `//server/share`.
    const drive = !data.home_relative and data.path.len > 0 and data.path[0] != '/';
    const unc = !data.home_relative and std.mem.startsWith(u8, data.path, "//");
    const root_comps: usize = if (drive) 1 else if (unc) 2 else 0;
    if (unc) try w.writeByte('/');
    var it = std.mem.tokenizeScalar(u8, data.path, '/');
    var i: usize = 0;
    while (it.next()) |comp| : (i += 1) {
        if (!(drive and i == 0)) try w.writeByte('/');
        if (i < root_comps) {
            try w.writeAll(comp);
            if (drive and total == 1) try w.writeByte('/');
        } else if (i + cfg.full_dirs >= total) {
            try w.writeAll(comp);
        } else {
            try w.writeAll(abbreviateComponent(comp, cfg.abbrev_len));
        }
    }
}

/// First `n` UTF-8 code points of `comp`, plus a leading dot for hidden dirs.
fn abbreviateComponent(comp: []const u8, n: usize) []const u8 {
    if (n == 0) return comp;
    var end: usize = if (comp.len > 0 and comp[0] == '.') 1 else 0;
    var kept: usize = 0;
    while (end < comp.len and kept < n) : (kept += 1) {
        end += std.unicode.utf8ByteSequenceLength(comp[end]) catch 1;
    }
    return comp[0..@min(end, comp.len)];
}

fn codepoints(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn expectPath(expected: []const u8, cwd: []const u8, home: ?[]const u8, cfg: Config) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try formatPath(&w, split(cwd, home), &cfg);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "home substitution" {
    try expectPath("~", "/home/u", "/home/u", .{});
    try expectPath("~/src", "/home/u/src", "/home/u", .{});
    try expectPath("/home/user2", "/home/user2", "/home/u", .{});
    try expectPath("/etc", "/etc", "/home/u", .{});
    try expectPath("/", "/", "/home/u", .{});
    try expectPath("/etc", "/etc", null, .{});
    try expectPath("H/x", "/home/u/x", "/home/u", .{ .home_symbol = "H" });
}

test "short paths are left alone" {
    try expectPath("~/dev/butaglyph/src", "/home/u/dev/butaglyph/src", "/home/u", .{});
}

test "long paths are abbreviated fish-style" {
    const long = "/home/u/dev/projects/butaglyph/src/modules";
    try expectPath("~/d/p/b/s/modules", long, "/home/u", .{});
    try expectPath("~/d/p/b/src/modules", long, "/home/u", .{ .full_dirs = 2 });
    try expectPath("~/de/pr/bu/sr/modules", long, "/home/u", .{ .abbrev_len = 2 });
    try expectPath("~/dev/projects/butaglyph/src/modules", long, "/home/u", .{ .abbreviate = false });
    try expectPath("/u/l/s/doc/zig", "/usr/local/share/doc/zig", null, .{ .max_length = 0, .full_dirs = 2 });
}

test "Windows paths keep their drive" {
    try expectPath("C:/U/x/dev", "C:/Users/x/dev", null, .{ .max_length = 0 });
    try expectPath("C:/", "C:/", null, .{ .max_length = 0 });
    try expectPath("C:/Windows", "C:/Windows", null, .{});
    try expectPath("//server/share/dir", "//server/share/dir", null, .{ .max_length = 0 });
    try expectPath("~/d/src", "C:/Users/x/dev/src", "C:/Users/x", .{ .max_length = 0 });
}

test "max_length = 0 always abbreviates" {
    try expectPath("~/d/src", "/home/u/dev/src", "/home/u", .{ .max_length = 0 });
    try expectPath("~", "/home/u", "/home/u", .{ .max_length = 0 });
    try expectPath("/", "/", null, .{ .max_length = 0 });
    try expectPath("/etc", "/etc", null, .{ .max_length = 0 });
}

test "hidden directories keep their dot" {
    try expectPath("~/.c/n/lua", "/home/u/.config/nvim/lua", "/home/u", .{ .max_length = 0 });
}

test "abbreviation is UTF-8 aware" {
    // Azerbaijani: Şəkillər (pictures), Sənədlər (documents)
    try expectPath("~/Ş/S/son", "/home/u/Şəkillər/Sənədlər/son", "/home/u", .{ .max_length = 0 });
    try expectPath("~/Şə/Sə/son", "/home/u/Şəkillər/Sənədlər/son", "/home/u", .{ .max_length = 0, .abbrev_len = 2 });
    // Length is measured in code points, not bytes: 19 code points, 25 bytes.
    try expectPath("~/Şəkillər/Sənədlər", "/home/u/Şəkillər/Sənədlər", "/home/u", .{ .max_length = 19 });
}
