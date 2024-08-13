const std = @import("std");
const testing = std.testing;
const HNSW = @import("hnsw.zig").HNSW;
const HNSWConfig = @import("hnsw.zig").HNSWConfig;

// Helper function to create a random point
fn randomPoint(allocator: std.mem.Allocator, dim: usize) ![]f32 {
    const point = try allocator.alloc(f32, dim);
    for (point) |*v| {
        v.* = std.crypto.random.float(f32);
    }
    return point;
}

// Helper function to calculate Euclidean distance
fn euclideanDistance(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0;
    for (a, 0..) |_, i| {
        const diff = a[i] - b[i];
        sum += diff * diff;
    }
    return std.math.sqrt(sum);
}

test "HNSW - Basic Functionality" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    // Insert some points
    try hnsw.insert(&[_]f32{ 1, 2, 3 });
    try hnsw.insert(&[_]f32{ 4, 5, 6 });
    try hnsw.insert(&[_]f32{ 7, 8, 9 });

    // Search for nearest neighbors
    const query = &[_]f32{ 3, 4, 5 };
    const results = try hnsw.search(query, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expect(euclideanDistance(query, results[0].point) <= euclideanDistance(query, results[1].point));
}

test "HNSW - Empty Index" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    const query = &[_]f32{ 1, 2, 3 };
    const results = try hnsw.search(query, 5);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 0), results.len);
}

test "HNSW - Single Point" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    const point = &[_]f32{ 1, 2, 3 };
    try hnsw.insert(point);

    const results = try hnsw.search(point, 1);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualSlices(f32, point, results[0].point);
}

test "HNSW - Large Dataset" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    const num_points = 10000;
    const dim = 128;

    // Insert many points
    for (0..num_points) |_| {
        const point = try randomPoint(allocator, dim);
        defer allocator.free(point);
        try hnsw.insert(point);
    }

    // Search for nearest neighbors
    const query = try randomPoint(allocator, dim);
    defer allocator.free(query);

    const k = 10;
    const results = try hnsw.search(query, k);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, k), results.len);

    // Check if results are sorted by distance
    var last_dist: f32 = 0;
    for (results) |result| {
        const dist = euclideanDistance(query, result.point);
        try testing.expect(dist >= last_dist);
        last_dist = dist;
    }
}

test "HNSW - Edge Cases" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    // Insert duplicate points
    const point = &[_]f32{ 1, 2, 3 };
    try hnsw.insert(point);
    try hnsw.insert(point);

    const results = try hnsw.search(point, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualSlices(f32, point, results[0].point);
    try testing.expectEqualSlices(f32, point, results[1].point);

    // Search with k larger than number of points
    const large_k_results = try hnsw.search(point, 100);
    defer allocator.free(large_k_results);

    try testing.expectEqual(@as(usize, 2), large_k_results.len);
}

test "HNSW - Memory Leaks" {
    var hnsw: HNSW(f32, .Euclidean) = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
        hnsw = HNSW(f32, .Euclidean).init(allocator, config);

        const num_points = 1000;
        const dim = 64;

        for (0..num_points) |_| {
            const point = try randomPoint(allocator, dim);
            try hnsw.insert(point);
            // Intentionally not freeing 'point' to test if HNSW properly manages memory
        }

        const query = try randomPoint(allocator, dim);
        const results = try hnsw.search(query, 10);
        _ = results;
        // Intentionally not freeing 'results' or 'query'
    }
    // The ArenaAllocator will detect any memory leaks when it's deinitialized
}

test "HNSW - Concurrent Access" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    const num_threads = 8;
    const points_per_thread = 1000;
    const dim = 128;

    const ThreadContext = struct {
        hnsw: *HNSW(f32, .Euclidean),
        allocator: std.mem.Allocator,
    };

    const thread_fn = struct {
        fn func(ctx: *const ThreadContext) !void {
            for (0..points_per_thread) |_| {
                const point = try ctx.allocator.alloc(f32, dim);
                defer ctx.allocator.free(point);
                for (point) |*v| {
                    v.* = std.crypto.random.float(f32);
                }
                try ctx.hnsw.insert(point);
            }
        }
    }.func;

    var threads: [num_threads]std.Thread = undefined;
    var contexts: [num_threads]ThreadContext = undefined;

    for (&threads, 0..) |*thread, i| {
        contexts[i] = .{
            .hnsw = &hnsw,
            .allocator = allocator,
        };
        thread.* = try std.Thread.spawn(.{}, thread_fn, .{&contexts[i]});
    }

    for (&threads) |*thread| {
        thread.join();
    }

    // Verify that all points were inserted
    const expected_count = num_threads * points_per_thread;
    const actual_count = hnsw.nodes.count();
    try testing.expectEqual(expected_count, actual_count);

    // Test search after concurrent insertion
    const query = try randomPoint(allocator, dim);
    defer allocator.free(query);

    const results = try hnsw.search(query, 10);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 10), results.len);
}

test "HNSW - Stress Test" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    const num_points = 100000;
    const dim = 128;
    const num_queries = 100;

    // Insert many points
    for (0..num_points) |_| {
        const point = try randomPoint(allocator, dim);
        defer allocator.free(point);
        try hnsw.insert(point);
    }

    // Perform multiple searches
    for (0..num_queries) |_| {
        const query = try randomPoint(allocator, dim);
        defer allocator.free(query);

        const results = try hnsw.search(query, 10);
        defer allocator.free(results);

        try testing.expectEqual(@as(usize, 10), results.len);
    }
}

test "HNSW - Different Data Types" {
    const allocator = testing.allocator;

    // Test with integer type
    {
        const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
        var hnsw_int = HNSW(i32, .Euclidean).init(allocator, config);
        defer hnsw_int.deinit();

        try hnsw_int.insert(&[_]i32{ 1, 2, 3 });
        try hnsw_int.insert(&[_]i32{ 4, 5, 6 });
        try hnsw_int.insert(&[_]i32{ 7, 8, 9 });

        const query_int = &[_]i32{ 3, 4, 5 };
        const results_int = try hnsw_int.search(query_int, 2);
        defer allocator.free(results_int);

        try testing.expectEqual(@as(usize, 2), results_int.len);
    }

    // Test with float64 type
    {
        const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
        var hnsw_f64 = HNSW(f64, .Euclidean).init(allocator, config);
        defer hnsw_f64.deinit();

        try hnsw_f64.insert(&[_]f64{ 1.1, 2.2, 3.3 });
        try hnsw_f64.insert(&[_]f64{ 4.4, 5.5, 6.6 });
        try hnsw_f64.insert(&[_]f64{ 7.7, 8.8, 9.9 });

        const query_f64 = &[_]f64{ 3.3, 4.4, 5.5 };
        const results_f64 = try hnsw_f64.search(query_f64, 2);
        defer allocator.free(results_f64);

        try testing.expectEqual(@as(usize, 2), results_f64.len);
    }
}

test "HNSW - Consistency" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    const num_points = 10000;
    const dim = 128;

    // Insert points
    for (0..num_points) |_| {
        const point = try randomPoint(allocator, dim);
        defer allocator.free(point);
        try hnsw.insert(point);
    }

    // Perform multiple searches with the same query
    const query = try randomPoint(allocator, dim);
    defer allocator.free(query);

    const num_searches = 10;
    const k = 10;
    var first_result = try allocator.alloc(f32, k * dim);
    defer allocator.free(first_result);

    for (0..num_searches) |i| {
        const results = try hnsw.search(query, k);
        defer allocator.free(results);

        if (i == 0) {
            // Store the first result for comparison
            for (results, 0..) |result, j| {
                @memcpy(first_result[j * dim .. (j + 1) * dim], result.point);
            }
        } else {
            // Compare with the first result
            for (results, 0..) |result, j| {
                const start = j * dim;
                const end = (j + 1) * dim;
                try testing.expectEqualSlices(f32, first_result[start..end], result.point);
            }
        }
    }
}

// New test to ensure Euclidean distance is functioning correctly
test "HNSW - Euclidean Distance Functionality" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Euclidean).init(allocator, config);
    defer hnsw.deinit();

    // Insert some points
    try hnsw.insert(&[_]f32{ 0, 0, 0 });    // Point a
    try hnsw.insert(&[_]f32{ 1, 1, 1 });    // Point b
    try hnsw.insert(&[_]f32{ 2, 2, 2 });    // Point c
    try hnsw.insert(&[_]f32{ -1, -1, -1 }); // Point d
    try hnsw.insert(&[_]f32{ 3, 0, 0 });    // Point e
    try hnsw.insert(&[_]f32{ 0, 4, 0 });    // Point f

    // Query point
    const query = &[_]f32{ 1, 0, 0 };

    const results = try hnsw.search(query, 6);
    defer allocator.free(results);

    // Expected order: a, b, e, d, c, f
    try testing.expectEqual(@as(usize, 6), results.len);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0, 0 }, results[0].point);    // a (Euclidean distance = 1)
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1, 1 }, results[1].point);    // b (Euclidean distance = √2 ≈ 1.414)
    try testing.expectEqualSlices(f32, &[_]f32{ 3, 0, 0 }, results[2].point);    // e (Euclidean distance = 2)
    try testing.expectEqualSlices(f32, &[_]f32{ -1, -1, -1 }, results[3].point); // d (Euclidean distance = √6 ≈ 2.449)
    try testing.expectEqualSlices(f32, &[_]f32{ 2, 2, 2 }, results[4].point);    // c (Euclidean distance = √5 ≈ 2.236)
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 4, 0 }, results[5].point);    // f (Euclidean distance = √17 ≈ 4.123)

    // Check approximate symmetry property
    const point_a = &[_]f32{ 2, 2, 2 };
    const point_b = &[_]f32{ -1, -1, -1 };
    const k = 6;  // Number of nearest neighbors to retrieve

    const results_a = try hnsw.search(point_a, k);
    defer allocator.free(results_a);
    const results_b = try hnsw.search(point_b, k);
    defer allocator.free(results_b);

    // Check if point_b is in the k-nearest neighbors of point_a
    var found_b_in_a = false;
    for (results_a) |result| {
        if (std.mem.eql(f32, result.point, point_b)) {
            found_b_in_a = true;
            break;
        }
    }

    // Check if point_a is in the k-nearest neighbors of point_b
    var found_a_in_b = false;
    for (results_b) |result| {
        if (std.mem.eql(f32, result.point, point_a)) {
            found_a_in_b = true;
            break;
        }
    }

    // Both points should be in each other's k-nearest neighbors
    try testing.expect(found_b_in_a);
    try testing.expect(found_a_in_b);
}

// New test to ensure cosine distance is functioning correctly
test "HNSW - Cosine Distance Functionality" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Cosine).init(allocator, config);
    defer hnsw.deinit();

    // Insert some vectors
    try hnsw.insert(&[_]f32{ 1, 0, 0 });     // Vector a
    try hnsw.insert(&[_]f32{ 0, 1, 0 });     // Vector b
    try hnsw.insert(&[_]f32{ 1, 1, 0 });     // Vector c
    try hnsw.insert(&[_]f32{ -1, 0, 0 });    // Vector d
    try hnsw.insert(&[_]f32{ 0.5, 0.5, 0 }); // Vector e

    // Query vector
    const query = &[_]f32{ 1, 1, 0 };

    const results = try hnsw.search(query, 5);
    defer allocator.free(results);

    // Expected order: c, e, a, b, d
    try testing.expectEqual(@as(usize, 5), results.len);
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1, 0 }, results[0].point);     // c (cos similarity = 1)
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5, 0 }, results[1].point); // e (cos similarity = 1)
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 0, 0 }, results[2].point);     // a (cos similarity = 1/√2)
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 1, 0 }, results[3].point);     // b (cos similarity = 1/√2)
    try testing.expectEqualSlices(f32, &[_]f32{ -1, 0, 0 }, results[4].point);    // d (cos similarity = -1/√2)
}

// New test to ensure Manhattan distance is functioning correctly
test "HNSW - Manhattan Distance Functionality" {
    const allocator = testing.allocator;
    const config = HNSWConfig{ .m = 16, .ef_construction = 200 };
    var hnsw = HNSW(f32, .Manhattan).init(allocator, config);
    defer hnsw.deinit();

    // Insert some points
    try hnsw.insert(&[_]f32{ 0, 0, 0 });   // Point a
    try hnsw.insert(&[_]f32{ 1, 1, 1 });   // Point b
    try hnsw.insert(&[_]f32{ 2, 2, 2 });   // Point c
    try hnsw.insert(&[_]f32{ -1, -1, -1 }); // Point d
    try hnsw.insert(&[_]f32{ 3, 0, 0 });   // Point e

    // Query point
    const query = &[_]f32{ 1, 0, 0 };

    const results = try hnsw.search(query, 5);
    defer allocator.free(results);

    // Expected order: a, b, e, d, c
    try testing.expectEqual(@as(usize, 5), results.len);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0, 0 }, results[0].point);    // a (Manhattan distance = 1)
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1, 1 }, results[1].point);    // b (Manhattan distance = 2)
    try testing.expectEqualSlices(f32, &[_]f32{ 3, 0, 0 }, results[2].point);    // e (Manhattan distance = 2)
    try testing.expectEqualSlices(f32, &[_]f32{ -1, -1, -1 }, results[3].point); // d (Manhattan distance = 4)
    try testing.expectEqualSlices(f32, &[_]f32{ 2, 2, 2 }, results[4].point);    // c (Manhattan distance = 5)
}
