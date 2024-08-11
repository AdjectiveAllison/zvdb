const std = @import("std");
const math = std.math;

pub fn distance(a: []const f32, b: []const f32) f32 {
    var sum_of_squares: f32 = 0;

    for (a, 0..) |_, i| {
        const diff = a[i] - b[i];
        sum_of_squares += diff * diff;
    }

    return math.sqrt(sum_of_squares);
}
