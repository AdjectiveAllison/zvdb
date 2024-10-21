const std = @import("std");
const testing = std.testing;
const HMMIS = @import("hmmis.zig").HMMIS;

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

test "HMMIS - Basic Functionality" {
    const allocator = testing.allocator;
    var hmmis = try HMMIS(f32, 3).init(allocator, .{});
    defer hmmis.deinit();

    // Insert some points
    try hmmis.insert([3]f32{ 1, 2, 3 });
    try hmmis.insert([3]f32{ 4, 5, 6 });
    try hmmis.insert([3]f32{ 7, 8, 9 });

    // Search for nearest neighbors
    const query = [3]f32{ 3, 4, 5 };
    const results = try hmmis.search(query, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expect(euclideanDistance(&query, &results[0].point) <= euclideanDistance(&query, &results[1].point));
}
