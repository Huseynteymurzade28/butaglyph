//! File system change notification for the daemon: inotify on Linux,
//! kqueue on macOS.
//!
//! Both queue an event before the system call that caused it returns. The
//! daemon reads the queue before every cache lookup, so a change made by a
//! command that has finished is always seen by the next prompt.
//!
//! The two differ in what they can see:
//! * inotify watches a directory and reports changes to its entries by
//!   name, including writes to the files in it. Directories are enough.
//! * kqueue watches one open file each (`EVFILT_VNODE`). On a directory it
//!   reports entries being added, removed or renamed, but not writes to
//!   the files in it, so files whose content matters must be watched one by
//!   one. It reports no names.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = @import("sys.zig");

pub const Event = struct {
    handle: i32,
    /// The entry of a watched directory that changed (inotify only); null
    /// when the watched file or directory itself changed, or when unknown.
    name: ?[]const u8 = null,
    /// Entries were added, removed or renamed, or the watched object itself
    /// was deleted or moved: the set of things to watch may have changed.
    structural: bool = false,
    /// The handle is gone (its directory was deleted or unmounted).
    gone: bool = false,
    /// Events were lost: assume everything changed.
    overflow: bool = false,
};

pub const Watcher = if (sys.is_linux) Inotify else if (sys.is_darwin) Kqueue else void;

pub const Inotify = struct {
    fd: i32,

    pub const watches_files = false;

    const linux = std.os.linux;
    const mask = linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CREATE | linux.IN.DELETE |
        linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
        linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW;

    pub fn init() sys.Error!Inotify {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        return .{ .fd = @intCast(rc) };
    }

    /// Watches the directory at `path`. Adding a directory that is already
    /// watched returns the same handle.
    pub fn add(w: *Inotify, path: [:0]const u8, is_dir: bool) sys.Error!i32 {
        std.debug.assert(is_dir);
        const rc = linux.inotify_add_watch(w.fd, path, mask);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOENT => error.NotFound,
            .NOTDIR => error.NotDir,
            .NOSPC => error.NoSpace, // fs.inotify.max_user_watches
            .ACCES => error.AccessDenied,
            else => error.Unexpected,
        };
    }

    pub fn remove(w: *Inotify, handle: i32) void {
        _ = linux.inotify_rm_watch(w.fd, handle);
    }

    /// Calls `onEvent(ctx, event)` for every queued event.
    pub fn drain(w: *Inotify, ctx: anytype, comptime onEvent: fn (@TypeOf(ctx), Event) void) void {
        var buf: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(w.fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return, // EAGAIN: the queue is empty
            }
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                off += @sizeOf(linux.inotify_event) + ev.len;
                if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
                    onEvent(ctx, .{ .handle = -1, .overflow = true });
                    continue;
                }
                onEvent(ctx, .{
                    .handle = ev.wd,
                    .name = ev.getName(),
                    .structural = ev.mask & (linux.IN.ISDIR | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0,
                    .gone = ev.mask & linux.IN.IGNORED != 0,
                });
            }
        }
    }
};

pub const Kqueue = struct {
    kq: i32,

    pub const watches_files = true;

    const c = std.c;
    const vnode_events = c.NOTE.DELETE | c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.ATTRIB |
        c.NOTE.LINK | c.NOTE.RENAME | c.NOTE.REVOKE;
    const replaced = c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE;

    pub fn init() sys.Error!Kqueue {
        const kq = c.kqueue();
        if (kq < 0) return error.Unexpected;
        _ = c.fcntl(kq, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        return .{ .kq = kq };
    }

    /// Opens `path` for events only (it doesn't keep a volume from being
    /// unmounted) and watches it. Every call returns a new handle.
    pub fn add(w: *Kqueue, path: [:0]const u8, is_dir: bool) sys.Error!i32 {
        const flags: posix.O = .{ .EVTONLY = true, .CLOEXEC = true, .NOFOLLOW = true, .DIRECTORY = is_dir };
        const fd = c.open(path, flags, @as(c_uint, 0));
        if (fd < 0) return switch (c.errno(fd)) {
            .NOENT, .LOOP => error.NotFound, // gone, or a symlink
            .NOTDIR => error.NotDir,
            .MFILE, .NFILE => error.TooManyFiles,
            .ACCES, .PERM => error.AccessDenied,
            else => error.Unexpected,
        };
        const change = [_]c.Kevent{.{
            .ident = @intCast(fd),
            .filter = c.EVFILT.VNODE,
            .flags = c.EV.ADD | c.EV.CLEAR,
            .fflags = vnode_events,
            .data = 0,
            .udata = @intFromBool(is_dir),
        }};
        var none: [0]c.Kevent = .{};
        if (c.kevent(w.kq, &change, 1, &none, 0, null) < 0) {
            _ = c.close(fd);
            return error.Unexpected;
        }
        return fd;
    }

    /// Closing the descriptor removes its event.
    pub fn remove(_: *Kqueue, handle: i32) void {
        _ = c.close(handle);
    }

    pub fn drain(w: *Kqueue, ctx: anytype, comptime onEvent: fn (@TypeOf(ctx), Event) void) void {
        var events: [64]c.Kevent = undefined;
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        while (true) {
            const n = c.kevent(w.kq, &events, 0, &events, events.len, &zero);
            if (n <= 0) return;
            for (events[0..@intCast(n)]) |ev| {
                const is_dir = ev.udata == 1;
                onEvent(ctx, .{
                    .handle = @intCast(ev.ident),
                    // On a directory, a write means its entries changed.
                    .structural = ev.fflags & replaced != 0 or (is_dir and ev.fflags & (c.NOTE.WRITE | c.NOTE.LINK) != 0),
                    .gone = ev.fflags & c.NOTE.REVOKE != 0,
                });
            }
            if (n < events.len) return;
        }
    }
};
