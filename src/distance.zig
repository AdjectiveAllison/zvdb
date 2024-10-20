const std = @import("std");

pub const DistanceMetric = enum {
    Euclidean,
    Manhattan,

    pub fn getName(self: DistanceMetric) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(name: []const u8) !DistanceMetric {
        return std.meta.stringToEnum(DistanceMetric, name) orelse error.InvalidMetricName;
    }
};

pub fn DistanceFunctions(comptime T: type, comptime size: comptime_int) type {
    return struct {
        pub const DistanceFunction = fn (a: [size]T, b: [size]T) T;

        const Vec = @Vector(size, T);

        pub fn euclideanDistance(a: [size]T, b: [size]T) T {
            const va = @as(Vec, a);
            const vb = @as(Vec, b);
            const diff = va - vb;
            const squared = diff * diff;
            const sum = @reduce(.Add, squared);

            return switch (@typeInfo(T)) {
                .float => @sqrt(sum),
                .int => {
                    const IntType = @Type(.{ .Int = .{
                        .signedness = .unsigned,
                        .bits = @max(@typeInfo(T).Int.bits * 2, 32),
                    } });
                    const large_sum = @as(IntType, @intCast(sum));
                    const float_result = @sqrt(@as(f64, @floatFromInt(large_sum)));
                    return @as(T, @intFromFloat(@floor(float_result)));
                },
                else => @compileError("Unsupported type for Euclidean distance"),
            };
        }

        pub fn manhattanDistance(a: [size]T, b: [size]T) T {
            const va = @as(Vec, a);
            const vb = @as(Vec, b);
            const diff = va - vb;
            const abs_diff = @abs(diff);
            return @reduce(.Add, abs_diff);
        }

        pub fn getDistanceFunction(metric: DistanceMetric) DistanceFunction {
            return switch (metric) {
                .Euclidean => euclideanDistance,
                .Manhattan => manhattanDistance,
            };
        }
    };
}
