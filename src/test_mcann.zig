const std = @import("std");
const testing = std.testing;
const MCANN = @import("mcann.zig").MCANN;
// Add this at the top of your test file
pub fn main() !void {
    // Set the log level to debug
    std.log.default_level = .debug;
    // Set up a logger that prints to stderr
    std.log.default_handler = std.log.defaultLog;

    // Run the tests
    try std.testing.run();
}

fn randomPoint(comptime dim: comptime_int) [dim]f32 {
    var point: [dim]f32 = undefined;
    for (&point) |*v| {
        v.* = std.crypto.random.float(f32);
    }
    return point;
}

// Helper function to calculate Euclidean distance
fn euclideanDistance(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0;
    for (a, b) |va, vb| {
        const diff = va - vb;
        sum += diff * diff;
    }
    return std.math.sqrt(sum);
}

test "MCANN - Basic Functionality" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 1024 * 1024); // 1MB memory budget
    defer mcann.deinit();

    try mcann.createCollection("test_collection");

    try mcann.insert("test_collection", .{ 1, 2, 3 });
    try mcann.insert("test_collection", .{ 4, 5, 6 });
    try mcann.insert("test_collection", .{ 7, 8, 9 });

    const query = [_]f32{ 3, 4, 5 };
    const results = try mcann.search("test_collection", query, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expect(euclideanDistance(&query, &results[0]) <= euclideanDistance(&query, &results[1]));
}

test "MCANN - Empty Collection" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 1024 * 1024);
    defer mcann.deinit();

    try mcann.createCollection("empty_collection");

    const query = [_]f32{ 1, 2, 3 };
    const results = try mcann.search("empty_collection", query, 5);
    defer allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "MCANN - Single Point" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 1024 * 1024);
    defer mcann.deinit();

    try mcann.createCollection("single_point");

    const point = [_]f32{ 1, 2, 3 };
    try mcann.insert("single_point", point);

    const results = try mcann.search("single_point", point, 1);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(point, results[0]);
}

test "MCANN - Multiple Collections" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 1024 * 1024);
    defer mcann.deinit();

    try mcann.createCollection("collection1");
    try mcann.createCollection("collection2");

    try mcann.insert("collection1", .{ 1, 2, 3 });
    try mcann.insert("collection2", .{ 4, 5, 6 });

    const query = [_]f32{ 1, 2, 3 };
    const results1 = try mcann.search("collection1", query, 1);
    defer allocator.free(results1);
    const results2 = try mcann.search("collection2", query, 1);
    defer allocator.free(results2);

    try testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3 }, &results1[0]);
    try testing.expectEqualSlices(f32, &[_]f32{ 4, 5, 6 }, &results2[0]);
}

test "MCANN - Large Dataset" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 128).init(allocator, 100 * 1024 * 1024); // 100MB memory budget
    defer mcann.deinit();

    try mcann.createCollection("large_collection");

    const num_points = 10000;
    const dim = 128;

    var points: [num_points][dim]f32 = undefined;

    // Generate all points at once
    for (&points) |*point| {
        point.* = randomPoint(dim);
    }

    // Insert points
    for (points) |point| {
        try mcann.insert("large_collection", point);
    } // Search for nearest neighbors

    const query = points[std.crypto.random.intRangeLessThan(usize, 0, num_points)];

    const k = 10;
    const results = try mcann.search("large_collection", query, k);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, k), results.len);

    // Check if results are sorted by distance
    var last_dist: f32 = 0;
    for (results) |result| {
        const dist = euclideanDistance(&query, &result);
        try testing.expect(dist >= last_dist);
        last_dist = dist;
    }

    // Count the number of cluster files
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var file_count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "large_collection_cluster_") and std.mem.endsWith(u8, entry.name, ".bin")) {
            file_count += 1;
        }
    }

    std.log.info("Number of cluster files created: {}", .{file_count});
    try testing.expect(file_count < 1000); // Adjust this number based on what you consider reasonable
}

test "MCANN - Cluster Splitting" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 1024 * 1024);
    defer mcann.deinit();

    try mcann.createCollection("split_test");

    // Insert more points than the optimal cluster size
    const num_points = 2000; // This should be larger than ClusterManager.optimal_cluster_size
    for (0..num_points) |i| {
        const point = [_]f32{ @floatFromInt(i), @floatFromInt(i), @floatFromInt(i) };
        try mcann.insert("split_test", point);
    }

    // Search for a point
    const query = [_]f32{ 1000, 1000, 1000 };
    const results = try mcann.search("split_test", query, 10);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 10), results.len);
    // The closest point should be very close to the query
    try testing.expect(euclideanDistance(&query, &results[0]) < 1.0);
}

test "MCANN - Memory Management" {
    const allocator = testing.allocator;
    // Set a small memory budget to force memory management
    var mcann = MCANN(f32, 3).init(allocator, 10 * 1024); // 10KB memory budget
    defer mcann.deinit();

    try mcann.createCollection("memory_test");

    // Insert a large number of points
    const num_points = 1000;
    for (0..num_points) |i| {
        const point = [_]f32{ @floatFromInt(i), @floatFromInt(i), @floatFromInt(i) };
        try mcann.insert("memory_test", point);
    }

    // Perform a search to trigger memory management
    const query = [_]f32{ 500, 500, 500 };
    const results = try mcann.search("memory_test", query, 10);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 10), results.len);
}

test "MCANN - Consistency" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 128).init(allocator, 10 * 1024 * 1024);
    defer mcann.deinit();

    try mcann.createCollection("consistency_test");

    const num_points = 1000;

    // Insert points
    for (0..num_points) |_| {
        const point = randomPoint(128);
        try mcann.insert("consistency_test", point);
    }

    // Perform multiple searches with the same query
    const query = randomPoint(128);

    const num_searches = 10;
    const k = 10;
    var first_result: [k][128]f32 = undefined;

    for (0..num_searches) |i| {
        const results = try mcann.search("consistency_test", query, k);
        defer allocator.free(results);

        if (i == 0) {
            // Store the first result for comparison
            @memcpy(&first_result, results);
        } else {
            // Compare with the first result
            for (results, 0..results.len) |result, j| {
                try testing.expectEqualSlices(f32, &first_result[j], &result);
            }
        }
    }
}

test "MCANN - Error Handling" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 1024 * 1024);
    defer mcann.deinit();

    // Test creating a collection that already exists
    try mcann.createCollection("error_test");
    try testing.expectError(error.CollectionAlreadyExists, mcann.createCollection("error_test"));

    // Test inserting into a non-existent collection
    try testing.expectError(error.CollectionNotFound, mcann.insert("non_existent", .{ 1, 2, 3 }));

    // Test searching in a non-existent collection
    try testing.expectError(error.CollectionNotFound, mcann.search("non_existent", .{ 1, 2, 3 }, 1));
}
