//! The common module interface.
//!
//! Every module is a file in src/modules/ exporting:
//!
//!   pub const id: Id;
//!   pub const cost: Cost;
//!   pub const Config = struct { ... };  // all fields defaulted; appears in config.zon under its id
//!   pub const Data = struct { ... };    // plain data: ints, enums, slices
//!   /// Gather data. null hides the module. An error also hides it.
//!   pub fn compute(ctx: *const Context, cfg: *const Config, arena: Allocator) !?Data;
//!   /// Pure function of its inputs: no I/O.
//!   pub fn render(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void;
//!
//! `expensive` modules must also have `timeout_ms: ?u32` in their Config.
//!
//! Computing and rendering are deliberately split. `Data` holds no pointers
//! into the Context, so it can be produced elsewhere: on a worker thread with
//! a deadline (Phase 1, `computeAll`) or in the `butad` daemon, sent over a
//! socket (Phase 3). Rendering always happens in the client.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Config = @import("config.zig").Config;
const Glyphs = @import("glyphs.zig").Glyphs;
const Line = @import("render.zig").Line;

pub const Id = enum {
    dir,
    git_branch,
    git_status,
    status,
    duration,
    character,
    jobs,
    line_break,
};

/// How expensive `compute` is.
/// * `cheap`: no I/O, bounded CPU work on the Context. Runs inline on the
///   main thread; dispatching it would cost more than computing it.
/// * `expensive`: touches the filesystem (or, later, the network). Runs on a
///   worker thread with a deadline, and is what the Phase 3 daemon caches.
pub const Cost = enum { cheap, expensive };

pub const impls = struct {
    pub const dir = @import("modules/dir.zig");
    pub const git_branch = @import("modules/git_branch.zig");
    pub const git_status = @import("modules/git_status.zig");
    pub const status = @import("modules/status.zig");
    pub const duration = @import("modules/duration.zig");
    pub const character = @import("modules/character.zig");
    pub const jobs = @import("modules/jobs.zig");
    pub const line_break = @import("modules/line_break.zig");
};

pub fn Impl(comptime id: Id) type {
    return @field(impls, @tagName(id));
}

pub const Data = union(Id) {
    dir: impls.dir.Data,
    git_branch: impls.git_branch.Data,
    git_status: impls.git_status.Data,
    status: impls.status.Data,
    duration: impls.duration.Data,
    character: impls.character.Data,
    jobs: impls.jobs.Data,
    line_break: impls.line_break.Data,
};

pub const id_count = @typeInfo(Id).@"enum".fields.len;

/// One slot per module id; null means "render nothing".
pub const Slots = [id_count]?Data;

// Compile-time check that every module implements the interface.
comptime {
    for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        const M = Impl(id);
        for ([_][]const u8{ "id", "cost", "Config", "Data", "compute", "render" }) |decl| {
            if (!@hasDecl(M, decl)) @compileError("module '" ++ f.name ++ "' is missing `" ++ decl ++ "`");
        }
        if (M.id != id) @compileError("module '" ++ f.name ++ "' declares the wrong id");
        if (@TypeOf(M.cost) != Cost) @compileError("module '" ++ f.name ++ "': cost must be a Cost");
        if (!@hasField(Config, f.name)) @compileError("Config has no section for module '" ++ f.name ++ "'");
        if (M.cost == .expensive and !@hasField(M.Config, "timeout_ms"))
            @compileError("expensive module '" ++ f.name ++ "' needs `timeout_ms: ?u32 = null` in its Config");
    }
}

pub fn configFor(comptime id: Id, cfg: *const Config) *const Impl(id).Config {
    return &@field(cfg, @tagName(id));
}

/// Bytes of private allocation space per cheap module. Modules may run on
/// different threads, so they never share an allocator. Expensive modules
/// (whose memory needs grow with the repository) get their own arena on
/// the page allocator instead; like everything else it is released when
/// the process exits.
pub const heap_size = 16 * 1024;

/// Everything a module task may touch after `computeAll` returns (plus its
/// own arena, see `Task`).
///
/// A task that misses its deadline is abandoned, not joined: it may be stuck
/// in a syscall that cannot be interrupted (a hung network mount), and
/// waiting for it would defeat the deadline. The prompt is printed and the
/// process exits, which ends the straggler. Until then it may still write to
/// its `Job` and heap, read the Context and Config, and use the Io instance,
/// so all of those must live until process exit (see `prompt` in main.zig).
pub const Runtime = struct {
    jobs: [id_count]Job = @splat(.{}),
    heaps: [id_count][heap_size]u8 = undefined,
};

const Job = struct {
    result: ?Data = null,
    /// Set (with release semantics) after `result` is written.
    done: Io.Event = .unset,
};

/// Computes every module that appears in `cfg.order`, filling `slots`.
/// Expensive modules run concurrently, each with a deadline of
/// `timeout_ms` (module override, else the global one) from the call; a
/// module that misses it gets a null slot. Cheap modules run inline
/// meanwhile. Never blocks longer than the largest deadline.
pub fn computeAll(ctx: *const Context, cfg: *const Config, rt: *Runtime, slots: *Slots) void {
    const io = ctx.io;
    const start = Io.Clock.Timestamp.now(io, .awake);
    var launched: [id_count]bool = @splat(false);

    // Launch expensive modules first so they overlap with everything else.
    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        slots[f.value] = null;
        if (Impl(id).cost == .expensive and inOrder(cfg, id)) {
            const job = &rt.jobs[f.value];
            const args = .{ job, ctx, cfg };
            if (io.concurrent(Task(id).run, args)) |_| {
                launched[f.value] = true;
            } else |_| {
                // No concurrency available (e.g. thread spawn failed): run inline, without a deadline.
                @call(.auto, Task(id).run, args);
                slots[f.value] = job.result;
            }
        }
    }

    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        if (Impl(id).cost == .cheap and inOrder(cfg, id)) {
            var fba: std.heap.FixedBufferAllocator = .init(&rt.heaps[f.value]);
            slots[f.value] = computeOne(id, ctx, configFor(id, cfg), fba.allocator());
        }
    }

    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        if (Impl(id).cost == .expensive) {
            if (launched[f.value]) {
                const timeout_ms = configFor(id, cfg).timeout_ms orelse cfg.timeout_ms;
                const deadline = start.addDuration(.{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
                const job = &rt.jobs[f.value];
                if (waitUntil(io, &job.done, deadline)) {
                    slots[f.value] = job.result;
                } else if (ctx.debug) {
                    std.debug.print("buta: module {s}: missed its {d} ms deadline\n", .{ @tagName(id), timeout_ms });
                }
            }
        }
    }
}

/// Waits for `event` until `deadline`. Returns whether it was set in time.
fn waitUntil(io: Io, event: *Io.Event, deadline: Io.Clock.Timestamp) bool {
    while (!event.isSet()) {
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return false;
        // Timeout and spurious wakeups both land here; the loop re-checks.
        event.waitTimeout(io, .{ .deadline = deadline }) catch {};
    }
    return true;
}

fn Task(comptime id: Id) type {
    return struct {
        fn run(job: *Job, ctx: *const Context, cfg: *const Config) void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            // Not deinitialized: the result points into it, and a straggler
            // must never free memory the main thread might be reading.
            job.result = computeOne(id, ctx, configFor(id, cfg), arena.allocator());
            job.done.set(ctx.io);
        }
    };
}

fn inOrder(cfg: *const Config, id: Id) bool {
    return std.mem.indexOfScalar(Id, cfg.order, id) != null;
}

fn computeOne(comptime id: Id, ctx: *const Context, cfg: *const Impl(id).Config, arena: Allocator) ?Data {
    const data = Impl(id).compute(ctx, cfg, arena) catch |err| {
        if (ctx.debug) std.debug.print("buta: module {s}: {s}\n", .{ @tagName(id), @errorName(err) });
        return null;
    } orelse return null;
    return @unionInit(Data, @tagName(id), data);
}

pub fn renderOne(data: *const Data, cfg: *const Config, g: *const Glyphs, line: *Line) Line.Error!void {
    switch (data.*) {
        inline else => |*d, id| try Impl(id).render(d, configFor(id, cfg), g, line),
    }
}

/// Renders the modules in `cfg.order`, inserting `cfg.separator` between
/// non-empty segments. A module that fails to render is rolled back and
/// skipped; the rest of the prompt is unaffected.
pub fn renderAll(slots: *const Slots, cfg: *const Config, g: *const Glyphs, line: *Line) void {
    var need_separator = false;
    for (cfg.order) |id| {
        const data = &(slots[@intFromEnum(id)] orelse continue);
        const start = line.mark();
        if (id != .line_break and need_separator) line.text(.{}, cfg.separator) catch return;
        const after_separator = line.mark();
        renderOne(data, cfg, g, line) catch {
            line.restore(start);
            continue;
        };
        if (id == .line_break) {
            need_separator = false;
        } else if (line.len == after_separator.len) {
            line.restore(start); // rendered nothing: drop the separator too
        } else {
            need_separator = true;
        }
    }
}

test "renderAll skips empty and hidden modules and joins with separator" {
    const render = @import("render.zig");
    var cfg: Config = .{};
    cfg.order = &.{ .dir, .status, .duration, .line_break, .character };
    var slots: Slots = @splat(null);
    slots[@intFromEnum(Id.dir)] = .{ .dir = .{ .path = "/tmp", .home_relative = false } };
    slots[@intFromEnum(Id.duration)] = .{ .duration = .{ .ms = 2500 } };
    slots[@intFromEnum(Id.line_break)] = .{ .line_break = .{} };
    slots[@intFromEnum(Id.character)] = .{ .character = .{ .success = true } };
    var line: Line = .{};
    renderAll(&slots, &cfg, @import("glyphs.zig").get(.ascii), &line);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render.write(&line, .plain, &w);
    // Strip ANSI for an easy comparison.
    var stripped: [256]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    const out = w.buffered();
    while (i < out.len) : (i += 1) {
        if (out[i] == 0x1b) {
            while (out[i] != 'm') i += 1;
            continue;
        }
        stripped[n] = out[i];
        n += 1;
    }
    try std.testing.expectEqualStrings("/tmp took 2.5s\n> ", stripped[0..n]);
}
