const std = @import("std");
const cosine = @import("cosine.zig");
const euclidean = @import("euclidean.zig");

pub const DistanceFunction = *const fn (a: []const f32, b: []const f32) f32;

pub const DistanceMetric = enum {
    Cosine,
    Euclidean,
};

pub fn getDistanceFunction(metric: DistanceMetric) DistanceFunction {
    return switch (metric) {
        .Cosine => cosine.distance,
        .Euclidean => euclidean.distance,
    };
}

pub fn validateVectors(a: []const f32, b: []const f32) !void {
    if (a.len != b.len) {
        return error.DimensionMismatch;
    }
    if (a.len == 0) {
        return error.EmptyVector;
    }
}
