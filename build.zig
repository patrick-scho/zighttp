const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("http", .{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/http.zig" } },
        .target = target,
        .optimize = optimize,
    });
    _ = mod;

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/lmdb.zig" },
        .target = target,
        .optimize = optimize,
    });

    // const test_bin = b.addInstallBinFile(unit_tests.getEmittedBin(), "./lmdb_test");

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&unit_tests.step);
    // test_step.dependOn(&test_bin.step);
}
