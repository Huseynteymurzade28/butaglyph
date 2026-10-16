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
//! Computing and rendering are deliberately split. `Data` holds no pointers
//! into the Context, so later phases can produce it elsewhere: on a worker
//! thread with a deadline (Phase 1) or in the `butad` daemon, sent over a
//! socket (Phase 3). Rendering always happens in the client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Config = @import("config.zig").Config;
const Glyphs = @import("glyphs.zig").Glyphs;
const Line = @import("render.zig").Line;

pub const Id = enum {
    dir,
    git_branch,
    status,
    duration,
    character,
    jobs,
    line_break,
};

/// How expensive `compute` is. `expensive` modules are the ones that get a
/// deadline in Phase 1 and are served from the daemon cache in Phase 3.
pub const Cost = enum { cheap, expensive };

pub const impls = struct {
    pub const dir = @import("modules/dir.zig");
    pub const git_branch = @import("modules/git_branch.zig");
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
    }
}

pub fn configFor(comptime id: Id, cfg: *const Config) *const Impl(id).Config {
    return &@field(cfg, @tagName(id));
}

/// Phase 0 driver: computes every module that appears in `cfg.order`,
/// sequentially. Phase 1 replaces only this function (one task per module,
/// a deadline per task, the slot stays null on timeout).
pub fn computeAll(ctx: *const Context, cfg: *const Config, arena: Allocator, slots: *Slots) void {
    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        slots[f.value] = if (std.mem.indexOfScalar(Id, cfg.order, id) != null)
            computeOne(id, ctx, cfg, arena)
        else
            null;
    }
}

fn computeOne(comptime id: Id, ctx: *const Context, cfg: *const Config, arena: Allocator) ?Data {
    const data = Impl(id).compute(ctx, configFor(id, cfg), arena) catch |err| {
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
