//! What `buta prompt` and `buta daemon` say to each other over a Unix
//! socket.
//!
//! The client sends one request:
//!
//!   "BUTA"  fingerprint: u64  length: u32  wire(Request)
//!
//! For a `prompt` request the daemon answers with one frame per requested
//! module, in whatever order results become ready (cache hits first):
//!
//!   length: u32  wire(Frame)
//!
//! and then closes the connection. A daemon whose fingerprint differs (it
//! was built from other sources) closes the connection without answering,
//! and the client computes everything itself. Integers in the header are
//! little-endian.

const std = @import("std");
const sys = @import("sys.zig");
const module = @import("module.zig");
const wire = @import("wire.zig");

pub const magic = "BUTA";
pub const header_len = magic.len + 8 + 4;
/// Largest request or frame either side accepts.
pub const max_message = 1024 * 1024;

pub const Request = union(enum) {
    prompt: Prompt,
    status,
    stop,
};

pub const Prompt = struct {
    /// Physical working directory of the shell.
    cwd: []const u8,
    debug: bool,
    modules: []const ModuleRequest,
};

pub const ModuleRequest = struct {
    id: module.Id,
    /// wire(Impl(id).Config): the client's configuration for the module.
    config: []const u8,
};

pub const Frame = struct {
    id: module.Id,
    /// wire(Impl(id).Data), or null when the module renders nothing.
    data: ?[]const u8,
};

pub const Status = struct {
    pid: i32,
    uptime_s: u64,
    repos: u32,
    watches: u32,
    hits: u64,
    misses: u64,
};

/// Changes whenever anything that crosses the socket changes shape: the
/// messages above, or the Config or Data of a module the daemon serves.
pub const fingerprint: u64 = blk: {
    var h = std.hash.Wyhash.init(0);
    for ([_]u64{ wire.fingerprint(Request), wire.fingerprint(Frame), wire.fingerprint(Status) }) |f| {
        h.update(std.mem.asBytes(&f));
    }
    for (module.ids) |id| {
        const M = module.Impl(id);
        if (module.scopeOf(M) == .repo) {
            h.update(@tagName(id));
            h.update(std.mem.asBytes(&wire.fingerprint(M.Config)));
            h.update(std.mem.asBytes(&wire.fingerprint(M.Data)));
        }
    }
    break :blk h.final();
};

/// Linux (inotify) and macOS (kqueue).
pub const supported = sys.supported;

/// `$BUTA_SOCKET` if set (empty disables the daemon), else
/// `$XDG_RUNTIME_DIR/butaglyph.sock`, else on macOS
/// `$TMPDIR/butaglyph.sock`. Without any of them there is no daemon: those
/// directories are private to the user, while a socket in a shared
/// directory such as /tmp would need more care than it is worth.
pub fn socketPath(buf: *[std.Io.net.UnixAddress.max_len]u8, getenv: anytype) ?[:0]const u8 {
    if (!supported) return null;
    if (getenv.get("BUTA_SOCKET")) |p| {
        if (p.len == 0) return null;
        return fit(buf, p, "");
    }
    if (getenv.get("XDG_RUNTIME_DIR")) |dir| return dirPath(buf, dir);
    if (sys.is_darwin) if (getenv.get("TMPDIR")) |dir| return dirPath(buf, dir);
    return null;
}

fn dirPath(buf: *[std.Io.net.UnixAddress.max_len]u8, dir: []const u8) ?[:0]const u8 {
    if (dir.len == 0 or dir[0] != '/') return null;
    return fit(buf, std.mem.trimEnd(u8, dir, "/"), "/butaglyph.sock");
}

fn fit(buf: *[std.Io.net.UnixAddress.max_len]u8, a: []const u8, b: []const u8) ?[:0]const u8 {
    if (a.len + b.len > sys.max_socket_path) return null;
    return std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ a, b }, 0) catch null;
}

pub fn writeHeader(w: *std.Io.Writer, payload_len: usize) std.Io.Writer.Error!void {
    try w.writeAll(magic);
    try w.writeInt(u64, fingerprint, .little);
    try w.writeInt(u32, @intCast(payload_len), .little);
}

pub const HeaderError = error{ BadMagic, FingerprintMismatch, MessageTooLarge };

/// Checks a request header and returns the payload length.
pub fn parseHeader(h: *const [header_len]u8) HeaderError!u32 {
    if (!std.mem.eql(u8, h[0..magic.len], magic)) return error.BadMagic;
    if (std.mem.readInt(u64, h[magic.len..][0..8], .little) != fingerprint) return error.FingerprintMismatch;
    const len = std.mem.readInt(u32, h[magic.len + 8 ..][0..4], .little);
    if (len > max_message) return error.MessageTooLarge;
    return len;
}

const TestEnv = struct {
    map: []const [2][]const u8,
    pub fn get(e: TestEnv, k: []const u8) ?[]const u8 {
        for (e.map) |kv| if (std.mem.eql(u8, kv[0], k)) return kv[1];
        return null;
    }
};

test socketPath {
    if (!supported) return error.SkipZigTest;
    var buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    try std.testing.expectEqualStrings("/s.sock", socketPath(&buf, TestEnv{ .map = &.{ .{ "BUTA_SOCKET", "/s.sock" }, .{ "XDG_RUNTIME_DIR", "/run/user/1" } } }).?);
    try std.testing.expectEqualStrings("/run/user/1/butaglyph.sock", socketPath(&buf, TestEnv{ .map = &.{.{ "XDG_RUNTIME_DIR", "/run/user/1/" }} }).?);
    try std.testing.expectEqual(null, socketPath(&buf, TestEnv{ .map = &.{ .{ "BUTA_SOCKET", "" }, .{ "XDG_RUNTIME_DIR", "/run/user/1" } } }));
    try std.testing.expectEqual(null, socketPath(&buf, TestEnv{ .map = &.{.{ "XDG_RUNTIME_DIR", "rel" }} }));
    try std.testing.expectEqual(null, socketPath(&buf, TestEnv{ .map = &.{} }));
    const long = "/" ++ @as([120]u8, @splat('x'));
    try std.testing.expectEqual(null, socketPath(&buf, TestEnv{ .map = &.{.{ "BUTA_SOCKET", long }} }));
}

test parseHeader {
    var buf: [header_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHeader(&w, 42);
    try std.testing.expectEqual(@as(u32, 42), try parseHeader(&buf));
    buf[magic.len] ^= 1;
    try std.testing.expectError(error.FingerprintMismatch, parseHeader(&buf));
    buf[0] = 'X';
    try std.testing.expectError(error.BadMagic, parseHeader(&buf));
}
