const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const exe = addButa(b, target, optimize, options);
    b.installArtifact(exe);

    // zig build run -- prompt --shell bash ...
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run buta").dependOn(&run_cmd.step);

    // Unit tests live next to the code; integration tests drive the real binary.
    const test_step = b.step("test", "Run unit and integration tests");

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const it_options = b.addOptions();
    it_options.addOptionPath("buta_path", exe.getEmittedBin());
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = it_options.createModule() }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // The benchmark always measures a ReleaseFast binary, whatever -Doptimize says.
    const fast_exe = addButa(b, target, .ReleaseFast, options);
    const bench_exe = b.addExecutable(.{
        .name = "buta-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addArtifactArg(fast_exe);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Benchmark `buta prompt` (ReleaseFast)").dependOn(&run_bench.step);
}

fn addButa(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "buta",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
        }),
    });
}
