const std = @import("std");
const testing = std.testing;
const MCANN = @import("mcann.zig").MCANN;

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
    var mcann = MCANN(f32, 3).init(allocator, 5, 10);
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
    var mcann = MCANN(f32, 3).init(allocator, 5, 10);
    defer mcann.deinit();

    try mcann.createCollection("empty_collection");

    const query = [_]f32{ 1, 2, 3 };
    const results = mcann.search("empty_collection", query, 5);
    try testing.expectError(error.NoTopClustersFound, results);
}

test "MCANN - Single Point" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 5, 10);
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
    var mcann = MCANN(f32, 3).init(allocator, 5, 10);
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
    var mcann = MCANN(f32, 128).init(allocator, 100, 10000); // Increased max_top_clusters to 100
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
    }

    // Search for nearest neighbors
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
}

test "MCANN - Edge Cases" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 3).init(allocator, 2, 1000); // Increase max_sub_clusters to 1000
    defer mcann.deinit();

    try mcann.createCollection("edge_cases");

    // Test inserting up to the limit
    try mcann.insert("edge_cases", .{ 1, 2, 3 });
    try mcann.insert("edge_cases", .{ 4, 5, 6 });
    try mcann.insert("edge_cases", .{ 7, 8, 9 });
    try mcann.insert("edge_cases", .{ 10, 11, 12 });

    // This should now succeed due to file growth
    try mcann.insert("edge_cases", .{ 13, 14, 15 });

    // Test searching with k larger than number of points
    const query = [_]f32{ 1, 2, 3 };
    const results = try mcann.search("edge_cases", query, 10);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 5), results.len);
}

test "MCANN - Consistency" {
    const allocator = testing.allocator;
    var mcann = MCANN(f32, 128).init(allocator, 10, 1000);
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
