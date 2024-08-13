const std = @import("std");
const builtin = @import("builtin");
const distance = @import("distance.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Order = std.math.Order;
const Mutex = std.Thread.Mutex;

pub const HNSWConfig = struct {
    m: usize,
    ef_construction: usize,
    distance: distance.DistanceMetric = .Euclidean,
};

pub fn HNSW(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            id: usize,
            point: []T,
            connections: []ArrayList(usize),
            mutex: Mutex,

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
                    .mutex = Mutex{},
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
        entry_point: ?usize,
        max_level: usize,
        config: HNSWConfig,
        mutex: Mutex,

        pub fn init(allocator: Allocator, config: HNSWConfig) !Self {
            try distance.validateMetricForType(config.distance, T);
            return .{
                .allocator = allocator,
                .nodes = AutoHashMap(usize, Node).init(allocator),
                .entry_point = null,
                .max_level = 0,
                .config = config,
                .mutex = Mutex{},
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                var node = entry.value_ptr;
                node.deinit(self.allocator);
            }
            self.nodes.deinit();
        }

        fn calculateDistance(self: *const Self, a: []const T, b: []const T) T {
            return switch (self.config.distance) {
                .Euclidean => distance.DistanceFunctions(T).euclideanDistance(a, b),
                .Manhattan => distance.DistanceFunctions(T).manhattanDistance(a, b),
                .Cosine => switch (@typeInfo(T)) {
                    .Float => distance.DistanceFunctions(T).cosineDistance(a, b),
                    else => @compileError("Cosine distance is only supported for floating-point types"),
                },
            };
        }

        pub fn insert(self: *Self, point: []const T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const id = self.nodes.count();
            const level = self.randomLevel();
            var node = try Node.init(self.allocator, id, point, level);
            errdefer node.deinit(self.allocator);

            try self.nodes.put(id, node);

            if (self.entry_point) |entry| {
                var ep_copy = entry;
                var curr_dist = self.calculateDistance(node.point, self.nodes.get(ep_copy).?.point);

                for (0..self.max_level + 1) |layer| {
                    var changed = true;
                    while (changed) {
                        changed = false;
                        const curr_node = self.nodes.get(ep_copy).?;
                        if (layer < curr_node.connections.len) {
                            for (curr_node.connections[layer].items) |neighbor_id| {
                                const neighbor = self.nodes.get(neighbor_id).?;
                                const dist = self.calculateDistance(node.point, neighbor.point);
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
                self.entry_point = id;
            }

            if (level > self.max_level) {
                self.max_level = level;
            }
        }

        fn connect(self: *Self, source: usize, target: usize, level: usize) !void {
            var source_node = self.nodes.getPtr(source) orelse return error.NodeNotFound;
            var target_node = self.nodes.getPtr(target) orelse return error.NodeNotFound;

            source_node.mutex.lock();
            defer source_node.mutex.unlock();
            target_node.mutex.lock();
            defer target_node.mutex.unlock();

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

            const Context = struct {
                self: *Self,
                node: *Node,
            };
            const context = Context{ .self = self, .node = node };

            const compareFn = struct {
                fn compare(ctx: Context, a: usize, b: usize) bool {
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
            self.mutex.lock();
            defer self.mutex.unlock();

            var result = try ArrayList(Node).initCapacity(self.allocator, k);
            errdefer result.deinit();

            if (self.entry_point) |entry| {
                var candidates = std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan).init(self.allocator, {});
                defer candidates.deinit();

                var visited = std.AutoHashMap(usize, void).init(self.allocator);
                defer visited.deinit();

                try candidates.add(.{ .id = entry, .distance = self.calculateDistance(query, self.nodes.get(entry).?.point) });
                try visited.put(entry, {});

                while (candidates.count() > 0 and result.items.len < k) {
                    const current = candidates.remove();
                    const current_node = self.nodes.get(current.id).?;
                    try result.append(current_node);

                    for (current_node.connections[0].items) |neighbor_id| {
                        if (!visited.contains(neighbor_id)) {
                            const neighbor = self.nodes.get(neighbor_id).?;
                            const dist = self.calculateDistance(query, neighbor.point);
                            try candidates.add(.{ .id = neighbor_id, .distance = dist });
                            try visited.put(neighbor_id, {});
                        }
                    }
                }
            }

            const Context = struct {
                self: *const Self,
                query: []const T,
                pub fn lessThan(ctx: @This(), a: Node, b: Node) bool {
                    return ctx.self.calculateDistance(ctx.query, a.point) < ctx.self.calculateDistance(ctx.query, b.point);
                }
            };
            std.sort.insertion(Node, result.items, Context{ .self = self, .query = query }, Context.lessThan);

            return result.toOwnedSlice();
        }

        const CandidateNode = struct {
            id: usize,
            distance: T,

            fn lessThan(_: void, a: CandidateNode, b: CandidateNode) std.math.Order {
                return std.math.order(a.distance, b.distance);
            }
        };
    };
}
