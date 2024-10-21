const std = @import("std");
const distance = @import("distance.zig");
const atomic = std.atomic;
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;

const KiB = 1024;
const MiB = 1024 * KiB;
const GiB = 1024 * MiB;

pub const HMMISConfig = struct {
    distance_metric: distance.DistanceMetric = .Euclidean,
};

// Hierarchical Metadata-Mapped Index Structure
pub fn HMMIS(
    comptime T: type,
    comptime len: comptime_int,
) type {
    return struct {
        const Self = @This();

        // TODO: This needs a better type, but I like the tagged union approach of std.json.Value so it's there temporarily.
        const MetaData = StringHashMap(std.json.Value);

        pub const EmbeddingResult = struct {
            id: usize,
            point: [len]T,
            distance: T,

            pub fn lessThan(_: void, a: EmbeddingResult, b: EmbeddingResult) std.math.Order {
                return std.math.order(a.distance, b.distance);
            }
        };
        const UsageStats = struct {
            memory_usage: atomic.Value(usize),
            vector_count: atomic.Value(usize),

            pub fn init(usage: usize, count: usize) UsageStats {
                return .{
                    .memory_usage = atomic.Value(usize).init(usage),
                    .vector_count = atomic.Value(usize).init(count),
                };
            }

            pub fn initEmpty() UsageStats {
                return UsageStats.init(0, 0);
            }

            pub fn addVector(self: *UsageStats) void {
                _ = self.vector_count.fetchAdd(1, .monotonic);
                _ = self.memory_usage.fetchAdd(EMBEDDING_SIZE, .monotonic);
            }
            pub fn removeVector(self: *UsageStats) void {
                _ = self.vector_count.fetchSub(1, .monotonic);
                _ = self.memory_usage.fetchSub(EMBEDDING_SIZE, .monotonic);
            }
            pub fn addVectors(self: *UsageStats, count: usize) void {
                _ = self.vector_count.fetchAdd(count, .monotonic);
                _ = self.memory_usage.fetchAdd(count * EMBEDDING_SIZE, .monotonic);
            }
            pub fn removeVectors(self: *UsageStats, count: usize) void {
                _ = self.vector_count.fetchSub(count, .monotonic);
                _ = self.memory_usage.fetchSub(count * EMBEDDING_SIZE, .monotonic);
            }
        };

        const EMBEDDING_SIZE: usize = getEmbeddingSize();

        const Cluster = struct {
            allocator: Allocator,
            centroid: [len]T,
            centroid_needs_updating: bool = false,
            metadata: MetaData,
            usage: UsageStats,
            cells: ArrayList(Cell),
            cells_need_rebalancing: bool = false,

            pub fn init(allocator: Allocator) !Cluster {
                var cluster: Cluster = undefined;

                cluster = .{
                    .allocator = allocator,
                    .centroid = [_]T{0} ** len,
                    .centroid_needs_updating = true,
                    .usage = UsageStats.initEmpty(),
                    .metadata = MetaData.init(allocator),
                    .cells = ArrayList(Cell).init(allocator),
                };

                try cluster.cells.append(Cell.init(allocator));

                return cluster;
            }

            pub fn deinit(self: *Cluster) void {
                for (self.cells.items) |*cell| {
                    cell.deinit();
                }
                self.cells.deinit();
            }

            pub fn insert(self: *Cluster, point_id: usize, point: [len]T) !void {
                self.usage.addVector();
                if (self.cells.items.len == 1) {
                    try self.cells.items[0].insert(point_id, point);
                }
            }

            pub fn search(self: *Cluster, point: [len]T, k: usize) ![]const EmbeddingResult {
                // TODO: Only return if we have 1 cluster
                // if (self.cells.items.len == 1) {
                return self.cells.items[0].search(point, k);
                // }
            }
        };

        const Cell = struct {
            allocator: Allocator,
            centroid: [len]T,
            centroid_needs_updating: bool = false,
            usage: UsageStats,
            // TODO: How does this metadata map to ID later on?
            metadata: MetaData,
            embeddings: AutoHashMap(usize, [len]T),

            pub fn init(allocator: Allocator) Cell {
                return .{
                    .allocator = allocator,
                    .usage = UsageStats.initEmpty(),
                    .metadata = MetaData.init(allocator),
                    .centroid = [_]T{0} ** len,
                    .centroid_needs_updating = true,
                    .embeddings = AutoHashMap(usize, [len]T).init(allocator),
                };
            }

            pub fn deinit(self: *Cell) void {
                self.embeddings.deinit();
            }
            pub fn insert(self: *Cell, point_id: usize, point: [len]T) !void {
                self.usage.addVector();
                try self.embeddings.put(point_id, point);
            }

            pub fn search(self: *Cell, point: [len]T, k: usize) ![]const EmbeddingResult {
                var result = try ArrayList(EmbeddingResult).initCapacity(self.allocator, k);

                var candidates = std.PriorityQueue(EmbeddingResult, void, EmbeddingResult.lessThan).init(self.allocator, {});
                defer candidates.deinit();

                var embeddings_iterator = self.embeddings.iterator();
                while (embeddings_iterator.next()) |entry| {
                    const target_id = entry.key_ptr.*;
                    const target_embedding = entry.value_ptr.*;

                    // TODO: Change up having to hardcode the distance type to allow config differences in `HMMISConfig`
                    const distance_between = distance.DistanceFunctions(T, len).euclideanDistance(target_embedding, point);
                    const embeddeing_result: EmbeddingResult = .{ .id = target_id, .point = target_embedding, .distance = distance_between };

                    if (candidates.count() < k) {
                        try candidates.add(embeddeing_result);
                    } else if (distance_between < candidates.peek().?.distance) {
                        _ = candidates.remove();
                        try candidates.add(embeddeing_result);
                    }
                }

                for (candidates.items) |candidate| {
                    try result.append(candidate);
                }

                return result.toOwnedSlice();
            }
        };

        allocator: Allocator,
        // TODO: I think we'll want to decide on a size to best work with memory mapping later on.
        usage: UsageStats,
        next_id: atomic.Value(usize),
        clusters: ArrayList(Cluster),
        clusters_need_rebalancing: bool = false,

        pub fn init(allocator: Allocator, config: HMMISConfig) !Self {

            // TODO: do something with config here.
            // I think we should make config comptime so that we can more easily interact with distance functions.
            _ = config;
            var self: Self = undefined;

            self = .{
                .allocator = allocator,
                .usage = UsageStats.initEmpty(),
                .clusters = ArrayList(Cluster).init(allocator),
                .next_id = atomic.Value(usize).init(0),
            };

            try self.clusters.append(try Cluster.init(allocator));

            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.clusters.items) |*cluster| {
                cluster.deinit();
            }
            self.clusters.deinit();
        }

        pub fn insert(self: *Self, point: [len]T) !void {
            const point_id = self.getNextId();
            self.usage.addVector();
            // If we only have one cluster let's simply insert up to it.
            if (self.clusters.items.len == 1) {
                try self.clusters.items[0].insert(point_id, point);
            }
        }

        pub fn search(self: *Self, point: [len]T, k: usize) ![]const EmbeddingResult {
            // TODO: Only return if we have 1 cluster
            // if (self.clusters.items.len == 1) {
            return self.clusters.items[0].search(point, k);
            // }
        }

        fn getNextId(self: *Self) usize {
            return self.next_id.fetchAdd(1, .monotonic);
        }

        fn getEmbeddingSize() usize {
            const size = @sizeOf(T);
            return @as(usize, size * len);
        }
    };
}
