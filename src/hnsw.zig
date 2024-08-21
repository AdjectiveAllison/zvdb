const std = @import("std");
const builtin = @import("builtin");
const distance = @import("distance.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Order = std.math.Order;
const RwLock = std.Thread.RwLock;
const AtomicValue = std.atomic.Value;
const Thread = std.Thread;

pub const HNSWConfig = struct {
    m: usize,
    ef_construction: usize,
    distance: distance.DistanceMetric = .Euclidean,
    num_threads: usize = 1,
    partition_size: usize = 1000,
};

pub fn HNSW(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            id: usize,
            point: []T,
            connections: []ArrayList(usize),
            lock: RwLock,

            fn init(allocator: Allocator, id: usize, point: []const T, level: usize) !Node {
                const connections = try allocator.alloc(ArrayList(usize), level + 1);
                errdefer allocator.free(connections);
                for (connections) |*conn| {
                    conn.* = ArrayList(usize).init(allocator);
                }
                const owned_point = try allocator.alloc(T, point.len);
                errdefer allocator.free(owned_point);
                @memcpy(owned_point, point);
                return Node{
                    .id = id,
                    .point = owned_point,
                    .connections = connections,
                    .lock = RwLock{},
                };
            }

            fn deinit(self: *Node, allocator: Allocator) void {
                for (self.connections) |*conn| {
                    conn.deinit();
                }
                allocator.free(self.connections);
                allocator.free(self.point);
            }
        };

        allocator: Allocator,
        nodes: AutoHashMap(usize, Node),
        entry_point: AtomicValue(usize),
        max_level: AtomicValue(usize),
        config: HNSWConfig,
        global_lock: RwLock,
        partitions: []ArrayList(usize),

        pub fn init(allocator: Allocator, config: HNSWConfig) !Self {
            try distance.validateMetricForType(config.distance, T);
            const num_partitions = @max(1, config.num_threads);
            const partitions = try allocator.alloc(ArrayList(usize), num_partitions);
            for (partitions) |*partition| {
                partition.* = ArrayList(usize).init(allocator);
            }
            return .{
                .allocator = allocator,
                .nodes = AutoHashMap(usize, Node).init(allocator),
                .entry_point = AtomicValue(usize).init(std.math.maxInt(usize)),
                .max_level = AtomicValue(usize).init(0),
                .config = config,
                .global_lock = RwLock{},
                .partitions = partitions,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                var node = entry.value_ptr;
                node.deinit(self.allocator);
            }
            self.nodes.deinit();
            for (self.partitions) |*partition| {
                partition.deinit();
            }
            self.allocator.free(self.partitions);
        }

        fn calculateDistance(self: *const Self, a: []const T, b: []const T) T {
            return switch (self.config.distance) {
                .Euclidean => distance.DistanceFunctions(T).euclideanDistance(a, b),
                .Manhattan => distance.DistanceFunctions(T).manhattanDistance(a, b),
                .Cosine => switch (@typeInfo(T)) {
                    .Float => distance.DistanceFunctions(T).cosineDistance(a, b),
                    else => @panic("Cosine distance is only supported for floating-point types"),
                },
            };
        }

        pub fn insert(self: *Self, point: []const T) !void {
            self.global_lock.lock();
            defer self.global_lock.unlock();

            const id = self.nodes.count();
            const level = self.randomLevel();
            var node = try Node.init(self.allocator, id, point, level);
            errdefer node.deinit(self.allocator);

            try self.nodes.put(id, node);

            const entry = self.entry_point.load(.acquire);
            if (entry != std.math.maxInt(usize)) {
                var ep_copy = entry;
                var curr_dist = self.calculateDistance(node.point, self.nodes.get(ep_copy).?.point);

                const max_level = self.max_level.load(.acquire);
                for (0..max_level + 1) |layer| {
                    var changed = true;
                    while (changed) {
                        changed = false;
                        var curr_node = self.nodes.get(ep_copy).?;
                        curr_node.lock.lockShared();
                        defer curr_node.lock.unlockShared();

                        if (layer < curr_node.connections.len) {
                            for (curr_node.connections[layer].items) |neighbor_id| {
                                var neighbor = self.nodes.get(neighbor_id).?;
                                neighbor.lock.lockShared();
                                const dist = self.calculateDistance(node.point, neighbor.point);
                                neighbor.lock.unlockShared();
                                if (dist < curr_dist) {
                                    ep_copy = neighbor_id;
                                    curr_dist = dist;
                                    changed = true;
                                }
                            }
                        }
                    }

                    if (layer <= level) {
                        try self.connect(id, ep_copy, @intCast(layer));
                    }
                }
            } else {
                self.entry_point.store(id, .release);
            }

            while (true) {
                const old_max_level = self.max_level.load(.acquire);
                if (level <= old_max_level) break;
                if (self.max_level.cmpxchgStrong(old_max_level, level, .release, .monotonic) == null) break;
            }
        }

        fn connect(self: *Self, source: usize, target: usize, level: usize) !void {
            var source_node = self.nodes.getPtr(source) orelse return error.NodeNotFound;
            var target_node = self.nodes.getPtr(target) orelse return error.NodeNotFound;

            source_node.lock.lock();
            defer source_node.lock.unlock();
            target_node.lock.lock();
            defer target_node.lock.unlock();

            if (level < source_node.connections.len) {
                try source_node.connections[level].append(target);
            }
            if (level < target_node.connections.len) {
                try target_node.connections[level].append(source);
            }

            if (level < source_node.connections.len) {
                try self.shrinkConnections(source, level);
            }
            if (level < target_node.connections.len) {
                try self.shrinkConnections(target, level);
            }
        }

        fn shrinkConnections(self: *Self, node_id: usize, level: usize) !void {
            var node = self.nodes.getPtr(node_id).?;
            var connections = &node.connections[level];
            if (connections.items.len <= self.config.m) return;

            var candidates = try self.allocator.alloc(usize, connections.items.len);
            defer self.allocator.free(candidates);
            @memcpy(candidates, connections.items);

            const ShrinkContext = struct {
                self: *Self,
                node: *Node,
            };
            const context = ShrinkContext{ .self = self, .node = node };

            const compareFn = struct {
                fn compare(ctx: ShrinkContext, a: usize, b: usize) bool {
                    const dist_a = ctx.self.calculateDistance(ctx.node.point, ctx.self.nodes.get(a).?.point);
                    const dist_b = ctx.self.calculateDistance(ctx.node.point, ctx.self.nodes.get(b).?.point);
                    return dist_a < dist_b;
                }
            }.compare;

            std.sort.insertion(usize, candidates, context, compareFn);

            connections.shrinkRetainingCapacity(self.config.m);
            @memcpy(connections.items, candidates[0..self.config.m]);
        }

        fn randomLevel(self: *Self) usize {
            _ = self;
            var level: usize = 0;
            const max_level = 31;
            while (level < max_level and std.crypto.random.float(f32) < 0.5) {
                level += 1;
            }
            return level;
        }

        pub fn search(self: *Self, query: []const T, k: usize) ![]const Node {
            if (self.config.num_threads > 1) {
                return self.parallelSearch(query, k);
            } else {
                return self.sequentialSearch(query, k);
            }
        }

        fn sequentialSearch(self: *Self, query: []const T, k: usize) ![]const Node {
            self.global_lock.lockShared();
            defer self.global_lock.unlockShared();

            var result = try ArrayList(Node).initCapacity(self.allocator, k);
            errdefer result.deinit();

            const entry = self.entry_point.load(.acquire);
            if (entry != std.math.maxInt(usize)) {
                var candidates = std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan).init(self.allocator, {});
                defer candidates.deinit();

                var visited = std.AutoHashMap(usize, void).init(self.allocator);
                defer visited.deinit();

                try candidates.add(.{ .id = entry, .distance = self.calculateDistance(query, self.nodes.get(entry).?.point) });
                try visited.put(entry, {});

                while (candidates.count() > 0 and result.items.len < k) {
                    const current = candidates.remove();
                    var current_node = self.nodes.get(current.id).?;
                    current_node.lock.lockShared();
                    try result.append(current_node);
                    current_node.lock.unlockShared();

                    for (current_node.connections[0].items) |neighbor_id| {
                        if (!visited.contains(neighbor_id)) {
                            var neighbor = self.nodes.get(neighbor_id).?;
                            neighbor.lock.lockShared();
                            const dist = self.calculateDistance(query, neighbor.point);
                            neighbor.lock.unlockShared();
                            try candidates.add(.{ .id = neighbor_id, .distance = dist });
                            try visited.put(neighbor_id, {});
                        }
                    }
                }
            }

            std.sort.insertion(Node, result.items, Context{ .self = self, .query = query }, Context.lessThan);

            return result.toOwnedSlice();
        }

        pub fn parallelSearch(self: *Self, query: []const T, k: usize) ![]const Node {
            self.global_lock.lockShared();
            defer self.global_lock.unlockShared();

            var result = try ArrayList(Node).initCapacity(self.allocator, k);
            errdefer result.deinit();

            const entry = self.entry_point.load(.acquire);
            if (entry != std.math.maxInt(usize)) {
                var upper_candidates = try self.searchUpperLayers(query);
                defer upper_candidates.deinit();

                var lower_candidates = try self.searchLowerLayers(query, upper_candidates);
                defer lower_candidates.deinit();

                while (lower_candidates.count() > 0 and result.items.len < k) {
                    const current = lower_candidates.remove();
                    var current_node = self.nodes.get(current.id).?;
                    current_node.lock.lockShared();
                    try result.append(current_node);
                    current_node.lock.unlockShared();
                }
            }

            std.sort.insertion(Node, result.items, Context{ .self = self, .query = query }, Context.lessThan);

            return result.toOwnedSlice();
        }

        const ThreadContext = struct {
            self: *Self,
            query: []const T,
            partition: *const ArrayList(usize),
            candidates: *std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan),
            lock: *RwLock,
        };

        fn searchUpperLayers(self: *Self, query: []const T) !std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan) {
            var candidates = std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan).init(self.allocator, {});
            errdefer candidates.deinit();

            var threads = try self.allocator.alloc(Thread, self.partitions.len);
            defer self.allocator.free(threads);

            var thread_contexts = try self.allocator.alloc(ThreadContext, self.partitions.len);
            defer self.allocator.free(thread_contexts);

            var candidates_lock = RwLock{};

            for (self.partitions, 0..) |*partition, i| {
                thread_contexts[i] = .{
                    .self = self,
                    .query = query,
                    .partition = partition,
                    .candidates = &candidates,
                    .lock = &candidates_lock,
                };
                threads[i] = try Thread.spawn(.{}, searchPartition, .{&thread_contexts[i]});
            }

            for (threads) |thread| {
                thread.join();
            }

            return candidates;
        }

        fn searchPartition(ctx: *const ThreadContext) void {
            for (ctx.partition.items) |node_id| {
                const node = ctx.self.nodes.get(node_id).?;
                const dist = ctx.self.calculateDistance(ctx.query, node.point);
                ctx.lock.lock();
                ctx.candidates.add(.{ .id = node_id, .distance = dist }) catch {};
                ctx.lock.unlock();
            }
        }

        fn searchLowerLayers(self: *Self, query: []const T, mut_upper_candidates: std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan)) !std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan) {
            var upper_candidates = mut_upper_candidates;
            var lower_candidates = std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan).init(self.allocator, {});
            errdefer lower_candidates.deinit();

            var visited = std.AutoHashMap(usize, void).init(self.allocator);
            defer visited.deinit();

            while (upper_candidates.count() > 0) {
                const current = upper_candidates.remove();
                if (visited.contains(current.id)) continue;
                try visited.put(current.id, {});

                var current_node = self.nodes.get(current.id).?;
                current_node.lock.lockShared();
                for (current_node.connections[0].items) |neighbor_id| {
                    if (!visited.contains(neighbor_id)) {
                        var neighbor = self.nodes.get(neighbor_id).?;
                        neighbor.lock.lockShared();
                        const dist = self.calculateDistance(query, neighbor.point);
                        neighbor.lock.unlockShared();
                        try lower_candidates.add(.{ .id = neighbor_id, .distance = dist });
                    }
                }
                current_node.lock.unlockShared();
            }

            return lower_candidates;
        }

        const CandidateNode = struct {
            id: usize,
            distance: T,

            fn lessThan(_: void, a: CandidateNode, b: CandidateNode) std.math.Order {
                return std.math.order(a.distance, b.distance);
            }
        };

        const Context = struct {
            self: *const Self,
            query: []const T,
            pub fn lessThan(ctx: @This(), a: Node, b: Node) bool {
                return ctx.self.calculateDistance(ctx.query, a.point) < ctx.self.calculateDistance(ctx.query, b.point);
            }
        };
    };
}
