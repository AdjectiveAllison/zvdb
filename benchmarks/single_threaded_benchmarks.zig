const std = @import("std");
const shared = @import("shared_benchmarks.zig");
const HNSW = @import("zvdb").HNSW;

pub fn runSingleThreadedBenchmarks(allocator: std.mem.Allocator, config: shared.BenchmarkConfig) !void {
    std.debug.print("Running Single-Threaded Benchmarks\n", .{});
    std.debug.print("================================\n\n", .{});

    for (config.dimensions) |dim| {
        std.debug.print("Dimension: {d}\n", .{dim});

        // Build the index
        var hnsw = try shared.buildIndex(allocator, dim, config.index_size);
        defer hnsw.deinit();

        // Insertion benchmark
        const insertion_result = try shared.runInsertionBenchmark(allocator, &hnsw, dim, config.num_index_operations, null);
        std.debug.print("{}\n", .{insertion_result});

        // Search benchmarks
        for (config.k_values) |k| {
            const search_result = try shared.runSearchBenchmark(allocator, &hnsw, dim, k, config.num_search_operations, null);
            std.debug.print("{}\n", .{search_result});
        }

        std.debug.print("\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = shared.BenchmarkConfig{
        .dimensions = &[_]usize{ 128, 512, 768, 1024 },
        .k_values = &[_]usize{ 10, 25, 50 },
        .index_size = 100000,
        .num_index_operations = 10000,
        .num_search_operations = 3000,
    };

    try runSingleThreadedBenchmarks(allocator, config);
}
