//! The Unix primitives the daemon and its client use: Unix sockets, file
//! locks, process control and signals. Linux makes raw syscalls (buta links
//! no libc there); macOS goes through libc. Errors are reduced to the few
//! cases callers act on.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;

pub const is_linux = builtin.os.tag == .linux;
pub const is_darwin = builtin.os.tag.isDarwin();
/// Where the daemon (and so the client side of it) exists.
pub const supported = is_linux or is_darwin;

pub const fd_t = i32;

pub const Error = error{
    Interrupted,
    WouldBlock,
    NotFound,
    NotDir,
    Refused,
    /// inotify watches (fs.inotify.max_user_watches) or disk space.
    NoSpace,
    TooManyFiles,
    AccessDenied,
    NameTooLong,
    Unexpected,
};

fn check(rc: anytype) Error!void {
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .NOENT => error.NotFound,
        .NOTDIR => error.NotDir,
        .CONNREFUSED => error.Refused,
        .NOSPC => error.NoSpace,
        .MFILE, .NFILE => error.TooManyFiles,
        .ACCES, .PERM => error.AccessDenied,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn toFd(rc: anytype) fd_t {
    return @intCast(rc);
}

// ---------------------------------------------------------------- sockets

const sockaddr_un = system.sockaddr.un;
/// Longest socket path (sun_path minus its terminating NUL): 107 bytes on
/// Linux, 103 on macOS.
pub const max_socket_path = @typeInfo(@FieldType(sockaddr_un, "path")).array.len - 1;

fn address(path: []const u8) Error!sockaddr_un {
    if (path.len > max_socket_path) return error.NameTooLong;
    var a: sockaddr_un = .{ .path = @splat(0) };
    @memcpy(a.path[0..path.len], path);
    return a;
}

/// A close-on-exec Unix stream socket that never raises SIGPIPE.
pub fn socket(nonblocking: bool) Error!fd_t {
    if (is_linux) {
        const nonblock: u32 = if (nonblocking) posix.SOCK.NONBLOCK else 0;
        const flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | nonblock;
        const rc = system.socket(posix.AF.UNIX, flags, 0);
        try check(rc);
        return toFd(rc);
    }
    const rc = system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try check(rc);
    const fd = toFd(rc);
    errdefer close(fd);
    try prepare(fd, nonblocking);
    return fd;
}

/// macOS has no SOCK_CLOEXEC, SOCK_NONBLOCK or MSG_NOSIGNAL.
fn prepare(fd: fd_t, nonblocking: bool) Error!void {
    try check(system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)));
    if (nonblocking) {
        const fl = system.fcntl(fd, posix.F.GETFL);
        try check(fl);
        const nonblock: c_int = @bitCast(posix.O{ .NONBLOCK = true });
        try check(system.fcntl(fd, posix.F.SETFL, fl | nonblock));
    }
    const one: c_int = 1;
    try check(system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, &one, @sizeOf(c_int)));
}

pub fn connect(fd: fd_t, path: []const u8) Error!void {
    const a = try address(path);
    try check(system.connect(fd, @ptrCast(&a), @sizeOf(sockaddr_un)));
}

pub fn listen(fd: fd_t, path: []const u8) Error!void {
    const a = try address(path);
    try check(system.bind(fd, @ptrCast(&a), @sizeOf(sockaddr_un)));
    try check(system.listen(fd, 128));
}

pub fn accept(fd: fd_t) Error!fd_t {
    if (is_linux) {
        const rc = system.accept4(fd, null, null, posix.SOCK.CLOEXEC);
        try check(rc);
        return toFd(rc);
    }
    const rc = system.accept(fd, null, null);
    try check(rc);
    const conn = toFd(rc);
    errdefer close(conn);
    try prepare(conn, false);
    return conn;
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    const rc = system.read(fd, buf.ptr, buf.len);
    try check(rc);
    return @intCast(rc);
}

pub fn send(fd: fd_t, bytes: []const u8) Error!usize {
    const rc = if (is_linux)
        system.sendto(fd, bytes.ptr, bytes.len, posix.MSG.NOSIGNAL, null, 0)
    else
        system.send(fd, bytes.ptr, bytes.len, 0);
    try check(rc);
    return @intCast(rc);
}

pub fn readAll(fd: fd_t, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = read(fd, buf[off..]) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return false, // WouldBlock: SO_RCVTIMEO expired
        };
        if (n == 0) return false;
        off += n;
    }
    return true;
}

pub fn writeAll(fd: fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        off += send(fd, bytes[off..]) catch |e| switch (e) {
            error.Interrupted => continue,
            else => return false,
        };
    }
    return true;
}

pub fn close(fd: fd_t) void {
    _ = system.close(fd);
}

/// Waits up to `timeout_ms` for `fd` to become readable (or hung up).
/// False on timeout.
pub fn waitReadable(fd: fd_t, timeout_ms: i32) Error!bool {
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const rc = system.poll(&pfd, 1, timeout_ms);
    try check(rc);
    return rc > 0;
}

/// Reads and writes give up after `seconds`.
pub fn setTimeouts(fd: fd_t, seconds: u32) void {
    var tv = std.mem.zeroes(posix.timeval);
    tv.sec = @intCast(seconds);
    _ = system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(posix.timeval));
    _ = system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(posix.timeval));
}

pub const Peer = struct {
    uid: u32,
    /// Linux only.
    pid: ?i32,
};

extern "c" fn getpeereid(fd: fd_t, uid: *posix.uid_t, gid: *posix.gid_t) c_int;

/// Who is at the other end of a Unix socket.
pub fn peer(fd: fd_t) ?Peer {
    if (is_linux) {
        const ucred = extern struct { pid: i32, uid: u32, gid: u32 };
        var cred: ucred = undefined;
        var len: posix.socklen_t = @sizeOf(ucred);
        const rc = system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.PEERCRED, std.mem.asBytes(&cred), &len);
        if (posix.errno(rc) != .SUCCESS or len != @sizeOf(ucred)) return null;
        return .{ .uid = cred.uid, .pid = cred.pid };
    }
    var uid: posix.uid_t = undefined;
    var gid: posix.gid_t = undefined;
    if (getpeereid(fd, &uid, &gid) != 0) return null;
    return .{ .uid = uid, .pid = null };
}

// ---------------------------------------------------------------- files

/// Opens (creating it, mode 0600) the daemon's lock file.
pub fn openLockFile(path: [*:0]const u8) Error!fd_t {
    const flags: posix.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const rc = if (is_linux) system.open(path, flags, 0o600) else system.open(path, flags, @as(c_uint, 0o600));
    try check(rc);
    return toFd(rc);
}

/// Takes an exclusive lock on `fd`, or fails with WouldBlock if another
/// open file holds it. Released when every descriptor for it is closed.
pub fn tryLock(fd: fd_t) Error!void {
    try check(system.flock(fd, posix.LOCK.EX | posix.LOCK.NB));
}

/// The 8 bytes at the start of `fd` as a little-endian integer (0 if short).
pub fn readStamp(fd: fd_t) i64 {
    var buf: [8]u8 = @splat(0);
    _ = system.pread(fd, &buf, buf.len, 0);
    return std.mem.readInt(i64, &buf, .little);
}

pub fn writeStamp(fd: fd_t, value: i64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, value, .little);
    _ = system.pwrite(fd, &buf, buf.len, 0);
}

pub fn unlink(path: [*:0]const u8) void {
    _ = system.unlink(path);
}

// ---------------------------------------------------------------- process

pub fn getpid() i32 {
    return @intCast(system.getpid());
}

pub fn getuid() u32 {
    return @intCast(system.getuid());
}

pub fn umask(mask: u32) void {
    if (is_linux) {
        _ = std.os.linux.syscall1(.umask, mask);
    } else {
        _ = system.umask(@intCast(mask));
    }
}

/// 0 in the child, the child's pid in the parent.
pub fn fork() Error!i32 {
    const rc = system.fork();
    try check(rc);
    return @intCast(rc);
}

/// For a detached daemon: a new session, stdio on /dev/null, `/` as the
/// working directory (so it keeps no mount point busy).
pub fn detachFromTerminal() void {
    _ = system.setsid();
    const flags: posix.O = .{ .ACCMODE = .RDWR };
    const rc = if (is_linux) system.open("/dev/null", flags, 0) else system.open("/dev/null", flags, @as(c_uint, 0));
    if (posix.errno(rc) == .SUCCESS) {
        const null_fd = toFd(rc);
        for (0..3) |fd| _ = system.dup2(null_fd, @intCast(fd));
        if (null_fd > 2) close(null_fd);
    }
}

pub fn chdirRoot() void {
    _ = system.chdir("/");
}

/// Ends the whole process at once. Async-signal-safe.
pub fn exit(code: u8) noreturn {
    if (is_linux) system.exit_group(code);
    std.c._exit(code);
}

/// Calls `handler` on SIGTERM, SIGINT and SIGHUP; ignores SIGPIPE.
pub fn onTerminate(comptime handler: fn () void) void {
    const S = struct {
        fn run(_: posix.SIG) callconv(.c) void {
            handler();
        }
    };
    var act: posix.Sigaction = .{ .handler = .{ .handler = S.run }, .mask = posix.sigemptyset(), .flags = 0 };
    for ([_]posix.SIG{ .TERM, .INT, .HUP }) |sig| _ = system.sigaction(sig, &act, null);
    act.handler = .{ .handler = posix.SIG.IGN };
    _ = system.sigaction(.PIPE, &act, null);
}

pub fn sleepMs(ms: u32) void {
    var ts: posix.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    _ = system.nanosleep(&ts, &ts);
}

/// macOS: raises the open file limit as far as allowed (kqueue needs one
/// descriptor per watched file) and returns it.
pub fn raiseFileLimit() u64 {
    var lim: posix.rlimit = undefined;
    if (system.getrlimit(.NOFILE, &lim) != 0) return 256;
    var want: u64 = lim.max;
    if (is_darwin) {
        // setrlimit refuses more than kern.maxfilesperproc.
        var per_proc: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (std.c.sysctlbyname("kern.maxfilesperproc", &per_proc, &len, null, 0) == 0 and per_proc > 0) {
            want = @min(want, @as(u64, @intCast(per_proc)));
        }
    }
    if (want > lim.cur) {
        const raised: posix.rlimit = .{ .cur = want, .max = lim.max };
        if (system.setrlimit(.NOFILE, &raised) == 0) return want;
    }
    return lim.cur;
}
