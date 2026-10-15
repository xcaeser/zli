const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional: expose module if reused
    const mod = b.addModule("zli", .{
        .root_source_file = b.path("src/zli.zig"),
        .single_threaded = false,
        .target = target,
        .optimize = optimize,
    });

    // Test runner
    const lib_test = b.addTest(.{
        .root_module = mod,
    });

    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    // Tests that use zli through `@import("zli")`, like an app would.
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};
    const usage_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zli_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zli", .module = mod }},
        }),
        .filters = test_filters,
    });
    const run_usage_test = b.addRunArtifact(usage_test);
    run_usage_test.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
    test_step.dependOn(&run_usage_test.step);

    const docs_step = b.step("docs", "Build the zli library docs");
    const docs_obj = b.addObject(.{
        .name = "zli",
        .root_module = mod,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
