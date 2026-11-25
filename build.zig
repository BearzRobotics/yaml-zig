//! yaml-zig build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as @import("yaml").
    const mod = b.addModule("yaml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // The official conformance suite, from a local checkout (it is not vendored).
    const conformance_step = b.step("conformance", "Run yaml-test-suite; needs -Dsuite=PATH");
    const conformance_exe = b.addExecutable(.{
        .name = "yaml-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yaml", .module = mod }},
        }),
    });
    // Compile (not run) it with the tests, so that it cannot stop building unnoticed.
    test_step.dependOn(&conformance_exe.step);
    if (b.option([]const u8, "suite", "A data checkout of yaml-test-suite")) |suite| {
        const run = b.addRunArtifact(conformance_exe);
        run.addArg(suite);
        run.has_side_effects = true;
        conformance_step.dependOn(&run.step);
    } else {
        conformance_step.dependOn(&b.addFail("pass -Dsuite=PATH/yaml-test-suite").step);
    }
}
