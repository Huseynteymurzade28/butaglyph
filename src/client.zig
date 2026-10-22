//! The prompt side of the daemon protocol (see src/protocol.zig).
//!
//! Everything here is best effort and bounded by the module deadlines: no
//! daemon, a refused or failed connection, or a daemon built from other
//! sources all mean "compute locally", and a daemon that is merely slow
//! costs at most the deadline, like a slow module would.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const module = @import("module.zig");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const Context = @import("context.zig").Context;
const Config = @import("config.zig").Config;

const Id = module.Id;

pub const Conn = struct {
    fd: i32 = -1,
    /// Modules the daemon was asked for and has not answered yet. After
    /// `collect`, the ones still set must be computed locally.
    pending: [module.id_count]bool = @splat(false),
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,

    /// Connects to the daemon and asks for every repo-scoped module in
    /// `cfg.order`. Returns false (and asks for nothing) when there is no
    /// daemon to ask.
    pub fn open(c: *Conn, ctx: *const Context, cfg: *const Config) bool {
        if (!protocol.supported) return false; // keeps the rest out of other builds
        if (cfg.daemon == .off) return false;
        var wanted = false;
        inline for (module.ids) |id| {
            if (module.scopeOf(module.Impl(id)) == .repo and module.inOrder(cfg, id)) wanted = true;
        }
        if (!wanted) return false;

        var path_buf: [Io.net.UnixAddress.max_len]u8 = undefined;
        const path = protocol.socketPath(&path_buf, ctx.env) orelse return false;
        const fd = sys.socket(true) catch return false;
        // A Unix socket connects at once or not at all: WouldBlock means
        // the daemon's backlog is full, which counts as "no daemon".
        sys.connect(fd, path) catch |e| {
            sys.close(fd);
            // No socket, or one left behind by a daemon that died.
            if (cfg.daemon == .auto and (e == error.NotFound or e == error.Refused)) autostart(ctx, path);
            return false;
        };
        c.fd = fd;
        if (c.send(ctx, cfg)) return true;
        c.close();
        c.pending = @splat(false);
        return false;
    }

    fn send(c: *Conn, ctx: *const Context, cfg: *const Config) bool {
        var mem: [16 * 1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&mem);
        const arena = fba.allocator();

        var requests: [module.id_count]protocol.ModuleRequest = undefined;
        var n: usize = 0;
        inline for (module.ids) |id| {
            if (module.scopeOf(module.Impl(id)) == .repo and module.inOrder(cfg, id)) {
                var aw: Io.Writer.Allocating = .init(arena);
                wire.encode(module.Impl(id).Config, module.configFor(id, cfg), &aw.writer) catch return false;
                requests[n] = .{ .id = id, .config = aw.written() };
                n += 1;
                c.pending[@backingInt(id)] = true;
            }
        }
        const request: protocol.Request = .{ .prompt = .{
            .cwd = ctx.physical_cwd,
            .debug = ctx.debug,
            .modules = requests[0..n],
        } };
        var payload: Io.Writer.Allocating = .init(arena);
        wire.encode(protocol.Request, &request, &payload.writer) catch return false;

        var header: [protocol.header_len]u8 = undefined;
        var hw: Io.Writer = .fixed(&header);
        protocol.writeHeader(&hw, payload.written().len) catch return false;
        // A local socket's buffer holds far more than a request, so a write
        // that does not complete at once means something is wrong.
        return sys.writeAll(c.fd, &header) and sys.writeAll(c.fd, payload.written());
    }

    /// Reads frames until every pending module is answered, has missed its
    /// deadline (its slot stays null), or the daemon hangs up (it stays
    /// pending, for the caller to compute locally).
    pub fn collect(c: *Conn, ctx: *const Context, cfg: *const Config, start: Io.Clock.Timestamp, rt: *module.Runtime, slots: *module.Slots) void {
        if (!protocol.supported) return; // never opened
        defer c.close();
        while (true) {
            while (true) {
                // A malformed frame: trust nothing else from this daemon.
                const next = c.peekFrame() catch return orelse break;
                c.accept(next.frame, ctx, cfg, start, rt, slots);
                c.consume(next.size);
            }
            // Drop modules whose deadline has passed and find the nearest one left.
            var wait_ms: ?i64 = null;
            inline for (module.ids) |id| {
                if (module.Impl(id).cost == .expensive and c.pending[@backingInt(id)]) {
                    const left = module.deadlineFor(id, cfg, start).durationFromNow(ctx.io).raw.toMilliseconds();
                    if (left <= 0) {
                        c.pending[@backingInt(id)] = false;
                        if (ctx.debug) std.debug.print("buta: module {s}: daemon missed the {d} ms deadline\n", .{ @tagName(id), module.timeoutFor(id, cfg) });
                    } else wait_ms = @min(wait_ms orelse left, left);
                }
            }
            const timeout = wait_ms orelse return; // nothing left to wait for
            if (!c.fill(@intCast(@min(timeout, std.math.maxInt(i32))))) return;
        }
    }

    fn accept(c: *Conn, frame: protocol.Frame, ctx: *const Context, cfg: *const Config, start: Io.Clock.Timestamp, rt: *module.Runtime, slots: *module.Slots) void {
        switch (frame.id) {
            inline else => |id| {
                if (comptime module.scopeOf(module.Impl(id)) != .repo) return;
                const i = @backingInt(id);
                if (!c.pending[i]) return;
                c.pending[i] = false;
                // A frame that arrives after the deadline is dropped, exactly
                // like a local task that finishes late.
                if (module.deadlineFor(id, cfg, start).durationFromNow(ctx.io).raw.nanoseconds <= 0) return;
                const bytes = frame.data orelse return;
                var fba: std.heap.FixedBufferAllocator = .init(&rt.heaps[i]);
                const data = wire.decodeSlice(module.Impl(id).Data, bytes, fba.allocator()) catch |e| {
                    if (ctx.debug) std.debug.print("buta: module {s}: bad daemon reply: {s}\n", .{ @tagName(id), @errorName(e) });
                    return;
                };
                slots[i] = @unionInit(module.Data, @tagName(id), data);
            },
        }
    }

    /// The first complete frame in `buf` and its size on the wire, or null
    /// if there is none yet. The frame points into `buf`: `consume` it after use.
    fn peekFrame(c: *Conn) error{BadFrame}!?struct { frame: protocol.Frame, size: usize } {
        if (c.len < 4) return null;
        const n = std.mem.readInt(u32, c.buf[0..4], .little);
        if (n > c.buf.len - 4) return error.BadFrame;
        if (c.len < 4 + n) return null;
        var r: Io.Reader = .fixed(c.buf[4..][0..n]);
        var no_memory: std.heap.FixedBufferAllocator = .init(&.{}); // decoding an enum allocates nothing
        const id = wire.decode(Id, &r, no_memory.allocator()) catch return error.BadFrame;
        // wire(?[]const u8), read in place rather than copied out.
        const has_data = r.takeByte() catch return error.BadFrame;
        const data: ?[]const u8 = switch (has_data) {
            0 => null,
            1 => blk: {
                const len = r.takeInt(u32, .little) catch return error.BadFrame;
                break :blk r.take(len) catch return error.BadFrame;
            },
            else => return error.BadFrame,
        };
        if (r.bufferedLen() != 0) return error.BadFrame;
        return .{ .frame = .{ .id = id, .data = data }, .size = 4 + n };
    }

    fn consume(c: *Conn, size: usize) void {
        std.mem.copyForwards(u8, &c.buf, c.buf[size..c.len]);
        c.len -= size;
    }

    /// Waits up to `timeout_ms` for more bytes. False on hang-up or error.
    fn fill(c: *Conn, timeout_ms: i32) bool {
        if (c.len == c.buf.len) return false;
        const ready = sys.waitReadable(c.fd, timeout_ms) catch |e| return e == error.Interrupted;
        if (!ready) return true; // timed out: the caller re-checks deadlines
        const got = sys.read(c.fd, c.buf[c.len..]) catch |e| return e == error.Interrupted or e == error.WouldBlock;
        if (got == 0) return false; // hang-up
        c.len += got;
        return true;
    }

    fn close(c: *Conn) void {
        if (c.fd >= 0) sys.close(c.fd);
        c.fd = -1;
    }
};

/// A daemon that can't start (no inotify, say) is tried again after this
/// long, so it costs one process spawn per interval rather than per prompt.
const autostart_interval_s = 30;

/// Starts `buta daemon --detach` and returns without waiting for it: this
/// prompt is computed locally, the next one asks the daemon.
///
/// The daemon's lock file decides: if someone holds it, a daemon is running
/// or starting (perhaps another build, still serving older shells). If not,
/// the time of this attempt is written into it, and nobody tries again
/// before the interval is over.
fn autostart(ctx: *const Context, socket_path: []const u8) void {
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrintSentinel(&lock_buf, "{s}.lock", .{socket_path}, 0) catch return;
    sys.umask(0o077);
    const fd = sys.openLockFile(lock_path) catch return;
    {
        // Unlocked before spawning: the daemon takes this lock itself.
        defer sys.close(fd);
        sys.tryLock(fd) catch return;
        const now = Io.Clock.real.now(ctx.io).toSeconds();
        const last = sys.readStamp(fd);
        if (now >= last and now - last < autostart_interval_s) return;
        sys.writeStamp(fd, now);
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(ctx.io, &exe_buf) catch return;
    const child = std.process.spawn(ctx.io, .{
        .argv = &.{ exe_buf[0..n], "daemon", "--detach" },
        .stdin = .ignore,
        .stdout = .ignore, // never hold the shell's command substitution open
        .stderr = .ignore,
    }) catch return;
    // Not waited for: `--detach` returns once the daemon listens, and
    // whatever remains of the child is reaped when this process exits.
    _ = child;
    if (ctx.debug) std.debug.print("buta: started the daemon\n", .{});
}
