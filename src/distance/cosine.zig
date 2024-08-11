const std = @import("std");
const math = std.math;

pub fn distance(a: []const f32, b: []const f32) f32 {
    var dot_product: f32 = 0;
    var magnitude_a: f32 = 0;
    var magnitude_b: f32 = 0;

    for (a, 0..) |_, i| {
        dot_product += a[i] * b[i];
        magnitude_a += a[i] * a[i];
        magnitude_b += b[i] * b[i];
    }

    magnitude_a = math.sqrt(magnitude_a);
    magnitude_b = math.sqrt(magnitude_b);

    if (magnitude_a == 0 or magnitude_b == 0) {
        return 1; // Maximum distance for zero vectors
    }

    const similarity = dot_product / (magnitude_a * magnitude_b);
    return 1 - similarity; // Convert similarity to distance
}
