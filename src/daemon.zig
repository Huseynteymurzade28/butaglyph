//! `buta daemon`: computes repo-scoped modules (see `module.Scope`) for
//! `buta prompt` and caches the results until inotify reports a change in
//! the repository.
//!
//! Freshness. A cached result for a repository is served only if no
//! relevant inotify event arrived since it was computed. The kernel queues
//! an inotify event before the syscall that caused it returns, and the
//! daemon drains the queue before every lookup, so a change made by a
//! command that has finished is always seen by the next prompt.
//!
//! What is watched, per repository: the git dir (HEAD, index), the common
//! dir (config, packed-refs), every directory under refs/, and every work
//! tree directory that contains a tracked file. Untracked files are not
//! reported yet, so directories holding none (build output, node_modules)
//! are not watched and churn there costs nothing. The watch set is
//! rebuilt from the index whenever the index changes or a watched directory
//! is created, removed or moved.
//!
//! Threads. The main thread accepts connections; each connection is
//! handled on a pool thread. All shared state is behind one mutex, held
//! only for lookups and bookkeeping, never while computing. A computation
//! stuck in the kernel (a hung network mount) ties up one pool thread; the
//! clients waiting for it give up at their deadline.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const git = @import("git");
const module = @import("module.zig");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const Context = @import("context.zig").Context;

/// Repositories with cached results; the least recently used one is
/// dropped (with its watches) to make room.
const max_repos = 64;
/// A client that stalls mid-request is dropped after this long.
const client_timeout_s = 2;
/// Connections handled at once; more are refused (the client computes locally).
const max_connections = 64;

const watch_mask = linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CREATE | linux.IN.DELETE |
    linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW;

/// What a watched directory is to the repositories using it, which decides
/// which events matter. Later tags are more inclusive.
const Kind = enum(u2) {
    /// git dir or common dir: only the files in `git_files`.
    git,
    /// refs/ and below: everything except lock files.
    refs,
    /// a work tree directory: everything.
    work,
};

const git_files = [_][]const u8{ "HEAD", "index", "packed-refs", "config", "commondir", "refs" };

const Watch = struct {
    /// Bit i set: `repos[i]` uses this watch.
    repos: u64,
    kind: Kind,
};

const Entry = struct {
    id: module.Id,
    config: []u8,
    /// The repository's `gen` when the computation started.
    gen: u64,
    /// wire(Data), or null for "renders nothing".
    data: ?[]u8,
};

const Repo = struct {
    git_dir: []const u8,
    common_dir: []const u8,
    work_tree: []const u8,
    /// Bumped by every relevant inotify event.
    gen: u64 = 0,
    last_used: u64 = 0,
    /// Requests currently using this repository; it can't be evicted meanwhile.
    busy: u32 = 0,
    /// The watch set must be rebuilt before results can be cached again.
    needs_sync: bool = true,
    syncing: bool = false,
    /// The last sync put every watch in place.
    watched: bool = false,
    wds: std.ArrayList(i32) = .empty,
    entries: std.ArrayList(Entry) = .empty,
};

const State = struct {
    io: Io,
    gpa: Allocator,
    environ: std.process.Environ,
    debug: bool,
    inotify: i32,
    started: Io.Clock.Timestamp,

    mutex: Io.Mutex = .init,
    // Everything below is guarded by `mutex`.
    watches: std.AutoHashMapUnmanaged(i32, Watch) = .empty,
    repos: [max_repos]?*Repo = @splat(null),
    tick: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    fn lock(s: *State) void {
        s.mutex.lockUncancelable(s.io);
    }

    fn unlock(s: *State) void {
        s.mutex.unlock(s.io);
    }

    fn log(s: *State, comptime fmt: []const u8, args: anytype) void {
        if (s.debug) std.debug.print("buta daemon: " ++ fmt ++ "\n", args);
    }

    // ------------------------------------------------------------ inotify

    /// Applies every queued inotify event. Caller holds the lock.
    fn drain(s: *State) void {
        var buf: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(s.inotify, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return, // EAGAIN: the queue is empty
            }
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                s.event(ev.wd, ev.mask, ev.getName());
                off += @sizeOf(linux.inotify_event) + ev.len;
            }
        }
    }

    fn event(s: *State, wd: i32, mask: u32, name: ?[]const u8) void {
        if (mask & linux.IN.Q_OVERFLOW != 0) {
            s.log("inotify queue overflow: dropping every cached result", .{});
            return s.invalidate(std.math.maxInt(u64), true);
        }
        const w = s.watches.get(wd) orelse return;
        if (mask & linux.IN.IGNORED != 0) {
            // The directory is gone (or unmounted): rebuild the watch set.
            _ = s.watches.remove(wd);
            return s.invalidate(w.repos, true);
        }
        if (!relevant(w.kind, name)) return;
        const structural = mask & (linux.IN.ISDIR | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0 or
            (w.kind == .git and std.mem.eql(u8, name orelse "", "index"));
        s.invalidate(w.repos, structural);
    }

    fn invalidate(s: *State, repos: u64, resync: bool) void {
        for (&s.repos, 0..) |slot, i| if (slot) |r| if (repos & bit(i) != 0) {
            r.gen += 1;
            if (resync) r.needs_sync = true;
        };
    }

    // ------------------------------------------------------------ repositories

    /// The cache slot for `repo`, made (by evicting the least recently used
    /// idle one if needed) when it doesn't exist. Caller holds the lock.
    fn slotFor(s: *State, repo: git.Repo) ?usize {
        var free: ?usize = null;
        var lru: ?usize = null;
        for (s.repos, 0..) |slot, i| {
            const r = slot orelse {
                free = free orelse i;
                continue;
            };
            if (std.mem.eql(u8, r.git_dir, repo.git_dir) and std.mem.eql(u8, r.work_tree, repo.work_tree)) return i;
            if (r.busy == 0 and (lru == null or r.last_used < s.repos[lru.?].?.last_used)) lru = i;
        }
        const i = free orelse lru orelse return null;
        if (s.repos[i] != null) s.evict(i);
        const r = s.gpa.create(Repo) catch return null;
        const paths = std.mem.concat(s.gpa, u8, &.{ repo.git_dir, repo.common_dir, repo.work_tree }) catch {
            s.gpa.destroy(r);
            return null;
        };
        r.* = .{
            .git_dir = paths[0..repo.git_dir.len],
            .common_dir = paths[repo.git_dir.len..][0..repo.common_dir.len],
            .work_tree = paths[repo.git_dir.len + repo.common_dir.len ..],
        };
        s.repos[i] = r;
        s.log("tracking {s}", .{r.work_tree});
        return i;
    }

    fn evict(s: *State, i: usize) void {
        const r = s.repos[i].?;
        s.log("dropping {s}", .{r.work_tree});
        for (r.wds.items) |wd| s.release(wd, i);
        r.wds.deinit(s.gpa);
        for (r.entries.items) |e| s.freeEntry(e);
        r.entries.deinit(s.gpa);
        s.gpa.free(r.git_dir.ptr[0 .. r.git_dir.len + r.common_dir.len + r.work_tree.len]);
        s.gpa.destroy(r);
        s.repos[i] = null;
    }

    fn release(s: *State, wd: i32, i: usize) void {
        const w = s.watches.getPtr(wd) orelse return;
        w.repos &= ~bit(i);
        if (w.repos == 0) {
            _ = s.watches.remove(wd);
            _ = linux.inotify_rm_watch(s.inotify, wd);
        }
    }

    fn freeEntry(s: *State, e: Entry) void {
        s.gpa.free(e.config);
        if (e.data) |d| s.gpa.free(d);
    }

    fn lookup(r: *const Repo, id: module.Id, config: []const u8) ?*Entry {
        for (r.entries.items) |*e| {
            if (e.id == id and std.mem.eql(u8, e.config, config)) return e;
        }
        return null;
    }

    /// Caches a result computed from the repository as of `gen`, unless a
    /// newer one is already there. Caller holds the lock.
    fn store(s: *State, r: *Repo, id: module.Id, config: []const u8, gen: u64, data: ?[]const u8) void {
        const copy: ?[]u8 = if (data) |d| s.gpa.dupe(u8, d) catch return else null;
        if (lookup(r, id, config)) |e| {
            if (e.gen > gen) {
                if (copy) |c| s.gpa.free(c);
                return;
            }
            if (e.data) |old| s.gpa.free(old);
            e.data = copy;
            e.gen = gen;
            return;
        }
        const cfg = s.gpa.dupe(u8, config) catch {
            if (copy) |c| s.gpa.free(c);
            return;
        };
        r.entries.append(s.gpa, .{ .id = id, .config = cfg, .gen = gen, .data = copy }) catch {
            s.freeEntry(.{ .id = id, .config = cfg, .gen = gen, .data = copy });
        };
    }

    // ------------------------------------------------------------ watches

    /// Rebuilds the watch set of `repos[i]`. Called without the lock; the
    /// caller's `busy` reference keeps the slot alive. Returns whether
    /// every directory is now watched.
    fn sync(s: *State, i: usize, arena: Allocator) bool {
        const r = s.repos[i].?; // stable while busy
        var wds: std.ArrayList(i32) = .empty;
        var ok = true;

        // The git side first: once HEAD and the index are watched, a change
        // to them while the rest is set up still invalidates the result.
        var git_dirs: std.ArrayList(Dir) = .empty;
        appendDir(&git_dirs, arena, r.git_dir, .git) catch return false;
        appendDir(&git_dirs, arena, r.common_dir, .git) catch return false;
        const refs = std.fmt.allocPrint(arena, "{s}/refs", .{r.common_dir}) catch return false;
        collectTree(s.io, arena, refs, &git_dirs) catch return false;
        s.addWatches(i, git_dirs.items, &wds, arena, &ok) catch return false;

        var work_dirs: std.ArrayList(Dir) = .empty;
        collectTracked(s.io, arena, r, &work_dirs) catch |e| {
            s.log("{s}: cannot read the index: {s}", .{ r.work_tree, @errorName(e) });
            ok = false;
        };
        s.addWatches(i, work_dirs.items, &wds, arena, &ok) catch return false;

        // The same directory can be listed twice (git dir = common dir).
        std.mem.sortUnstable(i32, wds.items, {}, std.sort.asc(i32));
        var unique: usize = 0;
        for (wds.items) |wd| {
            if (unique > 0 and wds.items[unique - 1] == wd) continue;
            wds.items[unique] = wd;
            unique += 1;
        }
        wds.shrinkRetainingCapacity(unique);
        s.lock();
        defer s.unlock();
        for (r.wds.items) |old| {
            if (std.sort.binarySearch(i32, wds.items, old, orderI32) == null) s.release(old, i);
        }
        r.wds.clearRetainingCapacity();
        r.wds.appendSlice(s.gpa, wds.items) catch {
            // Can't remember the set, so can't release it later: give it up.
            for (wds.items) |wd| s.release(wd, i);
            ok = false;
        };
        s.log("{s}: watching {d} directories{s}", .{ r.work_tree, r.wds.items.len, if (ok) "" else " (incomplete)" });
        return ok;
    }

    fn addWatches(s: *State, i: usize, dirs: []const Dir, wds: *std.ArrayList(i32), arena: Allocator, ok: *bool) !void {
        try wds.ensureUnusedCapacity(arena, dirs.len);
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        s.lock();
        defer s.unlock();
        for (dirs) |d| {
            const path = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{d.path}, 0) catch {
                ok.* = false;
                continue;
            };
            const rc = linux.inotify_add_watch(s.inotify, path, watch_mask);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                // Gone since it was listed: its parent's watch reports that.
                .NOENT, .NOTDIR => continue,
                else => |e| {
                    // ENOSPC: fs.inotify.max_user_watches is exhausted.
                    if (ok.*) s.log("{s}: cannot watch: {s}", .{ d.path, @tagName(e) });
                    ok.* = false;
                    continue;
                },
            }
            const wd: i32 = @intCast(rc);
            const gop = s.watches.getOrPut(s.gpa, wd) catch {
                ok.* = false;
                continue;
            };
            if (gop.found_existing) {
                gop.value_ptr.repos |= bit(i);
                gop.value_ptr.kind = @enumFromInt(@max(@intFromEnum(gop.value_ptr.kind), @intFromEnum(d.kind)));
            } else {
                gop.value_ptr.* = .{ .repos = bit(i), .kind = d.kind };
            }
            wds.appendAssumeCapacity(wd);
        }
    }

    // ------------------------------------------------------------ requests

    fn handle(s: *State, fd: i32) void {
        defer _ = linux.close(fd);
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var header: [protocol.header_len]u8 = undefined;
        if (!readAll(fd, &header)) return;
        const len = protocol.parseHeader(&header) catch |e| {
            // FingerprintMismatch: the client is a different build of buta.
            s.log("rejecting a client: {s}", .{@errorName(e)});
            return;
        };
        const payload = arena.alloc(u8, len) catch return;
        if (!readAll(fd, payload)) return;
        const request = wire.decodeSlice(protocol.Request, payload, arena) catch |e| {
            s.log("bad request: {s}", .{@errorName(e)});
            return;
        };
        switch (request) {
            .prompt => |p| s.prompt(fd, p, arena),
            .status => sendStatus(fd, s.status(), arena),
            .stop => {
                const st = s.status();
                // Free the socket path and the lock before answering, so
                // that a daemon started right after `stop` returns can
                // take over.
                releaseSocket();
                sendStatus(fd, st, arena);
                linux.exit_group(0);
            },
        }
    }

    fn status(s: *State) protocol.Status {
        s.lock();
        defer s.unlock();
        var repos: u32 = 0;
        for (s.repos) |r| repos += @intFromBool(r != null);
        return .{
            .pid = linux.getpid(),
            .uptime_s = @intCast(@max(0, s.started.untilNow(s.io).raw.toSeconds())),
            .repos = repos,
            .watches = s.watches.count(),
            .hits = s.hits,
            .misses = s.misses,
        };
    }

    fn prompt(s: *State, fd: i32, p: protocol.Prompt, arena: Allocator) void {
        const repo = (if (std.fs.path.isAbsolute(p.cwd)) git.repo.discover(s.io, arena, p.cwd) catch null else null) orelse {
            for (p.modules) |m| sendFrame(fd, m.id, null, arena);
            return;
        };

        const answered = arena.alloc(bool, p.modules.len) catch return;
        @memset(answered, false);
        const hits = arena.alloc(?[]const u8, p.modules.len) catch return;
        var slot: ?usize = null;
        var gen: u64 = 0;
        var do_sync = false;
        var cacheable = false;
        {
            s.lock();
            defer s.unlock();
            s.drain();
            slot = s.slotFor(repo);
            if (slot) |i| {
                const r = s.repos[i].?;
                r.busy += 1;
                s.tick += 1;
                r.last_used = s.tick;
                gen = r.gen;
                if (r.needs_sync and !r.syncing) {
                    do_sync = true;
                    r.needs_sync = false;
                    r.syncing = true;
                }
                // Results computed now may be cached only if every watch is
                // already in place, or will be before this request computes.
                cacheable = do_sync or (r.watched and !r.syncing);
                if (cacheable and !do_sync) for (p.modules, answered, hits) |m, *done, *hit| {
                    const e = lookup(r, m.id, m.config) orelse continue;
                    if (e.gen != gen) continue;
                    // Replies are written after unlocking; copy the data out.
                    hit.* = if (e.data) |d| arena.dupe(u8, d) catch continue else null;
                    done.* = true;
                    s.hits += 1;
                };
            }
        }
        for (p.modules, answered, hits) |m, done, hit| if (done) sendFrame(fd, m.id, hit, arena);
        defer if (slot) |i| {
            s.lock();
            s.repos[i].?.busy -= 1;
            s.unlock();
        };

        if (std.mem.indexOfScalar(bool, answered, false) == null) return;
        if (do_sync) {
            const ok = s.sync(slot.?, arena);
            s.lock();
            const r = s.repos[slot.?].?;
            r.syncing = false;
            r.watched = ok;
            if (!ok) r.needs_sync = true; // try again next time
            cacheable = ok;
            s.unlock();
        }

        const ctx: Context = .{
            .io = s.io,
            .environ = s.environ,
            .cwd = p.cwd,
            .physical_cwd = p.cwd,
            .home = null,
            .debug = p.debug or s.debug,
        };
        for (p.modules, answered) |m, done| {
            if (done) continue;
            const result = computeEncoded(&ctx, m, arena);
            sendFrame(fd, m.id, switch (result) {
                .data => |d| d,
                .hidden, .failed => null,
            }, arena);
            s.lock();
            defer s.unlock();
            s.misses += 1;
            // Errors may be transient, so only real answers are cached.
            if (cacheable and result != .failed) {
                s.store(s.repos[slot.?].?, m.id, m.config, gen, switch (result) {
                    .data => |d| d,
                    else => null,
                });
            }
        }
    }
};

fn bit(i: usize) u64 {
    return @as(u64, 1) << @intCast(i);
}

fn orderI32(a: i32, b: i32) std.math.Order {
    return std.math.order(a, b);
}

fn relevant(kind: Kind, name: ?[]const u8) bool {
    const n = name orelse return true; // the watched directory itself
    return switch (kind) {
        .work => true,
        .refs => !std.mem.endsWith(u8, n, ".lock"),
        .git => for (git_files) |f| {
            if (std.mem.eql(u8, n, f)) break true;
        } else false,
    };
}

const Dir = struct { path: []const u8, kind: Kind };

fn appendDir(list: *std.ArrayList(Dir), arena: Allocator, path: []const u8, kind: Kind) !void {
    try list.append(arena, .{ .path = path, .kind = kind });
}

/// `root` and every directory below it, as `.refs`.
fn collectTree(io: Io, arena: Allocator, root: []const u8, out: *std.ArrayList(Dir)) !void {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => |x| return x,
    };
    defer dir.close(io);
    try appendDir(out, arena, root, .refs);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try collectTree(io, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.name }), out);
    }
}

/// The work tree root and every directory holding a tracked path.
fn collectTracked(io: Io, arena: Allocator, r: *const Repo, out: *std.ArrayList(Dir)) !void {
    try appendDir(out, arena, r.work_tree, .work);
    const path = try std.fmt.allocPrint(arena, "{s}/index", .{r.git_dir});
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return, // no index yet: nothing tracked
        else => |x| return x,
    };
    const index = try git.index.parse(arena, data);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (index.entries) |e| {
        // Every ancestor directory, so that removing a whole subtree is seen
        // in its parent too.
        var end = std.mem.lastIndexOfScalar(u8, e.path, '/') orelse continue;
        while (true) {
            const rel = e.path[0..end];
            const gop = try seen.getOrPut(arena, rel);
            if (gop.found_existing) break; // its ancestors are in already
            try appendDir(out, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ r.work_tree, rel }), .work);
            end = std.mem.lastIndexOfScalar(u8, rel, '/') orelse break;
        }
    }
}

const Computed = union(enum) { data: []const u8, hidden, failed };

fn computeEncoded(ctx: *const Context, m: protocol.ModuleRequest, arena: Allocator) Computed {
    switch (m.id) {
        inline else => |id| {
            const M = module.Impl(id);
            if (comptime module.scopeOf(M) != .repo) return .failed;
            const cfg = wire.decodeSlice(M.Config, m.config, arena) catch return .failed;
            const data = M.compute(ctx, &cfg, arena) catch |e| {
                if (ctx.debug) std.debug.print("buta daemon: module {s}: {s}\n", .{ @tagName(id), @errorName(e) });
                return .failed;
            } orelse return .hidden;
            var aw: Io.Writer.Allocating = .init(arena);
            wire.encode(M.Data, &data, &aw.writer) catch return .failed;
            return .{ .data = aw.written() };
        },
    }
}

fn sendFrame(fd: i32, id: module.Id, data: ?[]const u8, arena: Allocator) void {
    sendMessage(fd, protocol.Frame, &.{ .id = id, .data = data }, arena);
}

fn sendStatus(fd: i32, st: protocol.Status, arena: Allocator) void {
    sendMessage(fd, protocol.Status, &st, arena);
}

/// Writes `length: u32` and wire(value). A client that has gone away is
/// not an error: the result is still worth caching.
fn sendMessage(fd: i32, comptime T: type, value: *const T, arena: Allocator) void {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeInt(u32, 0, .little) catch return;
    wire.encode(T, value, &aw.writer) catch return;
    const bytes = aw.written();
    std.mem.writeInt(u32, bytes[0..4], @intCast(bytes.len - 4), .little);
    _ = writeAll(fd, bytes);
}

fn readAll(fd: i32, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf[off..].ptr, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) return false else {
                off += rc;
            },
            .INTR => {},
            else => return false, // EAGAIN: SO_RCVTIMEO expired
        }
    }
    return true;
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.sendto(fd, bytes[off..].ptr, bytes.len - off, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------- lifecycle

/// The socket path and the lock file descriptor, kept for `releaseSocket`.
var socket_path: [Io.net.UnixAddress.max_len:0]u8 = @splat(0);
var lock_fd: i32 = -1;

/// Removes the socket and drops the lock. Async-signal-safe.
fn releaseSocket() void {
    _ = linux.unlink(&socket_path);
    if (lock_fd >= 0) _ = linux.close(lock_fd);
}

fn onSignal(_: linux.SIG) callconv(.c) void {
    releaseSocket();
    linux.exit_group(0);
}

pub const Action = enum { run, stop, status };

pub const Options = struct {
    action: Action = .run,
    /// Fork into the background once the socket is ready.
    detach: bool = false,
};

const EnvLookup = struct {
    environ: std.process.Environ,
    pub fn get(e: EnvLookup, name: []const u8) ?[]const u8 {
        return e.environ.getPosix(name);
    }
};

pub fn main(environ: std.process.Environ, opts: Options, out: *Io.Writer, err: *Io.Writer) u8 {
    if (!protocol.supported) {
        err.writeAll("buta daemon: not supported on this platform\n") catch {};
        return 1;
    }
    const path = protocol.socketPath(&socket_path, EnvLookup{ .environ = environ }) orelse {
        err.writeAll(if (environ.getPosix("BUTA_SOCKET") orelse environ.getPosix("XDG_RUNTIME_DIR")) |p| if (p.len > 0)
            "buta daemon: the socket path is too long (at most 107 bytes) or relative\n"
        else
            "buta daemon: BUTA_SOCKET is empty, which disables the daemon\n" else "buta daemon: no socket path: set XDG_RUNTIME_DIR or BUTA_SOCKET\n") catch {};
        return 1;
    };
    return switch (opts.action) {
        .run => run(environ, path, opts.detach, err),
        .stop, .status => control(path, opts.action, out, err),
    };
}

fn control(path: [:0]const u8, action: Action, out: *Io.Writer, err: *Io.Writer) u8 {
    const fd = connectBlocking(path) orelse {
        if (action == .stop) return 0;
        out.writeAll("buta daemon: not running\n") catch {};
        return 3;
    };
    defer _ = linux.close(fd);
    setTimeouts(fd);
    var buf: [64 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const arena = fba.allocator();
    const request: protocol.Request = if (action == .stop) .stop else .status;
    var aw: Io.Writer.Allocating = .init(arena);
    wire.encode(protocol.Request, &request, &aw.writer) catch return 1;
    var header: [protocol.header_len]u8 = undefined;
    var hw: Io.Writer = .fixed(&header);
    protocol.writeHeader(&hw, aw.written().len) catch return 1;
    var len_buf: [4]u8 = undefined;
    const reply_ok = writeAll(fd, &header) and writeAll(fd, aw.written()) and readAll(fd, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    const st: ?protocol.Status = if (reply_ok and len <= 1024) blk: {
        const body = arena.alloc(u8, len) catch break :blk null;
        if (!readAll(fd, body)) break :blk null;
        break :blk wire.decodeSlice(protocol.Status, body, arena) catch null;
    } else null;
    const s = st orelse {
        err.writeAll("buta daemon: no answer (is it a different version of buta? stop it with `pkill -x buta`)\n") catch {};
        return 1;
    };
    switch (action) {
        .stop => out.print("buta daemon: stopped (pid {d})\n", .{s.pid}) catch {},
        else => out.print(
            \\buta daemon: running (pid {d}, up {d}s)
            \\  socket:  {s}
            \\  repos:   {d}
            \\  watches: {d}
            \\  hits:    {d}
            \\  misses:  {d}
            \\
        , .{ s.pid, s.uptime_s, path, s.repos, s.watches, s.hits, s.misses }) catch {},
    }
    return 0;
}

fn run(environ: std.process.Environ, path: [:0]const u8, detach: bool, err: *Io.Writer) u8 {
    // Only one daemon per socket: the lock is held for the daemon's life
    // (and passes to the child on --detach).
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrintSentinel(&lock_buf, "{s}.lock", .{path}, 0) catch return 1;
    _ = linux.syscall1(.umask, 0o077);
    const lock_rc = linux.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(lock_rc) != .SUCCESS) {
        err.print("buta daemon: {s}: {s}\n", .{ lock_path, @tagName(linux.errno(lock_rc)) }) catch {};
        return 1;
    }
    if (linux.errno(linux.flock(@intCast(lock_rc), std.posix.LOCK.EX | std.posix.LOCK.NB)) != .SUCCESS) {
        err.print("buta daemon: already running ({s})\n", .{path}) catch {};
        return 1;
    }
    lock_fd = @intCast(lock_rc);

    // Holding the lock, any socket file left behind is stale.
    _ = linux.unlink(path);
    const listen_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(listen_rc) != .SUCCESS) return fail(err, "socket", linux.errno(listen_rc));
    const listen_fd: i32 = @intCast(listen_rc);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    const bind_rc = linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
    if (linux.errno(bind_rc) != .SUCCESS) return fail(err, path, linux.errno(bind_rc));
    if (linux.errno(linux.listen(listen_fd, 128)) != .SUCCESS) return fail(err, "listen", .INVAL);

    const inotify_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(inotify_rc) != .SUCCESS) return fail(err, "inotify_init1", linux.errno(inotify_rc));

    const debug = if (environ.getPosix("BUTA_DEBUG")) |v| v.len > 0 else false;
    if (detach) {
        // Fork before any thread exists. The parent returns once the child
        // owns the socket; the child leaves the terminal's session.
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return fail(err, "fork", linux.errno(pid));
        if (pid != 0) return 0;
        _ = linux.setsid();
        const null_rc = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(null_rc) == .SUCCESS) {
            for (0..3) |fd| _ = linux.dup2(@intCast(null_rc), @intCast(fd));
            if (null_rc > 2) _ = linux.close(@intCast(null_rc));
        }
    }
    _ = linux.chdir("/"); // don't keep a mount point busy

    var act: linux.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = linux.sigaction(sig, &act, null);
    act.handler = .{ .handler = linux.SIG.IGN };
    _ = linux.sigaction(.PIPE, &act, null);

    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{
        .stack_size = 1024 * 1024,
        .concurrent_limit = .limited(max_connections * 2),
    });
    const io = threaded.io();
    var state: State = .{
        .io = io,
        .gpa = std.heap.smp_allocator,
        .environ = environ,
        .debug = debug,
        .inotify = @intCast(inotify_rc),
        .started = Io.Clock.Timestamp.now(io, .awake),
    };
    if (!detach) err.print("buta daemon: listening on {s}\n", .{path}) catch {};
    err.flush() catch {};
    serve(&state, listen_fd);
}

fn fail(err: *Io.Writer, what: []const u8, e: linux.E) u8 {
    err.print("buta daemon: {s}: {s}\n", .{ what, @tagName(e) }) catch {};
    return 1;
}

fn serve(s: *State, listen_fd: i32) noreturn {
    // Never awaited: connection tasks free themselves when they finish.
    var group: Io.Group = .init;
    var active: std.atomic.Value(u32) = .init(0);
    const uid = linux.getuid();
    var ns_buf: [64]u8 = undefined;
    const own_ns = mountNamespace(&ns_buf, linux.getpid()) orelse "";
    while (true) {
        const rc = linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .CONNABORTED => continue,
            else => |e| {
                // Out of file descriptors or memory: back off instead of spinning.
                s.log("accept: {s}", .{@tagName(e)});
                var ts: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
                continue;
            },
        }
        const fd: i32 = @intCast(rc);
        const peer = peerCred(fd);
        // Only the user who runs the daemon may ask it about their files,
        // and only from where paths mean the same files (a client in a
        // container computes locally).
        if (peer == null or peer.?.uid != uid or !sameMountNamespace(peer.?.pid, own_ns)) {
            _ = linux.close(fd);
            continue;
        }
        setTimeouts(fd);
        if (active.fetchAdd(1, .monotonic) >= max_connections) {
            _ = active.fetchSub(1, .monotonic);
            _ = linux.close(fd); // the client computes locally
            continue;
        }
        group.concurrent(s.io, handleTask, .{ s, fd, &active }) catch {
            _ = active.fetchSub(1, .monotonic);
            _ = linux.close(fd);
        };
    }
}

fn handleTask(s: *State, fd: i32, active: *std.atomic.Value(u32)) void {
    defer _ = active.fetchSub(1, .monotonic);
    s.handle(fd);
}

const ucred = extern struct { pid: i32, uid: u32, gid: u32 };

fn peerCred(fd: i32) ?ucred {
    var cred: ucred = undefined;
    var len: linux.socklen_t = @sizeOf(ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &len);
    if (linux.errno(rc) != .SUCCESS or len != @sizeOf(ucred)) return null;
    return cred;
}

/// "mnt:[4026531841]" for `pid`, or null if it can't be read (for example
/// when the peer is in a pid namespace we can't see into).
fn mountNamespace(buf: []u8, pid: i32) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/ns/mnt", .{pid}, 0) catch return null;
    const rc = linux.readlink(path, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    return buf[0..rc];
}

fn sameMountNamespace(pid: i32, own: []const u8) bool {
    var buf: [64]u8 = undefined;
    const ns = mountNamespace(&buf, pid) orelse return false;
    return own.len > 0 and std.mem.eql(u8, ns, own);
}

fn setTimeouts(fd: i32) void {
    const tv: linux.timeval = .{ .sec = client_timeout_s, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
}

fn connectBlocking(path: [:0]const u8) ?i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

test relevant {
    try std.testing.expect(relevant(.work, "main.zig"));
    try std.testing.expect(relevant(.work, null));
    try std.testing.expect(relevant(.git, "index"));
    try std.testing.expect(relevant(.git, "HEAD"));
    try std.testing.expect(!relevant(.git, "index.lock"));
    try std.testing.expect(!relevant(.git, "FETCH_HEAD"));
    try std.testing.expect(!relevant(.git, "objects"));
    try std.testing.expect(relevant(.refs, "main"));
    try std.testing.expect(!relevant(.refs, "main.lock"));
}
