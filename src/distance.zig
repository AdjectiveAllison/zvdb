const std = @import("std");
const builtin = @import("builtin");

pub const DistanceMetric = enum {
    Euclidean,
    Manhattan,
    Cosine,

    pub fn getName(self: DistanceMetric) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(name: []const u8) !DistanceMetric {
        return std.meta.stringToEnum(DistanceMetric, name) orelse error.InvalidMetricName;
    }

    pub fn supportsType(self: DistanceMetric, comptime T: type) bool {
        return switch (self) {
            .Euclidean, .Manhattan => switch (@typeInfo(T)) {
                .Int, .Float => true,
                else => false,
            },
            .Cosine => switch (@typeInfo(T)) {
                .Float => true,
                else => false,
            },
        };
    }
};

pub fn DistanceFunctions(comptime T: type) type {
    return struct {
        pub const DistanceFunction = fn (a: []const T, b: []const T) T;

        const SIMD_WIDTH = switch (@typeInfo(T)) {
            .Float => |info| switch (info.bits) {
                32 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx)) 8 else 4,
                64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx)) 4 else 2,
                else => 1,
            },
            .Int => |info| switch (info.bits) {
                8 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 32 else 16,
                16 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 16 else 8,
                32 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 8 else 4,
                64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 4 else 2,
                else => 1,
            },
            else => 1,
        };

        pub fn getFunction(metric: DistanceMetric) DistanceFunction {
            return switch (metric) {
                .Euclidean => euclideanDistance,
                .Manhattan => manhattanDistance,
                .Cosine => switch (@typeInfo(T)) {
                    .Float => cosineDistance,
                    else => @compileError("Cosine distance is only supported for floating-point types"),
                },
            };
        }

        pub fn euclideanDistance(a: []const T, b: []const T) T {
            checkDimensions(a, b);
            const sum_of_squares = if (comptime canUseSIMD(T))
                simdSumOfSquaredDifferences(a, b)
            else
                scalarSumOfSquaredDifferences(a, b);

            return switch (@typeInfo(T)) {
                .Float => @sqrt(sum_of_squares),
                .Int => {
                    const IntType = @Type(.{ .Int = .{
                        .signedness = .unsigned,
                        .bits = @max(@bitSizeOf(T) * 2, 32),
                    } });
                    const large_sum = @as(IntType, @intCast(sum_of_squares));
                    const float_result = @sqrt(@as(f64, @floatFromInt(large_sum)));
                    return @as(T, @intFromFloat(@floor(float_result)));
                },
                else => @compileError("Unsupported type for Euclidean distance"),
            };
        }

        fn scalarSumOfSquaredDifferences(a: []const T, b: []const T) T {
            var sum: T = 0;
            for (a, b) |ai, bi| {
                const diff = switch (@typeInfo(T)) {
                    .Float => ai - bi,
                    .Int => if (ai > bi) ai - bi else bi - ai,
                    else => unreachable,
                };
                sum += diff * diff;
            }
            return sum;
        }

        fn simdSumOfSquaredDifferences(a: []const T, b: []const T) T {
            const len = a.len;
            const SimdVec = @Vector(SIMD_WIDTH, T);
            var sum: SimdVec = @splat(0);

            var i: usize = 0;
            while (i + SIMD_WIDTH <= len) : (i += SIMD_WIDTH) {
                const va = @as(SimdVec, a[i..][0..SIMD_WIDTH].*);
                const vb = @as(SimdVec, b[i..][0..SIMD_WIDTH].*);
                const diff = switch (@typeInfo(T)) {
                    .Float => va - vb,
                    .Int => @select(T, va >= vb, va - vb, vb - va),
                    else => unreachable,
                };
                sum += diff * diff;
            }

            var result: T = @reduce(.Add, sum);

            // Handle remaining elements
            while (i < len) : (i += 1) {
                const diff = switch (@typeInfo(T)) {
                    .Float => a[i] - b[i],
                    .Int => if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i],
                    else => unreachable,
                };
                result += diff * diff;
            }

            return result;
        }

        pub fn manhattanDistance(a: []const T, b: []const T) T {
            checkDimensions(a, b);
            if (comptime canUseSIMD(T)) {
                return simdManhattanDistance(a, b);
            } else {
                return scalarManhattanDistance(a, b);
            }
        }

        fn scalarManhattanDistance(a: []const T, b: []const T) T {
            var sum: T = 0;
            for (a, 0..) |_, i| {
                sum += if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
            }
            return sum;
        }

        fn simdManhattanDistance(a: []const T, b: []const T) T {
            const len = a.len;
            const SimdVec = @Vector(SIMD_WIDTH, T);
            var sum: SimdVec = @splat(0);

            var i: usize = 0;
            while (i + SIMD_WIDTH <= len) : (i += SIMD_WIDTH) {
                const va = @as(SimdVec, a[i..][0..SIMD_WIDTH].*);
                const vb = @as(SimdVec, b[i..][0..SIMD_WIDTH].*);
                const diff = va - vb;
                sum += @select(T, va > vb, diff, -diff);
            }

            var result: T = @reduce(.Add, sum);

            // Handle remaining elements
            while (i < len) : (i += 1) {
                result += if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
            }

            return result;
        }

        pub fn cosineDistance(a: []const T, b: []const T) T {
            checkDimensions(a, b);
            if (comptime canUseSIMD(T)) {
                return simdCosineDistance(a, b);
            } else {
                return scalarCosineDistance(a, b);
            }
        }

        fn scalarCosineDistance(a: []const T, b: []const T) T {
            var dot_product: T = 0;
            var magnitude_a: T = 0;
            var magnitude_b: T = 0;
            for (a, b) |ai, bi| {
                dot_product += ai * bi;
                magnitude_a += ai * ai;
                magnitude_b += bi * bi;
            }

            return finalizeDistance(dot_product, magnitude_a, magnitude_b);
        }

        fn simdCosineDistance(a: []const T, b: []const T) T {
            const len = a.len;
            const SimdVec = @Vector(SIMD_WIDTH, T);
            var dot_product: SimdVec = @splat(0);
            var magnitude_a: SimdVec = @splat(0);
            var magnitude_b: SimdVec = @splat(0);

            var i: usize = 0;
            while (i + SIMD_WIDTH <= len) : (i += SIMD_WIDTH) {
                const va = @as(SimdVec, a[i..][0..SIMD_WIDTH].*);
                const vb = @as(SimdVec, b[i..][0..SIMD_WIDTH].*);
                dot_product += va * vb;
                magnitude_a += va * va;
                magnitude_b += vb * vb;
            }

            // Reduce SIMD vectors and handle remaining elements
            var dp_sum = @reduce(.Add, dot_product);
            var ma_sum = @reduce(.Add, magnitude_a);
            var mb_sum = @reduce(.Add, magnitude_b);

            for (i..len) |j| {
                dp_sum += a[j] * b[j];
                ma_sum += a[j] * a[j];
                mb_sum += b[j] * b[j];
            }

            return finalizeDistance(dp_sum, ma_sum, mb_sum);
        }

        fn finalizeDistance(dot_product: T, magnitude_a: T, magnitude_b: T) T {
            // Handle potential division by zero
            if (magnitude_a == 0 or magnitude_b == 0) {
                return if (magnitude_a == magnitude_b) 0 else 1;
            }

            const cosine_similarity = dot_product / (std.math.sqrt(magnitude_a) * std.math.sqrt(magnitude_b));
            // Clamp the cosine_similarity to [-1, 1] to avoid domain errors with acos
            const clamped_similarity = std.math.clamp(cosine_similarity, -1, 1);
            return std.math.acos(clamped_similarity) / std.math.pi;
        }

        fn checkDimensions(a: []const T, b: []const T) void {
            if (a.len != b.len) {
                @panic("Mismatched dimensions in distance calculation");
            }
        }

        fn canUseSIMD(comptime ValType: type) bool {
            if (!std.Target.x86.featureSetHas(builtin.cpu.features, .sse)) {
                return false;
            }
            return switch (@typeInfo(ValType)) {
                .Float => |info| switch (info.bits) {
                    32 => true,
                    64 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse2),
                    else => false,
                },
                .Int => |info| switch (info.bits) {
                    8, 16, 32, 64 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse2),
                    else => false,
                },
                else => false,
            };
        }
    };
}

pub const DistanceError = error{
    InvalidMetricName,
    UnsupportedMetricForType,
    MismatchedDimensions,
};

pub fn validateMetricForType(metric: DistanceMetric, comptime T: type) DistanceError!void {
    if (!metric.supportsType(T)) {
        return DistanceError.UnsupportedMetricForType;
    }
}

pub fn calculateDistance(comptime T: type, metric: DistanceMetric, a: []const T, b: []const T) DistanceError!T {
    try validateMetricForType(metric, T);
    if (a.len != b.len) {
        return DistanceError.MismatchedDimensions;
    }
    return DistanceFunctions(T).getFunction(metric)(a, b);
}
