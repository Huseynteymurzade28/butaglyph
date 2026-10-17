//! `buta daemon`: computes repo-scoped modules (see `module.Scope`) for
//! `buta prompt` and caches the results until the file system reports a
//! change in the repository (inotify on Linux, kqueue on macOS; see
//! src/watch.zig).
//!
//! Freshness. A cached result for a repository is served only if no
//! relevant event arrived since it was computed. The kernel queues an event
//! before the syscall that caused it returns, and the daemon drains the
//! queue before every lookup, so a change made by a command that has
//! finished is always seen by the next prompt.
//!
//! What is watched, per repository: the git dir (HEAD, index), the common
//! dir (config, packed-refs, info/exclude), every directory under refs/,
//! the user's global git config and excludes files, every work tree
//! directory that holds a tracked file, and every other one that is not
//! ignored (untracked files count). Ignored directories (build output,
//! node_modules) are not watched, so churn there costs nothing. With
//! kqueue, which doesn't see writes to the files in a watched directory,
//! every tracked file and .gitignore is watched too. The watch set is
//! rebuilt whenever the index or an ignore rule changes, or a watched
//! directory gains, loses or renames an entry that is a directory.
//!
//! Threads. The main thread accepts connections; each connection is
//! handled on a pool thread. All shared state is behind one mutex, held
//! only for lookups and bookkeeping, never while computing. A computation
//! stuck in the kernel (a hung network mount) ties up one pool thread; the
//! clients waiting for it give up at their deadline.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const git = @import("git");
const module = @import("module.zig");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const sys = @import("sys.zig");
const watch = @import("watch.zig");
const context = @import("context.zig");
const Context = context.Context;
const Env = @import("env.zig").Env;
const git_status = @import("modules/git_status.zig");

/// Repositories with cached results; the least recently used one is
/// dropped (with its watches) to make room.
const max_repos = 64;
/// A client that stalls mid-request is dropped after this long.
const client_timeout_s = 2;
/// Connections handled at once; more are refused (the client computes locally).
const max_connections = 64;
/// kqueue: file descriptors kept free for connections and computing.
const reserved_fds = 256;

/// What a watched directory or file is to the repositories using it, which
/// decides which events matter. For directories (which inotify may share
/// between repositories) later tags are more inclusive.
const Kind = enum(u3) {
    /// git dir, common dir, info/: only the files in `git_files`.
    git,
    /// a directory holding a global git file: only those (`global_names`).
    global,
    /// refs/ and below: everything except lock files.
    refs,
    /// a work tree directory: everything.
    work,
    /// kqueue: a tracked file.
    file,
    /// kqueue: a file that decides what is watched (the index, HEAD, a
    /// .gitignore, a global git file): any change rebuilds the watch set.
    rules,
};

const git_files = [_][]const u8{ "HEAD", "index", "packed-refs", "config", "commondir", "refs", "info", "exclude" };

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
    /// Bumped by every relevant file system event.
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
    env: Env,
    home: ?[]const u8,
    debug: bool,
    watcher: watch.Watcher,
    /// kqueue: handles allowed before a repository is left unwatched.
    max_watches: u64,
    started: Io.Clock.Timestamp,
    exe: ?ExeId,

    mutex: Io.Mutex = .init,
    // Everything below is guarded by `mutex`.
    watches: std.AutoHashMapUnmanaged(i32, Watch) = .empty,
    repos: [max_repos]?*Repo = @splat(null),
    /// Base names of the global git files (inotify watches their directories).
    global_names: std.ArrayList([]const u8) = .empty,
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

    // ------------------------------------------------------------ events

    /// Applies every queued event. Caller holds the lock.
    fn drain(s: *State) void {
        s.watcher.drain(s, onEvent);
    }

    fn onEvent(s: *State, ev: watch.Event) void {
        if (ev.overflow) {
            s.log("event queue overflow: dropping every cached result", .{});
            return s.invalidate(std.math.maxInt(u64), true);
        }
        const w = s.watches.get(ev.handle) orelse return;
        if (ev.gone) {
            // The directory is gone (or unmounted): rebuild the watch set.
            _ = s.watches.remove(ev.handle);
            s.watcher.remove(ev.handle);
            return s.invalidate(w.repos, true);
        }
        if (!s.relevant(w.kind, ev.name)) return;
        s.invalidate(w.repos, ev.structural or s.rebuildsWatches(w.kind, ev.name));
    }

    fn relevant(s: *const State, kind: Kind, name: ?[]const u8) bool {
        const n = name orelse return true; // the watched directory or file itself
        return switch (kind) {
            .work, .file, .rules => true,
            .refs => !std.mem.endsWith(u8, n, ".lock"),
            .git => inList(&git_files, n),
            .global => inList(s.global_names.items, n),
        };
    }

    /// A change that can alter what must be watched.
    fn rebuildsWatches(s: *const State, kind: Kind, name: ?[]const u8) bool {
        if (kind == .rules) return true;
        const n = name orelse return false;
        return switch (kind) {
            .git => std.mem.eql(u8, n, "index") or std.mem.eql(u8, n, "exclude"),
            .global => inList(s.global_names.items, n),
            .work => std.mem.eql(u8, n, ".gitignore"),
            else => false,
        };
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
            s.watcher.remove(wd);
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
    /// everything is now watched.
    fn sync(s: *State, i: usize, arena: Allocator) bool {
        const r = s.repos[i].?; // stable while busy
        const files = watch.Watcher.watches_files;
        var wds: std.ArrayList(i32) = .empty;
        var ok = true;
        const repo: git.Repo = .{ .git_dir = r.git_dir, .common_dir = r.common_dir, .work_tree = r.work_tree };
        const global = git_status.globalFiles(&s.context(r.work_tree));

        // The git side first: once HEAD and the index are watched, a change
        // to them while the rest is set up still invalidates the result.
        var git_side: std.ArrayList(Target) = .empty;
        const info = std.fmt.allocPrint(arena, "{s}/info", .{r.common_dir}) catch return false;
        for ([_][]const u8{ r.git_dir, r.common_dir, info }) |d| add(&git_side, arena, d, .git, true) catch return false;
        if (files) {
            for ([_][2][]const u8{ .{ r.git_dir, "HEAD" }, .{ r.git_dir, "index" }, .{ r.common_dir, "config" }, .{ r.common_dir, "packed-refs" }, .{ info, "exclude" } }) |f| {
                const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ f[0], f[1] }) catch return false;
                add(&git_side, arena, path, .rules, false) catch return false;
            }
        }
        const refs = std.fmt.allocPrint(arena, "{s}/refs", .{r.common_dir}) catch return false;
        collectTree(s.io, arena, refs, &git_side) catch return false;
        // Global config and excludes: their directories (inotify filters
        // events by name; kqueue reports none, so any change of entries
        // there rebuilds the watch set) and, for kqueue, the files.
        const external = git.status.externalFiles(s.io, arena, repo, global) catch &.{};
        for (external) |path| {
            // kqueue: the file itself (if it exists) for writes, and below
            // the nearest directory for its creation, removal or renaming.
            if (files) add(&git_side, arena, path, .rules, false) catch return false;
            // The nearest directory that exists, for the name that would
            // lead to the file (`~/.config` for a missing ~/.config/git/ignore).
            var name = std.fs.path.basename(path);
            var dir = std.fs.path.dirname(path) orelse continue;
            while (!isDir(s.io, dir)) {
                name = std.fs.path.basename(dir);
                dir = std.fs.path.dirname(dir) orelse break;
            }
            add(&git_side, arena, dir, .global, true) catch return false;
            s.addGlobalName(name);
        }
        s.addWatches(i, git_side.items, &wds, arena, &ok) catch return false;

        var work_side: std.ArrayList(Target) = .empty;
        if (git.status.watchList(s.io, arena, repo, global, files)) |list| {
            for (list.dirs) |d| add(&work_side, arena, d, .work, true) catch return false;
            for (list.files) |f| add(&work_side, arena, f, .file, false) catch return false;
            if (files) for (list.ignore_files) |f| add(&work_side, arena, f, .rules, false) catch return false;
        } else |e| {
            s.log("{s}: cannot list what to watch: {s}", .{ r.work_tree, @errorName(e) });
            ok = false;
            add(&work_side, arena, r.work_tree, .work, true) catch return false;
        }
        s.addWatches(i, work_side.items, &wds, arena, &ok) catch return false;

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
        s.log("{s}: watching {d} {s}{s}", .{ r.work_tree, r.wds.items.len, if (files) "files and directories" else "directories", if (ok) "" else " (incomplete)" });
        return ok;
    }

    fn addGlobalName(s: *State, name: []const u8) void {
        s.lock();
        defer s.unlock();
        if (inList(s.global_names.items, name)) return;
        const copy = s.gpa.dupe(u8, name) catch return;
        s.global_names.append(s.gpa, copy) catch s.gpa.free(copy);
    }

    fn addWatches(s: *State, i: usize, targets: []const Target, wds: *std.ArrayList(i32), arena: Allocator, ok: *bool) !void {
        try wds.ensureUnusedCapacity(arena, targets.len);
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        s.lock();
        defer s.unlock();
        for (targets) |t| {
            if (watch.Watcher.watches_files and s.watches.count() >= s.max_watches) {
                if (ok.*) s.log("{s}: out of file descriptors for watches", .{t.path});
                ok.* = false;
                return;
            }
            const path = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{t.path}, 0) catch {
                ok.* = false;
                continue;
            };
            const wd = s.watcher.add(path, t.is_dir) catch |e| switch (e) {
                // Gone since it was listed (or never there): a watched
                // directory reports its arrival.
                error.NotFound, error.NotDir => continue,
                else => {
                    // NoSpace: fs.inotify.max_user_watches is exhausted.
                    if (ok.*) s.log("{s}: cannot watch: {s}", .{ t.path, @errorName(e) });
                    ok.* = false;
                    continue;
                },
            };
            const gop = s.watches.getOrPut(s.gpa, wd) catch {
                s.watcher.remove(wd);
                ok.* = false;
                continue;
            };
            if (gop.found_existing) {
                gop.value_ptr.repos |= bit(i);
                gop.value_ptr.kind = @enumFromInt(@max(@intFromEnum(gop.value_ptr.kind), @intFromEnum(t.kind)));
            } else {
                gop.value_ptr.* = .{ .repos = bit(i), .kind = t.kind };
            }
            wds.appendAssumeCapacity(wd);
        }
    }

    /// The Context modules are computed with: the request's directory, and
    /// the daemon's own environment.
    fn context(s: *const State, cwd: []const u8) Context {
        return .{
            .io = s.io,
            .env = s.env,
            .cwd = cwd,
            .physical_cwd = cwd,
            .home = s.home,
            .debug = s.debug,
        };
    }

    // ------------------------------------------------------------ requests

    fn handle(s: *State, fd: i32) void {
        defer sys.close(fd);
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var header: [protocol.header_len]u8 = undefined;
        if (!sys.readAll(fd, &header)) return;
        const len = protocol.parseHeader(&header) catch |e| {
            // FingerprintMismatch: the client is a different build of buta.
            s.log("rejecting a client: {s}", .{@errorName(e)});
            if (e == error.FingerprintMismatch and replacedExe(s.io, s.exe)) {
                // buta was upgraded: make way, so that the new build's
                // prompt can start its own daemon.
                s.log("{s} was replaced: exiting", .{s.exe.?.path});
                releaseSocket();
                sys.exit(0);
            }
            return;
        };
        const payload = arena.alloc(u8, len) catch return;
        if (!sys.readAll(fd, payload)) return;
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
                sys.exit(0);
            },
        }
    }

    fn status(s: *State) protocol.Status {
        s.lock();
        defer s.unlock();
        var repos: u32 = 0;
        for (s.repos) |r| repos += @intFromBool(r != null);
        return .{
            .pid = sys.getpid(),
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

        var ctx = s.context(p.cwd);
        ctx.debug = p.debug or s.debug;
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

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Something to watch.
const Target = struct { path: []const u8, kind: Kind, is_dir: bool };

fn add(list: *std.ArrayList(Target), arena: Allocator, path: []const u8, kind: Kind, is_dir: bool) !void {
    try list.append(arena, .{ .path = path, .kind = kind, .is_dir = is_dir });
}

/// `root` and every directory below it, as `.refs`.
fn collectTree(io: Io, arena: Allocator, root: []const u8, out: *std.ArrayList(Target)) !void {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => |x| return x,
    };
    defer dir.close(io);
    try add(out, arena, root, .refs, true);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try collectTree(io, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.name }), out);
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
    _ = sys.writeAll(fd, bytes);
}

// ---------------------------------------------------------------- lifecycle

/// The socket path and the lock file descriptor, kept for `releaseSocket`.
var socket_path: [Io.net.UnixAddress.max_len:0]u8 = @splat(0);
var lock_fd: i32 = -1;

/// Removes the socket and drops the lock. Async-signal-safe.
fn releaseSocket() void {
    sys.unlink(&socket_path);
    if (lock_fd >= 0) sys.close(lock_fd);
}

fn onSignal() void {
    releaseSocket();
    sys.exit(0);
}

/// Identifies the executable the daemon runs from, to notice an upgrade.
const ExeId = struct {
    path: []const u8,
    inode: Io.File.INode,
    size: u64,
    mtime: i96,

    fn of(io: Io, path: []const u8) ?ExeId {
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return .{ .path = path, .inode = st.inode, .size = st.size, .mtime = st.mtime.nanoseconds };
    }
};

/// The file the daemon was started from is gone or is another file now.
fn replacedExe(io: Io, exe: ?ExeId) bool {
    const old = exe orelse return false;
    const now = ExeId.of(io, old.path) orelse return true;
    return now.inode != old.inode or now.size != old.size or now.mtime != old.mtime;
}

pub const Action = enum { run, stop, status };

pub const Options = struct {
    action: Action = .run,
    /// Fork into the background once the socket is ready.
    detach: bool = false,
};

pub fn main(io: Io, env: Env, opts: Options, out: *Io.Writer, err: *Io.Writer) u8 {
    if (!protocol.supported) {
        err.writeAll("buta daemon: not supported on this platform\n") catch {};
        return 1;
    }
    const path = protocol.socketPath(&socket_path, env) orelse {
        err.writeAll(if (env.get("BUTA_SOCKET") orelse env.get("XDG_RUNTIME_DIR") orelse env.get("TMPDIR")) |p| if (p.len > 0)
            "buta daemon: the socket path is too long or relative\n"
        else
            "buta daemon: BUTA_SOCKET is empty, which disables the daemon\n" else "buta daemon: no socket path: set XDG_RUNTIME_DIR or BUTA_SOCKET\n") catch {};
        return 1;
    };
    return switch (opts.action) {
        .run => run(io, env, path, opts.detach, err),
        .stop, .status => control(path, opts.action, out, err),
    };
}

fn control(path: [:0]const u8, action: Action, out: *Io.Writer, err: *Io.Writer) u8 {
    const fd = connectBlocking(path) orelse {
        if (action == .stop) return 0;
        out.writeAll("buta daemon: not running\n") catch {};
        return 3;
    };
    defer sys.close(fd);
    sys.setTimeouts(fd, client_timeout_s);
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
    const reply_ok = sys.writeAll(fd, &header) and sys.writeAll(fd, aw.written()) and sys.readAll(fd, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    const st: ?protocol.Status = if (reply_ok and len <= 1024) blk: {
        const body = arena.alloc(u8, len) catch break :blk null;
        if (!sys.readAll(fd, body)) break :blk null;
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

fn run(io: Io, env: Env, path: [:0]const u8, detach: bool, err: *Io.Writer) u8 {
    // Only one daemon per socket: the lock is held for the daemon's life
    // (and passes to the child on --detach).
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrintSentinel(&lock_buf, "{s}.lock", .{path}, 0) catch return 1;
    sys.umask(0o077);
    const lock = sys.openLockFile(lock_path) catch |e| return fail(err, lock_path, e);
    sys.tryLock(lock) catch |e| {
        if (e != error.WouldBlock) return fail(err, lock_path, e);
        err.print("buta daemon: already running ({s})\n", .{path}) catch {};
        return 1;
    };
    lock_fd = lock;

    // Holding the lock, any socket file left behind is stale.
    sys.unlink(path);
    const listen_fd = sys.socket(false) catch |e| return fail(err, "socket", e);
    sys.listen(listen_fd, path) catch |e| return fail(err, path, e);
    const watcher = watch.Watcher.init() catch |e| return fail(err, "watcher", e);

    if (detach) {
        // Fork before any thread exists. The parent returns once the child
        // owns the socket; the child leaves the terminal's session.
        const pid = sys.fork() catch |e| return fail(err, "fork", e);
        if (pid != 0) return 0;
        sys.detachFromTerminal();
    }
    sys.chdirRoot(); // don't keep a mount point busy
    sys.onTerminate(onSignal);

    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{
        .stack_size = 1024 * 1024,
        .concurrent_limit = .limited(max_connections * 2),
    });
    const daemon_io = threaded.io();
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: ?ExeId = if (std.process.executablePath(io, &exe_buf)) |n| ExeId.of(io, exe_buf[0..n]) else |_| null;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home: ?[]const u8 = if (env.get("HOME")) |h| blk: {
        if (h.len > home_buf.len) break :blk null;
        @memcpy(home_buf[0..h.len], h);
        break :blk context.normalizeHome(home_buf[0..h.len]);
    } else null;
    var state: State = .{
        .io = daemon_io,
        .gpa = std.heap.smp_allocator,
        .env = env,
        .home = home,
        .debug = env.flag("BUTA_DEBUG"),
        .watcher = watcher,
        .max_watches = if (watch.Watcher.watches_files) sys.raiseFileLimit() -| reserved_fds else std.math.maxInt(u64),
        .started = Io.Clock.Timestamp.now(daemon_io, .awake),
        .exe = exe,
    };
    if (!detach) err.print("buta daemon: listening on {s}\n", .{path}) catch {};
    err.flush() catch {};
    serve(&state, listen_fd);
}

fn fail(err: *Io.Writer, what: []const u8, e: sys.Error) u8 {
    err.print("buta daemon: {s}: {s}\n", .{ what, @errorName(e) }) catch {};
    return 1;
}

fn serve(s: *State, listen_fd: i32) noreturn {
    // Never awaited: connection tasks free themselves when they finish.
    var group: Io.Group = .init;
    var active: std.atomic.Value(u32) = .init(0);
    const uid = sys.getuid();
    var ns_buf: [64]u8 = undefined;
    const own_ns = mountNamespace(&ns_buf, sys.getpid()) orelse "";
    while (true) {
        const fd = sys.accept(listen_fd) catch |e| switch (e) {
            error.Interrupted => continue,
            else => {
                // Out of file descriptors or memory: back off instead of spinning.
                s.log("accept: {s}", .{@errorName(e)});
                sys.sleepMs(100);
                continue;
            },
        };
        // Only the user who runs the daemon may ask it about their files,
        // and only from where paths mean the same files (a client in a
        // container computes locally).
        const peer = sys.peer(fd);
        if (peer == null or peer.?.uid != uid or !sameMountNamespace(peer.?.pid, own_ns)) {
            sys.close(fd);
            continue;
        }
        sys.setTimeouts(fd, client_timeout_s);
        if (active.fetchAdd(1, .monotonic) >= max_connections) {
            _ = active.fetchSub(1, .monotonic);
            sys.close(fd); // the client computes locally
            continue;
        }
        group.concurrent(s.io, handleTask, .{ s, fd, &active }) catch {
            _ = active.fetchSub(1, .monotonic);
            sys.close(fd);
        };
    }
}

fn handleTask(s: *State, fd: i32, active: *std.atomic.Value(u32)) void {
    defer _ = active.fetchSub(1, .monotonic);
    s.handle(fd);
}

/// Linux: "mnt:[4026531841]" for `pid`, or null if it can't be read (for
/// example when the peer is in a pid namespace we can't see into).
fn mountNamespace(buf: []u8, pid: i32) ?[]const u8 {
    if (!sys.is_linux) return null;
    const linux = std.os.linux;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/ns/mnt", .{pid}, 0) catch return null;
    const rc = linux.readlink(path, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    return buf[0..rc];
}

/// Elsewhere there are no mount namespaces to tell apart.
fn sameMountNamespace(pid: ?i32, own: []const u8) bool {
    if (!sys.is_linux) return true;
    var buf: [64]u8 = undefined;
    const ns = mountNamespace(&buf, pid orelse return false) orelse return false;
    return own.len > 0 and std.mem.eql(u8, ns, own);
}

fn connectBlocking(path: [:0]const u8) ?i32 {
    const fd = sys.socket(false) catch return null;
    sys.connect(fd, path) catch {
        sys.close(fd);
        return null;
    };
    return fd;
}

test "event relevance" {
    var s: State = undefined;
    s.global_names = .empty;
    try std.testing.expect(s.relevant(.work, "main.zig"));
    try std.testing.expect(s.relevant(.work, null));
    try std.testing.expect(s.relevant(.git, "index"));
    try std.testing.expect(s.relevant(.git, "HEAD"));
    try std.testing.expect(!s.relevant(.git, "index.lock"));
    try std.testing.expect(!s.relevant(.git, "FETCH_HEAD"));
    try std.testing.expect(!s.relevant(.git, "objects"));
    try std.testing.expect(s.relevant(.refs, "main"));
    try std.testing.expect(!s.relevant(.refs, "main.lock"));
    try std.testing.expect(!s.relevant(.global, ".bash_history"));

    try std.testing.expect(s.rebuildsWatches(.git, "index"));
    try std.testing.expect(!s.rebuildsWatches(.git, "HEAD"));
    try std.testing.expect(s.rebuildsWatches(.work, ".gitignore"));
    try std.testing.expect(!s.rebuildsWatches(.work, "main.zig"));
    try std.testing.expect(s.rebuildsWatches(.rules, null));
    try std.testing.expect(!s.rebuildsWatches(.file, null));
}
