const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library
    const lib = b.addStaticLibrary(.{
        .name = "zvdb",
        .root_source_file = b.path("src/zvdb.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Create a module for the library
    const lib_module = b.addModule("zvdb", .{
        .root_source_file = b.path("src/zvdb.zig"),
    });

    const hnsw_tests = b.addTest(.{
        .root_source_file = b.path("src/test_hnsw.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_hnsw_tests = b.addRunArtifact(hnsw_tests);

    const hnsw_test_step = b.step("test", "Run tests");
    hnsw_test_step.dependOn(&run_hnsw_tests.step);

    // Add unit tests
    // const unit_tests = b.addTest(.{
    //     .root_source_file = b.path("tests/unit/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const run_unit_tests = b.addRunArtifact(unit_tests);
    // const unit_test_step = b.step("unit-test", "Run unit tests");
    // unit_test_step.dependOn(&run_unit_tests.step);

    // // Add integration tests
    // const integration_tests = b.addTest(.{
    //     .root_source_file = b.path("tests/integration/full_flow_test.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const run_integration_tests = b.addRunArtifact(integration_tests);
    // const integration_test_step = b.step("integration-test", "Run integration tests");
    // integration_test_step.dependOn(&run_integration_tests.step);

    // Benchmarks:
    // Single-threaded benchmarks
    const single_threaded_benchmarks = b.addExecutable(.{
        .name = "single_threaded_benchmarks",
        .root_source_file = b.path("benchmarks/single_threaded_benchmarks.zig"),
        .target = target,
        .optimize = optimize,
    });
    single_threaded_benchmarks.root_module.addImport("zvdb", lib_module);
    b.installArtifact(single_threaded_benchmarks);

    const run_single_threaded = b.addRunArtifact(single_threaded_benchmarks);
    if (b.args) |args| {
        run_single_threaded.addArgs(args);
    }
    const run_single_threaded_step = b.step("bench-single", "Run single-threaded benchmarks");
    run_single_threaded_step.dependOn(&run_single_threaded.step);

    // Multi-threaded benchmarks
    const multi_threaded_benchmarks = b.addExecutable(.{
        .name = "multi_threaded_benchmarks",
        .root_source_file = b.path("benchmarks/multi_threaded_benchmarks.zig"),
        .target = target,
        .optimize = optimize,
    });
    multi_threaded_benchmarks.root_module.addImport("zvdb", lib_module);
    b.installArtifact(multi_threaded_benchmarks);

    const run_multi_threaded = b.addRunArtifact(multi_threaded_benchmarks);
    if (b.args) |args| {
        run_multi_threaded.addArgs(args);
    }
    const run_multi_threaded_step = b.step("bench-multi", "Run multi-threaded benchmarks");
    run_multi_threaded_step.dependOn(&run_multi_threaded.step);

    // Examples
    // const basic_example = b.addExecutable(.{
    //     .name = "basic_usage",
    //     .root_source_file = b.path("examples/basic_usage.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // basic_example.root_module.addImport("zvdb", lib_module);
    // b.installArtifact(basic_example);

    // const advanced_example = b.addExecutable(.{
    //     .name = "advanced_usage",
    //     .root_source_file = b.path("examples/advanced_usage.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // advanced_example.root_module.addImport("zvdb", lib_module);
    // b.installArtifact(advanced_example);

    // Benchmarks
    // const index_benchmark = b.addExecutable(.{
    //     .name = "index_performance",
    //     .root_source_file = b.path("benchmarks/index_performance.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // index_benchmark.root_module.addImport("zvdb", lib_module);
    // b.installArtifact(index_benchmark);

    // const search_benchmark = b.addExecutable(.{
    //     .name = "search_performance",
    //     .root_source_file = b.path("benchmarks/search_performance.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // search_benchmark.root_module.addImport("zvdb", lib_module);
    // b.installArtifact(search_benchmark);

    // // Run benchmarks step
    // const run_benchmarks = b.step("benchmark", "Run performance benchmarks");
    // const run_index_benchmark = b.addRunArtifact(index_benchmark);
    // const run_search_benchmark = b.addRunArtifact(search_benchmark);
    // run_benchmarks.dependOn(&run_index_benchmark.step);
    // run_benchmarks.dependOn(&run_search_benchmark.step);
}
