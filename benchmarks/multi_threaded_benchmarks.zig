const std = @import("std");
const shared = @import("shared_benchmarks.zig");
const csv_utils = @import("csv_utils.zig");

pub fn runMultiThreadedBenchmarks(allocator: std.mem.Allocator, config: shared.BenchmarkConfig, csv_file_path: []const u8) !void {
    std.debug.print("Running Multi-Threaded Benchmarks\n", .{});
    std.debug.print("================================\n\n", .{});

    const thread_counts = [_]usize{ 2, 4, 8 };

    for (config.dimensions) |dim| {
        for (thread_counts) |thread_count| {
            // Build the index
            var hnsw = try shared.buildIndex(allocator, dim, config.index_size);
            defer hnsw.deinit();

            // Insertion benchmark
            const insertion_result = try shared.runInsertionBenchmark(allocator, &hnsw, dim, config.num_index_operations, thread_count);
            std.debug.print("{}\n", .{insertion_result});
            try shared.appendResultToCsv(allocator, insertion_result, csv_file_path);

            // Search benchmarks
            for (config.k_values) |k| {
                const search_result = try shared.runSearchBenchmark(allocator, &hnsw, dim, k, config.num_search_operations, thread_count);
                std.debug.print("{}\n", .{search_result});
                try shared.appendResultToCsv(allocator, search_result, csv_file_path);
            }

            std.debug.print("\n", .{});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const git_commit = try csv_utils.getGitCommit(allocator);
    defer allocator.free(git_commit);

    const csv_file_path = try csv_utils.getCsvFilePath(allocator, git_commit);
    defer allocator.free(csv_file_path);

    const config = shared.BenchmarkConfig{
        .dimensions = &[_]usize{ 128, 512, 768, 1024 },
        .k_values = &[_]usize{ 10, 25, 50 },
        .index_size = 100000,
        .num_index_operations = 10000,
        .num_search_operations = 3000,
    };

    try runMultiThreadedBenchmarks(allocator, config, csv_file_path);
}
