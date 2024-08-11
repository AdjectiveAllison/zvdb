const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

const distance = @import("../distance/distance.zig");
const DistanceMetric = distance.DistanceMetric;

pub const HNSWConfig = struct {
    max_connections: usize,
    ef_construction: usize,
    ef_search: usize,
};

const Node = struct {
    id: u64,
    vector: []f32,
    connections: ArrayList(u64),

    fn init(allocator: Allocator, id: u64, vector: []const f32) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .id = id,
            .vector = try allocator.dupe(f32, vector),
            .connections = ArrayList(u64).init(allocator),
        };
        return node;
    }

    fn deinit(self: *Node, allocator: Allocator) void {
        allocator.free(self.vector);
        self.connections.deinit();
        allocator.destroy(self);
    }
};

pub const HNSW = struct {
    allocator: Allocator,
    nodes: AutoHashMap(u64, *Node),
    entry_point: ?u64,
    max_level: usize,
    config: HNSWConfig,
    distance_metric: DistanceMetric,

    const Self = @This();

    pub fn init(allocator: Allocator, config: HNSWConfig, dist_metric: DistanceMetric) !Self {
        return Self{
            .allocator = allocator,
            .nodes = AutoHashMap(u64, *Node).init(allocator),
            .entry_point = null,
            .max_level = 0,
            .config = config,
            .distance_metric = dist_metric,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            node.*.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    pub fn addItem(self: *Self, id: u64, vector: []const f32) !void {
        const new_node = try Node.init(self.allocator, id, vector);
        const level = self.randomLevel();

        if (level > self.max_level) {
            self.max_level = level;
        }

        // If this is the first node, make it the entry point
        if (self.entry_point == null) {
            self.entry_point = id;
            try self.nodes.put(id, new_node);
            return;
        }

        // Find entry point
        var curr_node_id = self.entry_point.?;
        var curr_dist = distance.getDistanceFunction(self.distance_metric)(vector, self.nodes.get(curr_node_id).?.vector);

        // Traverse the layers
        var lc = self.max_level;
        while (lc > level) : (lc -= 1) {
            var changed = true;
            while (changed) {
                changed = false;
                for (self.nodes.get(curr_node_id).?.connections.items) |neighbor_id| {
                    const neighbor_dist = distance.getDistanceFunction(self.distance_metric)(vector, self.nodes.get(neighbor_id).?.vector);
                    if (neighbor_dist < curr_dist) {
                        curr_node_id = neighbor_id;
                        curr_dist = neighbor_dist;
                        changed = true;
                    }
                }
            }
        }

        // Connect the new node to its neighbors
        while (lc >= 0) : (lc -= 1) {
            const neighbors = try self.searchLayer(vector, curr_node_id, self.config.ef_construction, lc);
            defer self.allocator.free(neighbors);

            try self.connectNewElement(new_node, neighbors, lc);

            if (neighbors.len > 0) {
                curr_node_id = neighbors[0];
            }
        }

        // Update entry point if necessary
        if (level > self.max_level) {
            self.entry_point = id;
        }

        try self.nodes.put(id, new_node);
    }

    pub fn searchKnn(self: *Self, query: []const f32, k: usize) ![]u64 {
        if (self.entry_point == null) {
            return &[_]u64{};
        }

        var curr_node_id = self.entry_point.?;
        var curr_dist = distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(curr_node_id).?.vector);

        var lc = self.max_level;
        while (lc > 0) : (lc -= 1) {
            var changed = true;
            while (changed) {
                changed = false;
                for (self.nodes.get(curr_node_id).?.connections.items) |neighbor_id| {
                    const neighbor_dist = distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(neighbor_id).?.vector);
                    if (neighbor_dist < curr_dist) {
                        curr_node_id = neighbor_id;
                        curr_dist = neighbor_dist;
                        changed = true;
                    }
                }
            }
        }

        const neighbors = try self.searchLayer(query, curr_node_id, self.config.ef_search, 0);
        defer self.allocator.free(neighbors);

        const result = try self.allocator.alloc(u64, @min(k, neighbors.len));
        @memcpy(result, neighbors[0..@min(k, neighbors.len)]);

        return result;
    }

    fn randomLevel(self: *Self) usize {
        var rng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = rng.random();
        return @intCast(random.float(f32) * @as(f32, @floatFromInt(self.max_level + 1)));
    }

    fn searchLayer(self: *Self, query: []const f32, entry_point: u64, ef: usize, layer: usize) ![]u64 {
        var candidates = std.PriorityQueue(u64, *const Self, distanceComparator).init(self.allocator, self);
        var visited = AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        try candidates.add(entry_point);
        try visited.put(entry_point, {});

        var results = std.PriorityQueue(u64, *const Self, distanceComparator).init(self.allocator, self);
        try results.add(entry_point);

        while (candidates.removeOrNull()) |curr_id| {
            const curr_dist = distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(curr_id).?.vector);
            if (results.count() >= ef and curr_dist > distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(results.peek().?).?.vector)) {
                break;
            }

            // Filter connections based on the current layer
            const connections = self.nodes.get(curr_id).?.connections.items;
            const layer_connections = connections[0..@min(connections.len, self.config.max_connections * (layer + 1))];

            for (layer_connections) |neighbor_id| {
                if (!visited.contains(neighbor_id)) {
                    try visited.put(neighbor_id, {});
                    const neighbor_dist = distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(neighbor_id).?.vector);

                    if (results.count() < ef or neighbor_dist < distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(results.peek().?).?.vector)) {
                        try candidates.add(neighbor_id);
                        try results.add(neighbor_id);

                        if (results.count() > ef) {
                            _ = results.remove();
                        }
                    }
                }
            }
        }

        const result = try self.allocator.alloc(u64, results.count());
        var i: usize = 0;
        while (results.removeOrNull()) |id| {
            result[results.count() - i - 1] = id;
            i += 1;
        }

        return result;
    }

    fn connectNewElement(self: *Self, new_node: *Node, neighbors: []const u64, level: usize) !void {
        for (neighbors) |neighbor_id| {
            try new_node.connections.append(neighbor_id);
            try self.nodes.get(neighbor_id).?.connections.append(new_node.id);
        }

        if (new_node.connections.items.len > self.config.max_connections) {
            try self.shrinkConnections(new_node, level);
        }

        for (neighbors) |neighbor_id| {
            const neighbor = self.nodes.get(neighbor_id).?;
            if (neighbor.connections.items.len > self.config.max_connections) {
                try self.shrinkConnections(neighbor, level);
            }
        }
    }

    fn shrinkConnections(self: *Self, node: *Node, level: usize) !void {
        var connections = try std.PriorityQueue(u64, *const Self, distanceComparator).init(self.allocator, self);
        defer connections.deinit();

        for (node.connections.items) |conn_id| {
            try connections.add(conn_id);
        }

        node.connections.clearRetainingCapacity();

        // Adjust max connections based on the level
        const level_max_connections = @max(self.config.max_connections / (level + 1), 2);

        while (connections.count() > 0 and node.connections.items.len < level_max_connections) {
            const conn_id = connections.remove();
            try node.connections.append(conn_id);
        }
    }

    fn distanceComparator(self: *const Self, a: u64, b: u64) std.math.Order {
        const dist_fn = distance.getDistanceFunction(self.distance_metric);
        const dist_a = dist_fn(self.nodes.get(a).?.vector, self.nodes.get(b).?.vector);
        const dist_b = dist_fn(self.nodes.get(a).?.vector, self.nodes.get(b).?.vector);
        return std.math.order(dist_a, dist_b);
    }
};
