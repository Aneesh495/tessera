const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tessera library module
    const lib_mod = b.addModule("tessera", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tessera CLI executable
    const exe = b.addExecutable(.{
        .name = "tessera",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tessera", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run CLI step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Tessera CLI");
    run_step.dependOn(&run_cmd.step);

    // Tessera Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "tessera-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tessera", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const run_bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the performance benchmark suite");
    bench_step.dependOn(&run_bench_cmd.step);

    // Tessera Storage Inspector executable
    const inspect_exe = b.addExecutable(.{
        .name = "tessera-inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/inspect.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tessera", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(inspect_exe);

    const run_inspect_cmd = b.addRunArtifact(inspect_exe);
    const inspect_step = b.step("inspect", "Run the storage inspector tool");
    inspect_step.dependOn(&run_inspect_cmd.step);

    // Tests for library module
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // Tests for CLI executable
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
