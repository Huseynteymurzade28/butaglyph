//! Environment variables and paths, the same way on every platform.
//!
//! POSIX reads the process environment in place. Windows keeps it as
//! UTF-16, so it is converted once into a map (WTF-8 keys and values, names
//! compared case-insensitively, as Windows does).
//!
//! Paths inside buta always use `/`. Windows accepts it everywhere, and it
//! lets the git reader and the modules split paths the same way on every
//! platform; `toSlashes` converts what comes from the OS.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

pub const Env = struct {
    environ: std.process.Environ,
    /// Windows only: the converted environment.
    map: ?*const std.process.Environ.Map = null,

    /// On Windows, converts the environment with `gpa`; the map is never
    /// freed (it lives as long as the process).
    pub fn init(environ: std.process.Environ, gpa: std.mem.Allocator) Env {
        if (!is_windows) return .{ .environ = environ };
        const map = gpa.create(std.process.Environ.Map) catch return .{ .environ = environ };
        map.* = environ.createMap(gpa) catch {
            gpa.destroy(map);
            return .{ .environ = environ };
        };
        return .{ .environ = environ, .map = map };
    }

    pub fn get(e: Env, name: []const u8) ?[]const u8 {
        if (is_windows) return if (e.map) |m| m.get(name) else null;
        return e.environ.getPosix(name);
    }

    /// The variable is set and not empty.
    pub fn flag(e: Env, name: []const u8) bool {
        return if (e.get(name)) |v| v.len > 0 else false;
    }
};

/// Replaces `\` with `/` on Windows (in place). Elsewhere `\` is an
/// ordinary file name character and is left alone.
pub fn toSlashes(path: []u8) []u8 {
    if (is_windows) std.mem.replaceScalar(u8, path, '\\', '/');
    return path;
}

/// Copies `path` into `buf` with `toSlashes` applied; null if it doesn't fit.
pub fn toSlashesCopy(buf: []u8, path: []const u8) ?[]u8 {
    if (path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    return toSlashes(buf[0..path.len]);
}

/// Absolute in the `/`-separated form: `/x` on POSIX; `C:/x` or `//server/share`
/// on Windows.
pub fn isAbsolute(path: []const u8) bool {
    if (!is_windows) return path.len > 0 and path[0] == '/';
    return isAbsoluteWindows(path);
}

fn isAbsoluteWindows(path: []const u8) bool {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and path[2] == '/') return true;
    return std.mem.startsWith(u8, path, "//");
}

/// Length of the root of an absolute path: 1 for `/`, 3 for `C:/`, 2 for `//`.
pub fn rootLen(path: []const u8) usize {
    if (is_windows and path.len >= 3 and path[1] == ':') return 3;
    if (is_windows and std.mem.startsWith(u8, path, "//")) return 2;
    return 1;
}

/// Path prefix test that follows the platform's case rules (Windows file
/// names are case-insensitive).
pub fn startsWithPath(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    if (is_windows) return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
    return std.mem.eql(u8, path[0..prefix.len], prefix);
}

test isAbsoluteWindows {
    try std.testing.expect(isAbsoluteWindows("C:/Users"));
    try std.testing.expect(isAbsoluteWindows("//server/share"));
    try std.testing.expect(!isAbsoluteWindows("C:rel"));
    try std.testing.expect(!isAbsoluteWindows("/c/Users"));
    try std.testing.expect(!isAbsoluteWindows("rel"));
}
