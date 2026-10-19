//! Python version and virtual environment. Shown inside a Python project,
//! and anywhere a virtual environment ($VIRTUAL_ENV) or a conda
//! environment other than `base` is active. A virtual environment's
//! version is read from its pyvenv.cfg; otherwise `python3 --version` is
//! run, and kept in the version cache (see lang.zig).

const std = @import("std");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const env = @import("../env.zig");
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const Line = render_mod.Line;
const lang = @import("lang.zig");

pub const id: module.Id = .python;
pub const cost: module.Cost = .expensive;
pub const batch = true;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "yellow", .bold = true },
    symbol: ?[]const u8 = null,
    version_prefix: []const u8 = "v",
    detect: lang.Detect = .{ .files = &.{
        "pyproject.toml", "requirements.txt", "setup.py", "setup.cfg",
        "Pipfile",        ".python-version",  "tox.ini",  "uv.lock",
    } },
    /// The active environment's name, after the version.
    show_env: bool = true,
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = struct {
    version: ?[]const u8,
    /// The virtual or conda environment.
    env: ?[]const u8,
};

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    if (ctx.getEnv("VIRTUAL_ENV")) |raw| if (raw.len > 0) {
        const venv = env.toSlashes(try arena.dupe(u8, std.mem.trimEnd(u8, raw, "/\\")));
        const cfg_path = try std.fmt.allocPrint(arena, "{s}/pyvenv.cfg", .{venv});
        const pyvenv = lang.readSmall(ctx.io, arena, cfg_path) orelse "";
        return .{
            .version = venvVersion(pyvenv) orelse try runPython(ctx, arena),
            .env = if (cfg.show_env) venvName(venv, pyvenv) else null,
        };
    };
    const conda = condaEnv(ctx);
    if (conda == null and try lang.findProject(ctx, arena, cfg.detect) == null) return null;
    return .{
        .version = try runPython(ctx, arena),
        .env = if (cfg.show_env) conda else null,
    };
}

fn runPython(ctx: *const Context, arena: std.mem.Allocator) !?[]const u8 {
    const exe = try lang.which(ctx, arena, "python3") orelse
        try lang.which(ctx, arena, "python") orelse return null;
    return lang.probe(ctx, arena, exe, &.{"--version"});
}

/// `version` (venv, virtualenv) or `version_info` (uv, virtualenv 20+),
/// cut to major.minor.micro: `3.12.1.final.0` is `3.12.1`.
fn venvVersion(pyvenv: []const u8) ?[]const u8 {
    const v = lang.iniValue(pyvenv, "version") orelse lang.iniValue(pyvenv, "version_info") orelse return null;
    var dots: usize = 0;
    for (v, 0..) |c, i| if (c == '.') {
        dots += 1;
        if (dots == 3) return v[0..i];
    };
    return if (v.len > 0) v else null;
}

/// pyvenv.cfg's `prompt` (`uv venv` sets the project name), else the
/// directory's name.
fn venvName(venv: []const u8, pyvenv: []const u8) []const u8 {
    if (lang.iniValue(pyvenv, "prompt")) |p| {
        const name = std.mem.trim(u8, p, " ()");
        if (name.len > 0) return name;
    }
    const slash = std.mem.lastIndexOfScalar(u8, venv, '/') orelse return venv;
    return venv[slash + 1 ..];
}

fn condaEnv(ctx: *const Context) ?[]const u8 {
    const name = ctx.getEnv("CONDA_DEFAULT_ENV") orelse return null;
    if (name.len == 0 or std.mem.eql(u8, name, "base")) return null;
    return name;
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    try lang.draw(line, cfg.style, cfg.symbol orelse g.python, cfg.version_prefix, data.version, data.env);
}

test venvVersion {
    try std.testing.expectEqualStrings("3.11.4", venvVersion("home = /usr/bin\nversion = 3.11.4\n").?);
    try std.testing.expectEqualStrings("3.12.1", venvVersion("version_info = 3.12.1.final.0\n").?);
    try std.testing.expectEqualStrings("3.13", venvVersion("version_info = 3.13\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), venvVersion("home = /usr/bin\n"));
}

test venvName {
    try std.testing.expectEqualStrings(".venv", venvName("/home/u/proj/.venv", "version = 3.12.1\n"));
    try std.testing.expectEqualStrings("proj", venvName("/home/u/proj/.venv", "prompt = proj\n"));
    try std.testing.expectEqualStrings("proj", venvName("/home/u/proj/.venv", "prompt = (proj) \n"));
}

test "python rendering" {
    const g = @import("../glyphs.zig").get(.ascii);
    var line: Line = .{};
    try render(&.{ .version = "3.12.1", .env = ".venv" }, &.{}, g, &line);
    try render(&.{ .version = "3.12.1", .env = null }, &.{}, g, &line);
    try std.testing.expectEqualStrings("py v3.12.1 (.venv)", line.items()[0].text);
    try std.testing.expectEqualStrings("py v3.12.1", line.items()[1].text);
}
