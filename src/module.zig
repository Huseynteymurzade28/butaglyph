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
//! `expensive` modules must also have `timeout_ms: ?u32` in their Config,
//! and may declare
//!
//!   pub const scope: Scope = .repo;
//!
//! to have the daemon compute and cache them (see `Scope`), or
//!
//!   pub const batch = true;
//!
//! to share one worker thread with the other batched modules (see `batched`).
//!
//! Computing and rendering are deliberately split. `Data` holds no pointers
//! into the Context, so it can be produced elsewhere: on a worker thread with
//! a deadline (`computeAll`) or in the daemon, sent over a socket
//! (src/daemon.zig, src/client.zig). Rendering always happens in the client.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Config = @import("config.zig").Config;
const Glyphs = @import("glyphs.zig").Glyphs;
const Line = @import("render.zig").Line;
const client = @import("client.zig");

pub const Id = enum {
    dir,
    git_branch,
    git_status,
    status,
    duration,
    character,
    jobs,
    line_break,
    text,
    python,
    node,
    rust,
    go,
    zig,
    java,
    ruby,
    php,
    deno,
    bun,
    dotnet,
    lua,
    haskell,
    docker_context,
    kubernetes,
    aws,
    os,
    user,
};

/// How expensive `compute` is.
/// * `cheap`: no I/O, bounded CPU work on the Context. Runs inline on the
///   main thread; dispatching it would cost more than computing it.
/// * `expensive`: touches the filesystem (or, later, the network). Runs on a
///   worker thread with a deadline, and is what the daemon caches.
pub const Cost = enum { cheap, expensive };

/// What an expensive module's result depends on, which decides whether the
/// daemon may serve it from its cache.
/// * `local` (the default): anything in the Context. Always computed by
///   the client.
/// * `repo`: only the git repository containing `ctx.physical_cwd` (its
///   work tree, index, HEAD, refs and config, plus the user's global git
///   files) and the module's Config. The daemon computes it with a Context
///   that has only `io`, `cwd`, `physical_cwd`, `debug` and its own `env`
///   and `home` filled in, and keeps the result until the file system
///   reports a change in that repository. Its Config and Data must be
///   encodable by src/wire.zig.
pub const Scope = enum { local, repo };

pub fn scopeOf(comptime M: type) Scope {
    return if (@hasDecl(M, "scope")) M.scope else .local;
}

/// Batched modules are computed one after another on a single worker
/// thread, in `Id` order. They are the ones that usually find nothing to
/// show after a few `stat` calls or file reads (the language and context
/// modules), where a thread each would cost more than the work. Each
/// still has its own deadline.
pub fn batched(comptime M: type) bool {
    return M.cost == .expensive and @hasDecl(M, "batch") and M.batch;
}

pub const impls = struct {
    pub const dir = @import("modules/dir.zig");
    pub const git_branch = @import("modules/git_branch.zig");
    pub const git_status = @import("modules/git_status.zig");
    pub const status = @import("modules/status.zig");
    pub const duration = @import("modules/duration.zig");
    pub const character = @import("modules/character.zig");
    pub const jobs = @import("modules/jobs.zig");
    pub const line_break = @import("modules/line_break.zig");
    pub const text = @import("modules/text.zig");
    pub const python = @import("modules/python.zig");
    pub const node = @import("modules/node.zig");
    pub const rust = @import("modules/rust.zig");
    pub const go = @import("modules/go.zig");
    pub const zig = @import("modules/zig.zig");
    pub const java = @import("modules/java.zig");
    pub const ruby = @import("modules/langs.zig").ruby;
    pub const php = @import("modules/langs.zig").php;
    pub const deno = @import("modules/langs.zig").deno;
    pub const bun = @import("modules/langs.zig").bun;
    pub const dotnet = @import("modules/dotnet.zig");
    pub const lua = @import("modules/langs.zig").lua;
    pub const haskell = @import("modules/langs.zig").haskell;
    pub const docker_context = @import("modules/docker_context.zig");
    pub const kubernetes = @import("modules/kubernetes.zig");
    pub const aws = @import("modules/aws.zig");
    pub const os = @import("modules/os.zig");
    pub const user = @import("modules/user.zig");
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
    text: impls.text.Data,
    python: impls.python.Data,
    node: impls.node.Data,
    rust: impls.rust.Data,
    go: impls.go.Data,
    zig: impls.zig.Data,
    java: impls.java.Data,
    ruby: impls.ruby.Data,
    php: impls.php.Data,
    deno: impls.deno.Data,
    bun: impls.bun.Data,
    dotnet: impls.dotnet.Data,
    lua: impls.lua.Data,
    haskell: impls.haskell.Data,
    docker_context: impls.docker_context.Data,
    kubernetes: impls.kubernetes.Data,
    aws: impls.aws.Data,
    os: impls.os.Data,
    user: impls.user.Data,
};

pub const ids = std.meta.tags(Id);
pub const id_count = ids.len;

/// One slot per module id; null means "render nothing".
pub const Slots = [id_count]?Data;

// Compile-time check that every module implements the interface.
comptime {
    for (ids) |id| {
        const M = Impl(id);
        for ([_][]const u8{ "id", "cost", "Config", "Data", "compute", "render" }) |decl| {
            if (!@hasDecl(M, decl)) @compileError("module '" ++ @tagName(id) ++ "' is missing `" ++ decl ++ "`");
        }
        if (M.id != id) @compileError("module '" ++ @tagName(id) ++ "' declares the wrong id");
        if (@TypeOf(M.cost) != Cost) @compileError("module '" ++ @tagName(id) ++ "': cost must be a Cost");
        if (!@hasField(Config, @tagName(id))) @compileError("Config has no section for module '" ++ @tagName(id) ++ "'");
        if (M.cost == .expensive and !@hasField(M.Config, "timeout_ms"))
            @compileError("expensive module '" ++ @tagName(id) ++ "' needs `timeout_ms: ?u32 = null` in its Config");
        if (scopeOf(M) != .local and M.cost != .expensive)
            @compileError("module '" ++ @tagName(id) ++ "': only expensive modules can have a scope");
        if (@hasDecl(M, "batch") and (M.cost != .expensive or scopeOf(M) != .local))
            @compileError("module '" ++ @tagName(id) ++ "': only local expensive modules can be batched");
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
/// module that misses it gets a null slot. Repo-scoped modules are asked
/// of the daemon when one is running, and computed here when it is not (or
/// when it hangs up without answering). Cheap modules run inline
/// meanwhile. Never blocks longer than the largest deadline.
pub fn computeAll(ctx: *const Context, cfg: *const Config, rt: *Runtime, slots: *Slots) void {
    const start = Io.Clock.Timestamp.now(ctx.io, .awake);
    var launched: [id_count]bool = @splat(false);
    slots.* = @splat(null);

    // Send the daemon its request first, so it works while we do.
    var conn: client.Conn = .{};
    const asked = conn.open(ctx, cfg);

    // Launch the other expensive modules so they overlap with everything else.
    inline for (ids) |id| {
        if (Impl(id).cost == .expensive and !batched(Impl(id)) and inOrder(cfg, id) and !conn.pending[@backingInt(id)]) {
            launch(id, ctx, cfg, rt, slots, &launched);
        }
    }
    launchBatch(ctx, cfg, rt, slots, &launched);

    inline for (ids) |id| {
        if (Impl(id).cost == .cheap and inOrder(cfg, id)) {
            var fba: std.heap.FixedBufferAllocator = .init(&rt.heaps[@backingInt(id)]);
            slots[@backingInt(id)] = computeOne(id, ctx, configFor(id, cfg), fba.allocator());
        }
    }

    if (asked) {
        conn.collect(ctx, cfg, start, rt, slots);
        // What the daemon left unanswered (it hung up early) is computed here.
        inline for (ids) |id| {
            if (Impl(id).cost == .expensive and conn.pending[@backingInt(id)]) launch(id, ctx, cfg, rt, slots, &launched);
        }
    }

    inline for (ids) |id| {
        if (Impl(id).cost == .expensive) {
            if (launched[@backingInt(id)]) {
                const job = &rt.jobs[@backingInt(id)];
                if (waitUntil(ctx.io, &job.done, deadlineFor(id, cfg, start))) {
                    slots[@backingInt(id)] = job.result;
                } else if (ctx.debug) {
                    std.debug.print("buta: module {s}: missed its {d} ms deadline\n", .{ @tagName(id), timeoutFor(id, cfg) });
                }
            }
        }
    }
}

fn launch(comptime id: Id, ctx: *const Context, cfg: *const Config, rt: *Runtime, slots: *Slots, launched: *[id_count]bool) void {
    const job = &rt.jobs[@backingInt(id)];
    const args = .{ job, ctx, cfg };
    if (ctx.io.concurrent(Task(id).run, args)) |_| {
        launched[@backingInt(id)] = true;
    } else |_| {
        // No concurrency available (e.g. thread spawn failed): run inline, without a deadline.
        @call(.auto, Task(id).run, args);
        slots[@backingInt(id)] = job.result;
    }
}

/// Starts the batched modules in `cfg.order` on one worker thread.
fn launchBatch(ctx: *const Context, cfg: *const Config, rt: *Runtime, slots: *Slots, launched: *[id_count]bool) void {
    var any = false;
    inline for (ids) |id| {
        if (batched(Impl(id)) and inOrder(cfg, id)) any = true;
    }
    if (!any) return;
    const args = .{ rt, ctx, cfg };
    if (ctx.io.concurrent(BatchTask.run, args)) |_| {
        inline for (ids) |id| {
            if (batched(Impl(id)) and inOrder(cfg, id)) launched[@backingInt(id)] = true;
        }
    } else |_| {
        @call(.auto, BatchTask.run, args);
        inline for (ids) |id| {
            if (batched(Impl(id))) slots[@backingInt(id)] = rt.jobs[@backingInt(id)].result;
        }
    }
}

const BatchTask = struct {
    fn run(rt: *Runtime, ctx: *const Context, cfg: *const Config) void {
        inline for (ids) |id| {
            if (comptime batched(Impl(id))) {
                if (inOrder(cfg, id)) Task(id).run(&rt.jobs[@backingInt(id)], ctx, cfg);
            }
        }
    }
};

pub fn timeoutFor(comptime id: Id, cfg: *const Config) u32 {
    return configFor(id, cfg).timeout_ms orelse cfg.timeout_ms;
}

pub fn deadlineFor(comptime id: Id, cfg: *const Config, start: Io.Clock.Timestamp) Io.Clock.Timestamp {
    return start.addDuration(.{ .raw = .fromMilliseconds(timeoutFor(id, cfg)), .clock = .awake });
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

pub fn inOrder(cfg: *const Config, id: Id) bool {
    return std.mem.indexOfScalar(Id, cfg.order, id) != null;
}

pub fn computeOne(comptime id: Id, ctx: *const Context, cfg: *const Impl(id).Config, arena: Allocator) ?Data {
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
/// non-empty ones, or, with `cfg.segments`, joining modules that have a
/// background into segments. A module that fails to render is rolled back
/// and skipped; the rest of the prompt is unaffected.
pub fn renderAll(slots: *const Slots, cfg: *const Config, g: *const Glyphs, line: *Line) void {
    var w: Weaver = .{ .cfg = cfg, .line = line };
    for (cfg.order) |id| {
        const data = &(slots[@backingInt(id)] orelse continue);
        if (id == .line_break) {
            w.endLine() catch return;
            line.newline() catch return;
            continue;
        }
        const start = line.mark();
        const saved = w;
        renderOne(data, cfg, g, line) catch {
            line.restore(start);
            continue;
        };
        if (line.len == start.len) continue; // rendered nothing
        w.frame(start.len) catch {
            line.restore(start);
            w = saved;
        };
    }
    w.endLine() catch {};
}

/// Puts separators, or segment joints and padding, around each module's spans.
const Weaver = struct {
    cfg: *const Config,
    line: *Line,
    need_separator: bool = false,
    /// Background of the segment the line currently ends in.
    open_bg: ?[]const u8 = null,

    const Span = Line.Span;
    const edge = @import("render.zig").Paint.edge;

    fn span(style: @import("render.zig").Style, text: []const u8) Span {
        return .{ .style = style, .kind = .text, .text = text };
    }

    /// The module's spans start at `at` and run to the end of the line.
    fn frame(w: *Weaver, at: usize) Line.Error!void {
        var before: [4]Span = undefined;
        var n: usize = 0;
        const bg = if (w.cfg.segments != null) segmentBackground(w.line.items()[at..]) else null;
        if (bg) |b| {
            const seg = w.cfg.segments.?;
            if (w.open_bg != null and seg.join != null) {
                before[n] = span(.{ .fg = edge(w.open_bg.?, true), .bg = edge(b, false) }, seg.join.?);
                n += 1;
            } else {
                if (w.open_bg) |prev| {
                    before[n] = span(.{ .fg = edge(prev, true) }, seg.close);
                    n += 1;
                }
                if (w.need_separator) {
                    before[n] = span(.{}, w.cfg.separator);
                    n += 1;
                }
                before[n] = span(.{ .fg = edge(b, false) }, seg.open);
                n += 1;
            }
            before[n] = span(.{ .bg = edge(b, false) }, seg.padding);
            n += 1;
            try w.insertNonEmpty(at, before[0..n]);
            try w.line.text(.{ .bg = edge(b, true) }, seg.padding);
            w.open_bg = b;
        } else {
            if (w.open_bg) |prev| {
                before[n] = span(.{ .fg = edge(prev, true) }, w.cfg.segments.?.close);
                n += 1;
                w.open_bg = null;
            }
            if (w.need_separator) {
                before[n] = span(.{}, w.cfg.separator);
                n += 1;
            }
            try w.insertNonEmpty(at, before[0..n]);
        }
        w.need_separator = true;
    }

    fn insertNonEmpty(w: *Weaver, at: usize, spans: []const Span) Line.Error!void {
        var keep: [4]Span = undefined;
        var n: usize = 0;
        for (spans) |s| if (s.text.len > 0) {
            keep[n] = s;
            n += 1;
        };
        try w.line.insert(at, keep[0..n]);
    }

    /// Closes an open segment run; the next module starts a fresh line.
    fn endLine(w: *Weaver) Line.Error!void {
        if (w.open_bg) |prev| try w.line.text(.{ .fg = edge(prev, true) }, w.cfg.segments.?.close);
        w.open_bg = null;
        w.need_separator = false;
    }
};

/// A module is a segment if it draws something with a background color.
fn segmentBackground(spans: []const Line.Span) ?[]const u8 {
    for (spans) |s| if (s.style.bg) |b| return b;
    return null;
}

test "renderAll skips empty and hidden modules and joins with separator" {
    const render = @import("render.zig");
    var cfg: Config = .{};
    cfg.order = &.{ .dir, .status, .duration, .line_break, .character };
    var slots: Slots = @splat(null);
    slots[@backingInt(Id.dir)] = .{ .dir = .{ .path = "/tmp", .home_relative = false } };
    slots[@backingInt(Id.duration)] = .{ .duration = .{ .ms = 2500 } };
    slots[@backingInt(Id.line_break)] = .{ .line_break = .{} };
    slots[@backingInt(Id.character)] = .{ .character = .{ .success = true } };
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

test "segments join modules that have a background" {
    const render = @import("render.zig");
    var cfg: Config = .{};
    cfg.order = &.{ .dir, .status, .duration, .line_break, .character };
    cfg.segments = .{ .open = "(", .join = ">", .close = ")", .padding = " " };
    cfg.dir.style = .{ .fg = "black", .bg = "blue" };
    cfg.duration.style = .{ .bg = "#ff0000>#00ff00" };
    var slots: Slots = @splat(null);
    slots[@backingInt(Id.dir)] = .{ .dir = .{ .path = "/tmp", .home_relative = false } };
    slots[@backingInt(Id.status)] = .{ .status = .{ .code = 1 } };
    slots[@backingInt(Id.duration)] = .{ .duration = .{ .ms = 2500 } };
    slots[@backingInt(Id.line_break)] = .{ .line_break = .{} };
    slots[@backingInt(Id.character)] = .{ .character = .{ .success = true } };
    var line: Line = .{};
    renderAll(&slots, &cfg, @import("glyphs.zig").get(.ascii), &line);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (line.items()) |sp| try text.appendSlice(std.testing.allocator, sp.text);
    // status has no background: it closes the first run and opens nothing.
    try std.testing.expectEqualStrings("( /tmp ) x 1 ( took 2.5s )\n> ", text.items);

    // Joints are drawn in the neighbors' colors, gradient edges included.
    for (line.items()) |sp| {
        if (std.mem.eql(u8, sp.text, "(") and sp.style.fg.?[0] == '#') try std.testing.expectEqualStrings("#ff0000", sp.style.fg.?);
        if (std.mem.eql(u8, sp.text, ")") and sp.style.fg.?[0] == '#') try std.testing.expectEqualStrings("#00ff00", sp.style.fg.?);
    }
    _ = render;
}

test "adjacent segments share one joint" {
    var cfg: Config = .{};
    cfg.order = &.{ .dir, .duration };
    cfg.segments = .{ .open = "[", .join = ">", .close = "]", .padding = "" };
    cfg.dir.style = .{ .bg = "blue" };
    cfg.duration.style = .{ .bg = "red" };
    var slots: Slots = @splat(null);
    slots[@backingInt(Id.dir)] = .{ .dir = .{ .path = "/tmp", .home_relative = false } };
    slots[@backingInt(Id.duration)] = .{ .duration = .{ .ms = 2500 } };
    var line: Line = .{};
    renderAll(&slots, &cfg, @import("glyphs.zig").get(.ascii), &line);
    var joint: ?Line.Span = null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (line.items()) |sp| {
        try text.appendSlice(std.testing.allocator, sp.text);
        if (std.mem.eql(u8, sp.text, ">")) joint = sp;
    }
    try std.testing.expectEqualStrings("[/tmp>took 2.5s]", text.items);
    try std.testing.expectEqualStrings("blue", joint.?.style.fg.?);
    try std.testing.expectEqualStrings("red", joint.?.style.bg.?);
}

test "without a join, every segment is its own pill" {
    var cfg: Config = .{};
    cfg.order = &.{ .dir, .duration };
    cfg.segments = .{ .open = "(", .join = null, .close = ")", .padding = "" };
    cfg.dir.style = .{ .bg = "blue" };
    cfg.duration.style = .{ .bg = "red" };
    var slots: Slots = @splat(null);
    slots[@backingInt(Id.dir)] = .{ .dir = .{ .path = "/tmp", .home_relative = false } };
    slots[@backingInt(Id.duration)] = .{ .duration = .{ .ms = 2500 } };
    var line: Line = .{};
    renderAll(&slots, &cfg, @import("glyphs.zig").get(.ascii), &line);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (line.items()) |sp| try text.appendSlice(std.testing.allocator, sp.text);
    try std.testing.expectEqualStrings("(/tmp) (took 2.5s)", text.items);
}
