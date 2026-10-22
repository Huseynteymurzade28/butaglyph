//! Repository status from butaglyph's own git reader: staged, renamed,
//! modified, deleted, conflicted and untracked paths, and commits ahead of/behind the
//! upstream. Hidden when there is nothing to report.

const std = @import("std");
const git = @import("git");
const module = @import("../module.zig");
const Context = @import("../context.zig").Context;
const Glyphs = @import("../glyphs.zig").Glyphs;
const render_mod = @import("../render.zig");
const lang = @import("lang.zig");
const env = @import("../env.zig");
const Line = render_mod.Line;

pub const id: module.Id = .git_status;
pub const cost: module.Cost = .expensive;
pub const scope: module.Scope = .repo;

pub const Config = struct {
    style: render_mod.Style = .{ .fg = "red", .bold = true },
    staged_symbol: ?[]const u8 = null,
    renamed_symbol: ?[]const u8 = null,
    modified_symbol: ?[]const u8 = null,
    deleted_symbol: ?[]const u8 = null,
    conflicted_symbol: ?[]const u8 = null,
    untracked_symbol: ?[]const u8 = null,
    ahead_symbol: ?[]const u8 = null,
    behind_symbol: ?[]const u8 = null,
    /// Show "+2" rather than "+".
    show_counts: bool = true,
    /// Walk history to count commits ahead of/behind the upstream.
    ahead_behind: bool = true,
    /// Compare the index with the working tree (stat of every tracked file).
    worktree: bool = true,
    /// Count untracked files (a walk of the work tree, skipping ignored
    /// directories). The repository's `status.showUntrackedFiles` applies.
    untracked: bool = true,
    /// Overrides the global `timeout_ms` for this module.
    timeout_ms: ?u32 = null,
};

pub const Data = git.Status;

pub fn compute(ctx: *const Context, cfg: *const Config, arena: std.mem.Allocator) !?Data {
    const repo = try git.repo.discover(ctx.io, arena, ctx.physical_cwd) orelse return null;
    const st = try git.status.compute(ctx.io, arena, repo, .{
        .worktree = cfg.worktree,
        .untracked = cfg.untracked,
        .ahead_behind = cfg.ahead_behind,
        .global = try globalFiles(ctx, arena),
    });
    const ahead = st.ahead orelse 0;
    const behind = st.behind orelse 0;
    if (st.staged + st.renamed + st.modified + st.deleted + st.conflicted + st.untracked + ahead + behind == 0) return null;
    return st;
}

/// Where git looks for the user's global and system config and excludes.
pub fn globalFiles(ctx: *const Context, arena: std.mem.Allocator) !git.status.Global {
    return .{
        .home = ctx.home,
        .xdg_config_home = ctx.getEnv("XDG_CONFIG_HOME"),
        .config_global = ctx.getEnv("GIT_CONFIG_GLOBAL"),
        .system = try systemFile(ctx, arena),
    };
}

/// $GIT_CONFIG_SYSTEM, else the file next to the `git` in $PATH, unless
/// $GIT_CONFIG_NOSYSTEM is set.
fn systemFile(ctx: *const Context, arena: std.mem.Allocator) !?[]const u8 {
    if (ctx.getEnv("GIT_CONFIG_NOSYSTEM")) |v| {
        for ([_][]const u8{ "1", "true", "yes", "on" }) |t| if (std.ascii.eqlIgnoreCase(v, t)) return null;
    }
    if (ctx.getEnv("GIT_CONFIG_SYSTEM")) |p| return if (p.len > 0) p else null;
    const exe = if (try lang.which(ctx, arena, "git")) |e| env.toSlashes(try arena.dupe(u8, e)) else null;
    return git.status.systemConfig(arena, exe, env.is_windows);
}

pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    const parts = [_]struct { u32, []const u8 }{
        .{ data.conflicted, cfg.conflicted_symbol orelse g.git_conflicted },
        .{ data.staged, cfg.staged_symbol orelse g.git_staged },
        .{ data.renamed, cfg.renamed_symbol orelse g.git_renamed },
        .{ data.modified, cfg.modified_symbol orelse g.git_modified },
        .{ data.deleted, cfg.deleted_symbol orelse g.git_deleted },
        .{ data.untracked, cfg.untracked_symbol orelse g.git_untracked },
        .{ data.ahead orelse 0, cfg.ahead_symbol orelse g.git_ahead },
        .{ data.behind orelse 0, cfg.behind_symbol orelse g.git_behind },
    };
    var first = true;
    for (parts) |p| {
        if (p[0] == 0) continue;
        if (!first) try line.text(cfg.style, " ");
        first = false;
        if (cfg.show_counts) {
            try line.print(cfg.style, "{s}{d}", .{ p[1], p[0] });
        } else {
            try line.text(cfg.style, p[1]);
        }
    }
}

test "git_status rendering" {
    const glyphs = @import("../glyphs.zig");
    var line: Line = .{};
    try render(&.{ .staged = 2, .renamed = 1, .modified = 1, .ahead = 3, .behind = 0 }, &.{}, glyphs.get(.ascii), &line);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (line.items()) |s| try text.appendSlice(std.testing.allocator, s.text);
    try std.testing.expectEqualStrings("+2 >1 !1 ^3", text.items);

    line = .{};
    try render(&.{ .conflicted = 1, .deleted = 4, .untracked = 2 }, &.{ .show_counts = false }, glyphs.get(.ascii), &line);
    text.clearRetainingCapacity();
    for (line.items()) |s| try text.appendSlice(std.testing.allocator, s.text);
    try std.testing.expectEqualStrings("= - ?", text.items);
}
