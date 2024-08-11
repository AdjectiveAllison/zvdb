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
        errdefer allocator.destroy(node);
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

    pub const KnnResult = struct {
        id: u64,
        distance: f32,
    };

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
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    pub fn addItem(self: *Self, vector: []const f32) !u64 {
        const new_id: u64 = @intCast(self.nodes.count());
        const new_node = try Node.init(self.allocator, new_id, vector);
        errdefer new_node.deinit(self.allocator);

        const level = self.randomLevel();

        if (level > self.max_level) {
            self.max_level = level;
        }

        // If this is the first node, make it the entry point
        if (self.entry_point == null) {
            self.entry_point = new_id;
            try self.nodes.put(new_id, new_node);
            return new_id;
        }

        // Find entry point
        var curr_node_id = self.entry_point.?;
        var curr_dist = distance.getDistanceFunction(self.distance_metric)(vector, self.nodes.get(curr_node_id).?.vector);

        // Traverse the layers
        var lc: i32 = @intCast(self.max_level);
        while (lc >= 0) : (lc -= 1) {
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

            if (lc <= level) {
                const neighbors = try self.searchLayer(vector, curr_node_id, self.config.ef_construction, @intCast(lc));
                defer self.allocator.free(neighbors);

                try self.connectNewElement(new_node, neighbors, @intCast(lc));

                if (neighbors.len > 0) {
                    curr_node_id = neighbors[0];
                }
            }
        }

        // Update entry point if necessary
        if (level > self.max_level) {
            self.entry_point = new_id;
        }

        try self.nodes.put(new_id, new_node);
        return new_id;
    }

    pub fn deleteItem(self: *Self, id: u64) !void {
        const node = self.nodes.get(id) orelse return error.NodeNotFound;

        // Remove connections to this node from all other nodes
        for (node.connections.items) |neighbor_id| {
            if (self.nodes.getPtr(neighbor_id)) |neighbor| {
                // Find the index of the id in the neighbor's connections
                if (std.mem.indexOfScalar(u64, neighbor.*.connections.items, id)) |index| {
                    _ = neighbor.*.connections.orderedRemove(index);
                }
            }
        }

        // Remove the node from the index and free its memory
        if (self.nodes.remove(id)) {
            node.deinit(self.allocator);
        }

        // If the deleted node was the entry point, update it
        if (self.entry_point) |entry_point| {
            if (entry_point == id) {
                self.entry_point = if (self.nodes.count() > 0)
                    blk: {
                        var it = self.nodes.keyIterator();
                        break :blk if (it.next()) |key_ptr| key_ptr.* else null;
                    }
                else
                    null;
            }
        }

        // Update max_level if necessary
        if (self.max_level > 0) {
            var new_max_level: usize = 0;
            var it = self.nodes.valueIterator();
            while (it.next()) |node_ptr| {
                new_max_level = @max(new_max_level, node_ptr.*.connections.items.len);
            }
            self.max_level = new_max_level;
        }
    }

    pub fn serialize(self: *HNSW, writer: anytype) !void {
        // Write basic information
        try writer.writeInt(usize, self.nodes.count(), .little);
        try writer.writeInt(usize, self.max_level, .little);
        if (self.entry_point) |entry_point| {
            try writer.writeByte(1);
            try writer.writeInt(u64, entry_point, .little);
        } else {
            try writer.writeByte(0);
        }

        // Write nodes
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const node = entry.value_ptr.*;

            try writer.writeInt(u64, id, .little);
            try writer.writeInt(usize, node.vector.len, .little);
            for (node.vector) |value| {
                try writer.writeInt(u32, @bitCast(value), .little);
            }

            try writer.writeInt(usize, node.connections.items.len, .little);
            for (node.connections.items) |connection| {
                try writer.writeInt(u64, connection, .little);
            }
        }
    }

    pub fn deserialize(self: *HNSW, reader: anytype) !void {
        self.deinit(); // Clear existing data
        self.nodes = AutoHashMap(u64, *Node).init(self.allocator);

        const node_count = reader.readInt(usize, .little) catch |err| {
            if (err == error.EndOfStream) {
                return error.InvalidOrEmptyFile;
            }
            return err;
        };
        self.max_level = try reader.readInt(usize, .little);
        const has_entry_point = try reader.readByte();
        if (has_entry_point == 1) {
            self.entry_point = try reader.readInt(u64, .little);
        } else {
            self.entry_point = null;
        }

        // Read nodes
        var i: usize = 0;
        while (i < node_count) : (i += 1) {
            const id = try reader.readInt(u64, .little);
            const vector_len = reader.readInt(usize, .little) catch |err| {
                if (err == error.EndOfStream) {
                    // Handle the case where the file is empty or we've reached the end
                    return error.InvalidOrEmptyFile;
                }
                return err;
            };
            const vector = try self.allocator.alloc(f32, vector_len);
            for (vector) |*value| {
                const bits = try reader.readInt(u32, .little);
                value.* = @bitCast(bits);
            }

            var node = try self.allocator.create(Node);
            node.* = Node{
                .id = id,
                .vector = vector,
                .connections = ArrayList(u64).init(self.allocator),
            };

            const connection_count = try reader.readInt(usize, .little);
            try node.connections.ensureTotalCapacity(connection_count);
            var j: usize = 0;
            while (j < connection_count) : (j += 1) {
                const connection = try reader.readInt(u64, .little);
                try node.connections.append(connection);
            }

            try self.nodes.put(id, node);
        }
    }

    pub fn updateItem(self: *Self, id: u64, vector: []const f32) !void {
        const node = self.nodes.getPtr(id) orelse return error.NodeNotFound;

        // Update the vector
        self.allocator.free(node.*.vector);
        node.*.vector = try self.allocator.dupe(f32, vector);

        // Reconnect the node in the graph
        const level = self.randomLevel();
        var curr_level: usize = 0;
        while (curr_level <= level and curr_level <= self.max_level) : (curr_level += 1) {
            const neighbors = try self.searchLayer(vector, self.entry_point.?, self.config.ef_construction, curr_level);
            defer self.allocator.free(neighbors);

            try self.reconnectNode(node.*, neighbors, curr_level);
        }
    }

    pub fn searchKnn(self: *Self, query: []const f32, k: usize) ![]KnnResult {
        if (self.entry_point == null) {
            return &[_]KnnResult{};
        }

        var curr_node_id = self.entry_point.?;
        var curr_dist = distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(curr_node_id).?.*.vector);

        var lc = self.max_level;
        while (lc > 0) : (lc -= 1) {
            var changed = true;
            while (changed) {
                changed = false;
                for (self.nodes.get(curr_node_id).?.*.connections.items) |neighbor_id| {
                    const neighbor_dist = distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(neighbor_id).?.*.vector);
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

        const result = try self.allocator.alloc(KnnResult, @min(k, neighbors.len));
        for (neighbors[0..@min(k, neighbors.len)], 0..) |id, i| {
            result[i] = .{
                .id = id,
                .distance = distance.getDistanceFunction(self.distance_metric)(query, self.nodes.get(id).?.*.vector),
            };
        }

        return result;
    }

    fn randomLevel(self: *Self) usize {
        // Generate a random float between 0 and 1
        const random_float = std.crypto.random.float(f32);

        // Multiply by (max_level + 1) and truncate to get an integer
        const level = @as(usize, @intFromFloat(random_float * @as(f32, @floatFromInt(self.max_level + 1))));

        // Ensure the level is within bounds
        return @min(level, self.max_level);
    }

    fn searchLayer(self: *Self, query: []const f32, entry_point: u64, ef: usize, layer: usize) ![]u64 {
        var candidates = std.PriorityQueue(u64, *const Self, distanceComparator).init(self.allocator, self);
        defer candidates.deinit();
        var visited = AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        try candidates.add(entry_point);
        try visited.put(entry_point, {});

        var results = std.PriorityQueue(u64, *const Self, distanceComparator).init(self.allocator, self);
        defer results.deinit();
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
        errdefer self.allocator.free(result);

        var i: usize = 0;
        while (results.removeOrNull()) |id| {
            result[i] = id;
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
            try self.pruneConnections(new_node, level);
        }

        for (neighbors) |neighbor_id| {
            const neighbor = self.nodes.get(neighbor_id).?;
            if (neighbor.connections.items.len > self.config.max_connections) {
                try self.pruneConnections(neighbor, level);
            }
        }
    }

    fn pruneConnections(self: *Self, node: *Node, level: usize) !void {
        const start = level * self.config.max_connections;
        const end = @min((level + 1) * self.config.max_connections, node.connections.items.len);

        var connections = std.PriorityQueue(u64, *const Self, distanceComparator).init(self.allocator, self);
        defer connections.deinit();

        for (node.connections.items[start..end]) |conn_id| {
            try connections.add(conn_id);
        }

        node.connections.shrinkRetainingCapacity(start);

        while (connections.count() > 0 and node.connections.items.len < (level + 1) * self.config.max_connections) {
            const conn_id = connections.remove();
            try node.connections.append(conn_id);
        }
    }

    fn reconnectNode(self: *Self, node: *Node, neighbors: []const u64, level: usize) !void {
        // Clear existing connections at this level
        while (node.connections.items.len > level * self.config.max_connections) {
            _ = node.connections.pop();
        }

        // Add new connections
        for (neighbors) |neighbor_id| {
            if (node.connections.items.len >= (level + 1) * self.config.max_connections) break;
            if (neighbor_id != node.id) {
                try node.connections.append(neighbor_id);
                if (self.nodes.getPtr(neighbor_id)) |neighbor| {
                    try neighbor.*.connections.append(node.id);
                }
            }
        }

        // Ensure reciprocal connections and prune if necessary
        try self.ensureReciprocalConnections(node, level);
    }

    fn ensureReciprocalConnections(self: *Self, node: *Node, level: usize) !void {
        const start = level * self.config.max_connections;
        const end = @min((level + 1) * self.config.max_connections, node.connections.items.len);

        for (node.connections.items[start..end]) |neighbor_id| {
            if (self.nodes.getPtr(neighbor_id)) |neighbor| {
                const contains = for (neighbor.*.connections.items) |conn_id| {
                    if (conn_id == node.id) break true;
                } else false;

                if (!contains) {
                    try neighbor.*.connections.append(node.id);
                }
            }
        }

        // Prune connections if necessary
        var it = self.nodes.valueIterator();
        while (it.next()) |neighbor| {
            if (neighbor.*.connections.items.len > (level + 1) * self.config.max_connections) {
                try self.pruneConnections(neighbor.*, level);
            }
        }
    }

    fn distanceComparator(self: *const Self, a: u64, b: u64) std.math.Order {
        const dist_fn = distance.getDistanceFunction(self.distance_metric);
        const dist_a = dist_fn(self.nodes.get(a).?.vector, self.nodes.get(b).?.vector);
        const dist_b = dist_fn(self.nodes.get(a).?.vector, self.nodes.get(b).?.vector);
        return std.math.order(dist_a, dist_b);
    }
};
