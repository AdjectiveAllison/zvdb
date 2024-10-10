const std = @import("std");
const HNSW = @import("zvdb").HNSW;
const MCANN = @import("zvdb").MCANN;

const BenchmarkResult = struct {
    operation: []const u8,
    algorithm: []const u8,
    num_points: usize,
    dimensions: usize,
    total_time_ns: u64,
    operations_per_second: f64,

    pub fn format(
        self: BenchmarkResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s} Benchmark ({s}):\n", .{ self.operation, self.algorithm });
        try writer.print("  Points: {d}\n", .{self.num_points});
        try writer.print("  Dimensions: {d}\n", .{self.dimensions});
        try writer.print("  Total time: {d:.2} seconds\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1e9});
        try writer.print("  {s} per second: {d:.2}\n", .{ self.operation, self.operations_per_second });
    }
};

fn randomPoint(allocator: std.mem.Allocator, dim: usize) ![]f32 {
    const point = try allocator.alloc(f32, dim);
    for (point) |*v| {
        v.* = std.crypto.random.float(f32);
    }
    return point;
}

fn runHNSWBenchmark(allocator: std.mem.Allocator, num_points: usize, comptime dim: usize, k: usize) !void {
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insertion benchmark
    {
        var timer = try std.time.Timer.start();
        const start = timer.lap();

        for (0..num_points) |_| {
            const point = try randomPoint(allocator, dim);
            defer allocator.free(point);
            try hnsw.insert(point);
        }

        const end = timer.lap();
        const elapsed_ns = end - start;
        const points_per_second = @as(f64, @floatFromInt(num_points)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

        const result = BenchmarkResult{
            .operation = "Insertion",
            .algorithm = "HNSW",
            .num_points = num_points,
            .dimensions = dim,
            .total_time_ns = elapsed_ns,
            .operations_per_second = points_per_second,
        };
        std.debug.print("{}\n", .{result});
    }

    // Search benchmark
    {
        var timer = try std.time.Timer.start();
        const start = timer.lap();

        for (0..num_points) |_| {
            const query = try randomPoint(allocator, dim);
            defer allocator.free(query);
            const results = try hnsw.search(query, k);
            allocator.free(results);
        }

        const end = timer.lap();
        const elapsed_ns = end - start;
        const queries_per_second = @as(f64, @floatFromInt(num_points)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

        const result = BenchmarkResult{
            .operation = "Search",
            .algorithm = "HNSW",
            .num_points = num_points,
            .dimensions = dim,
            .total_time_ns = elapsed_ns,
            .operations_per_second = queries_per_second,
        };
        std.debug.print("{}\n", .{result});
    }
}

fn runMCANNBenchmark(allocator: std.mem.Allocator, num_points: usize, comptime dim: usize, k: usize) !void {
    var mcann = MCANN(f32, dim).init(allocator, 100, 100000);
    defer mcann.deinit();

    try mcann.createCollection("benchmark_collection");

    // Insertion benchmark
    {
        var timer = try std.time.Timer.start();
        const start = timer.lap();

        for (0..num_points) |_| {
            var point: [dim]f32 = undefined;
            for (&point) |*v| {
                v.* = std.crypto.random.float(f32);
            }
            try mcann.insert("benchmark_collection", point);
        }

        const end = timer.lap();
        const elapsed_ns = end - start;
        const points_per_second = @as(f64, @floatFromInt(num_points)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

        const result = BenchmarkResult{
            .operation = "Insertion",
            .algorithm = "MCANN",
            .num_points = num_points,
            .dimensions = dim,
            .total_time_ns = elapsed_ns,
            .operations_per_second = points_per_second,
        };
        std.debug.print("{}\n", .{result});
    }

    // Search benchmark
    {
        var timer = try std.time.Timer.start();
        const start = timer.lap();

        for (0..num_points) |_| {
            var query: [dim]f32 = undefined;
            for (&query) |*v| {
                v.* = std.crypto.random.float(f32);
            }
            const results = try mcann.search("benchmark_collection", query, k);
            allocator.free(results);
        }

        const end = timer.lap();
        const elapsed_ns = end - start;
        const queries_per_second = @as(f64, @floatFromInt(num_points)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

        const result = BenchmarkResult{
            .operation = "Search",
            .algorithm = "MCANN",
            .num_points = num_points,
            .dimensions = dim,
            .total_time_ns = elapsed_ns,
            .operations_per_second = queries_per_second,
        };
        std.debug.print("{}\n", .{result});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const num_points = 100000;
    const dim = 128;
    const k = 10;

    std.debug.print("Running HNSW Benchmark\n", .{});
    std.debug.print("=====================\n\n", .{});
    try runHNSWBenchmark(allocator, num_points, dim, k);

    std.debug.print("\nRunning MCANN Benchmark\n", .{});
    std.debug.print("=====================\n\n", .{});
    try runMCANNBenchmark(allocator, num_points, dim, k);
}
