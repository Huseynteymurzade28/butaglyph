//! zig build bench [-- <iterations>]
//!
//! Spawns `buta prompt` N times (default 1000) from the current directory
//! and reports wall-clock statistics. Each sample includes fork/exec, i.e.
//! exactly what the shell pays per prompt. `/bin/true` is measured the same
//! way as a baseline for the process-spawn cost alone.

const std = @import("std");
const Io = std.Io;

const target_mean_ms = 2.0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.MissingButaPath;
    const iterations = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 1000;

    const prompt_argv = [_][]const u8{ args[1], "prompt", "--shell", "bash", "--status", "1", "--duration-ms", "3500", "--jobs", "1" };
    const baseline = try measure(io, arena, &.{"/bin/true"}, iterations);
    const stats = try measure(io, arena, &prompt_argv, iterations);

    var out_buf: [2048]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;
    try out.print("buta prompt ({d} runs, ReleaseFast, cwd: git repo)\n", .{iterations});
    try report(out, "buta prompt", stats);
    try report(out, "/bin/true  ", baseline);
    // buta is statically linked; /bin/true usually is not, so the difference
    // can be negative (no dynamic loader work for buta).
    try out.print("difference vs /bin/true: {d:.3} ms\n", .{stats.mean - baseline.mean});
    try out.print("target mean < {d:.1} ms: {s}\n", .{ target_mean_ms, if (stats.mean < target_mean_ms) "PASS" else "FAIL" });
    try out.flush();
}

const Stats = struct { mean: f64, p50: f64, p99: f64, min: f64, max: f64 };

fn measure(io: Io, arena: std.mem.Allocator, argv: []const []const u8, n: usize) !Stats {
    const samples = try arena.alloc(f64, n);
    for (0..20) |_| _ = try runOnce(io, argv); // warm up the page cache
    for (samples) |*s| s.* = try runOnce(io, argv);
    std.mem.sortUnstable(f64, samples, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (samples) |s| sum += s;
    return .{
        .mean = sum / @as(f64, @floatFromInt(n)),
        .p50 = samples[n / 2],
        .p99 = samples[@min(n - 1, (n * 99) / 100)],
        .min = samples[0],
        .max = samples[n - 1],
    };
}

fn runOnce(io: Io, argv: []const []const u8) !f64 {
    const start = Io.Timestamp.now(io, .awake);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const ns = start.untilNow(io, .awake).toNanoseconds();
    if (term != .exited or term.exited != 0) return error.ChildFailed;
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn report(out: *Io.Writer, label: []const u8, s: Stats) !void {
    try out.print("  {s}  mean {d:.3} ms  p50 {d:.3}  p99 {d:.3}  min {d:.3}  max {d:.3}\n", .{ label, s.mean, s.p50, s.p99, s.min, s.max });
}
