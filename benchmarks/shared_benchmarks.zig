const std = @import("std");
const HNSW = @import("zvdb").HNSW;
const csv_utils = @import("csv_utils.zig");

pub const BenchmarkResult = struct {
    operation: []const u8,
    dimensions: usize,
    k: ?usize,
    num_threads: ?usize,
    total_time_ns: u64,
    operations_performed: usize,
    operations_per_second: f64,

    pub fn format(
        self: BenchmarkResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s} Benchmark:\n", .{self.operation});
        try writer.print("  Dimensions: {d}\n", .{self.dimensions});
        if (self.k) |k_value| {
            try writer.print("  k: {d}\n", .{k_value});
        }
        if (self.num_threads) |threads| {
            try writer.print("  Threads: {d}\n", .{threads});
        }
        try writer.print("  Total time: {d:.2} seconds\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1e9});
        try writer.print("  Operations performed: {d}\n", .{self.operations_performed});
        try writer.print("  {s} per second: {d:.2}\n", .{ self.operation, self.operations_per_second });
    }

    pub fn toCsv(self: BenchmarkResult, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s},{d},{d},{d},{d},{d},{d:.2}", .{
            self.operation,
            self.dimensions,
            self.k orelse 0,
            self.num_threads orelse 1,
            self.total_time_ns,
            self.operations_performed,
            self.operations_per_second,
        });
    }
};

pub fn randomPoint(allocator: std.mem.Allocator, dim: usize, rng: std.Random) ![]f32 {
    const point = try allocator.alloc(f32, dim);
    for (point) |*v| {
        v.* = rng.float(f32);
    }
    return point;
}

pub fn buildIndex(allocator: std.mem.Allocator, dim: usize, num_points: usize) !HNSW(f32) {
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    errdefer hnsw.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    for (0..num_points) |_| {
        const point = try randomPoint(allocator, dim, rng);
        defer allocator.free(point);
        try hnsw.insert(point);
    }

    return hnsw;
}

pub fn runInsertionBenchmark(allocator: std.mem.Allocator, hnsw: *HNSW(f32), dim: usize, num_operations: usize, num_threads: ?usize) !BenchmarkResult {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const start_time = std.time.nanoTimestamp();

    for (0..num_operations) |_| {
        const point = try randomPoint(allocator, dim, rng);
        defer allocator.free(point);
        try hnsw.insert(point);
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end_time - start_time);
    const operations_per_second = @as(f64, @floatFromInt(num_operations)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    return BenchmarkResult{
        .operation = "Insertion",
        .dimensions = dim,
        .k = null,
        .num_threads = num_threads,
        .total_time_ns = elapsed_ns,
        .operations_performed = num_operations,
        .operations_per_second = operations_per_second,
    };
}

pub fn runSearchBenchmark(allocator: std.mem.Allocator, hnsw: *HNSW(f32), dim: usize, k: usize, num_operations: usize, num_threads: ?usize) !BenchmarkResult {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const start_time = std.time.nanoTimestamp();

    for (0..num_operations) |_| {
        const query = try randomPoint(allocator, dim, rng);
        defer allocator.free(query);
        const results = try hnsw.search(query, k);
        allocator.free(results);
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end_time - start_time);
    const operations_per_second = @as(f64, @floatFromInt(num_operations)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    return BenchmarkResult{
        .operation = "Search",
        .dimensions = dim,
        .k = k,
        .num_threads = num_threads,
        .total_time_ns = elapsed_ns,
        .operations_performed = num_operations,
        .operations_per_second = operations_per_second,
    };
}

pub const BenchmarkConfig = struct {
    dimensions: []const usize,
    k_values: []const usize,
    index_size: usize,
    num_index_operations: usize,
    num_search_operations: usize,
};

pub fn appendResultToCsv(allocator: std.mem.Allocator, result: BenchmarkResult, file_path: []const u8) !void {
    try csv_utils.ensureCsvHeaderExists(file_path);

    const csv_line = try result.toCsv(allocator);
    defer allocator.free(csv_line);

    try csv_utils.appendToCsv(file_path, csv_line);
}
