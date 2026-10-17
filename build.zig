const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const git = b.createModule(.{
        .root_source_file = b.path("src/git/git.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = addButa(b, target, optimize, options, git);
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
    const git_unit_tests = b.addTest(.{ .root_module = git });
    test_step.dependOn(&b.addRunArtifact(git_unit_tests).step);

    // Compares the git reader against the real `git` CLI on generated repos
    // (skipped when git is not installed).
    const git_compat = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/git_compat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "git", .module = git }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(git_compat).step);

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

    // Runs the real daemon and checks its answers against local computation.
    const sys = b.createModule(.{ .root_source_file = b.path("src/sys.zig"), .target = target, .optimize = optimize });
    const daemon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/daemon.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = it_options.createModule() },
                .{ .name = "sys", .module = sys },
            },
        }),
    });
    // The daemon exists on Linux and macOS only.
    if (target.result.os.tag == .linux or target.result.os.tag.isDarwin()) {
        test_step.dependOn(&b.addRunArtifact(daemon_tests).step);
    }

    // The benchmark always measures a ReleaseFast binary, whatever -Doptimize says.
    const fast_git = b.createModule(.{
        .root_source_file = b.path("src/git/git.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const fast_exe = addButa(b, target, .ReleaseFast, options, fast_git);
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
    git: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "buta",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "git", .module = git },
            },
        }),
    });
}
