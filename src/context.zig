//! Read-only input shared by every module. Built once per prompt before any
//! module runs, so it is safe to share across worker threads (Phase 1).

const std = @import("std");
const Io = std.Io;
const Shell = @import("render.zig").Shell;

pub const Context = struct {
    io: Io,
    environ: std.process.Environ,
    /// Logical working directory as the user sees it ($PWD, symlinks intact).
    cwd: []const u8,
    /// Physical working directory (getcwd). Used for filesystem walks such as
    /// git discovery, where `..` must mean the real parent.
    physical_cwd: []const u8,
    /// $HOME without trailing slashes; null if unset, empty or "/".
    home: ?[]const u8,
    /// Exit status of the previous command.
    status: i32 = 0,
    /// Duration of the previous command; null if unknown.
    duration_ms: ?u64 = null,
    /// Number of background jobs.
    jobs: u32 = 0,
    shell: Shell = .plain,
    /// BUTA_DEBUG is set: modules report their errors on stderr.
    debug: bool = false,

    pub fn getEnv(ctx: *const Context, name: []const u8) ?[]const u8 {
        return ctx.environ.getPosix(name);
    }
};

/// Normalizes $HOME: strips trailing slashes, rejects "", "/" and relative paths.
pub fn normalizeHome(raw: ?[]const u8) ?[]const u8 {
    const h = std.mem.trimEnd(u8, raw orelse return null, "/");
    if (h.len == 0 or h[0] != '/') return null;
    return h;
}

/// $PWD is trusted when it is absolute and free of `.`/`..` components,
/// which is what POSIX shells guarantee for the logical cwd.
pub fn validPwd(pwd: ?[]const u8) ?[]const u8 {
    const p = pwd orelse return null;
    if (p.len == 0 or p[0] != '/') return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return null;
    }
    return p;
}

test normalizeHome {
    try std.testing.expectEqualStrings("/home/a", normalizeHome("/home/a/").?);
    try std.testing.expectEqualStrings("/home/a", normalizeHome("/home/a").?);
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeHome("/"));
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeHome(""));
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeHome("rel"));
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeHome(null));
}

test validPwd {
    try std.testing.expectEqualStrings("/a/b", validPwd("/a/b").?);
    try std.testing.expectEqualStrings("/", validPwd("/").?);
    try std.testing.expectEqual(@as(?[]const u8, null), validPwd("/a/../b"));
    try std.testing.expectEqual(@as(?[]const u8, null), validPwd("/a/./b"));
    try std.testing.expectEqual(@as(?[]const u8, null), validPwd("a/b"));
}
