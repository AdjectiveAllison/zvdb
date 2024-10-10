const std = @import("std");
const Allocator = std.mem.Allocator;
const distance = @import("distance.zig");
const posix = std.posix;
const fs = std.fs;
const assert = std.debug.assert;

pub fn MCANN(comptime T: type, comptime dim: comptime_int) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        collections: std.StringHashMap(Collection),
        cluster_manager: ClusterManager,

        const Collection = struct {
            name: []const u8,
            root_cluster: *Cluster,
            metadata_index: MetadataIndex,
        };

        const Cluster = struct {
            centroid: [dim]T,
            vectors: std.ArrayList([dim]T),
            sub_clusters: std.ArrayList(*Cluster),
            parent: ?*Cluster,
            level: usize,
            vector_file: []const u8,
            is_loaded: bool,
            mapped_memory: ?[]align(std.mem.page_size) u8,
        };

        const MetadataIndex = struct {
            total_vectors: usize,
        };

        const ClusterManager = struct {
            allocator: Allocator,
            memory_budget: usize,
            optimal_cluster_size: usize,
            max_depth: usize,
            next_cluster_id: u64,

            fn init(allocator: Allocator, memory_budget: usize) ClusterManager {
                return .{
                    .allocator = allocator,
                    .memory_budget = memory_budget,
                    .optimal_cluster_size = 1000, // This can be adjusted based on experiments
                    .max_depth = 3, // This can also be adjusted
                    .next_cluster_id = 0,
                };
            }

            fn createCluster(self: *ClusterManager, parent: ?*Cluster, level: usize, collection_name: []const u8) !*Cluster {
                const cluster_id = self.next_cluster_id;
                self.next_cluster_id += 1;

                const file_name = try std.fmt.allocPrint(self.allocator, "{s}_cluster_{d}.bin", .{ collection_name, cluster_id });
                errdefer self.allocator.free(file_name);

                const file = try fs.cwd().createFile(file_name, .{ .read = true, .truncate = true });
                defer file.close();

                const initial_size = self.optimal_cluster_size * dim * @sizeOf(T);
                try file.setEndPos(initial_size);

                const new_cluster = try self.allocator.create(Cluster);
                new_cluster.* = .{
                    .centroid = undefined,
                    .vectors = std.ArrayList([dim]T).init(self.allocator),
                    .sub_clusters = std.ArrayList(*Cluster).init(self.allocator),
                    .parent = parent,
                    .level = level,
                    .vector_file = file_name,
                    .is_loaded = false,
                    .mapped_memory = null,
                };

                return new_cluster;
            }

            fn splitClusterIfNeeded(self: *ClusterManager, cluster: *Cluster, collection_name: []const u8) !void {
                std.log.debug("Evaluating split for cluster. Level: {}, Vectors: {}, Max Depth: {}", .{ cluster.level, cluster.vectors.items.len, self.max_depth });
                if (cluster.vectors.items.len <= self.optimal_cluster_size or cluster.level >= self.max_depth) {
                    std.log.debug("Skipping split. Optimal size: {}, Current size: {}", .{ self.optimal_cluster_size, cluster.vectors.items.len });
                    return;
                }

                std.log.info("Splitting cluster. Creating sub-clusters.", .{});
                var kmeans = try KMeans(T, dim).init(self.allocator, 2, cluster.vectors.items);
                defer kmeans.deinit();

                const centroids = try kmeans.run(100);

                for (centroids) |centroid| {
                    const new_cluster = try self.createCluster(cluster, cluster.level + 1, collection_name);
                    new_cluster.centroid = centroid;
                    try cluster.sub_clusters.append(new_cluster);
                }

                // Redistribute vectors to sub-clusters
                const temp_vectors = try self.allocator.alloc([dim]T, cluster.vectors.items.len);
                defer self.allocator.free(temp_vectors);
                @memcpy(temp_vectors, cluster.vectors.items);

                for (temp_vectors) |vector| {
                    const nearest_sub_cluster = try self.findNearestCluster(cluster.sub_clusters.items, vector);
                    try nearest_sub_cluster.vectors.append(vector);
                }

                std.log.debug("Cleared original cluster vectors. Sub-clusters created: {}", .{cluster.sub_clusters.items.len});
                cluster.vectors.clearRetainingCapacity();
            }

            fn findNearestCluster(self: *ClusterManager, clusters: []*Cluster, vector: [dim]T) !*Cluster {
                _ = self;
                var nearest: ?*Cluster = null;
                var min_distance: T = std.math.inf(T);

                for (clusters) |cluster| {
                    const dist = distance.DistanceFunctions(T, dim).euclideanDistance(cluster.centroid, vector);
                    if (dist < min_distance) {
                        min_distance = dist;
                        nearest = cluster;
                    }
                }

                return nearest orelse error.NoClusterFound;
            }

            fn mergeClusterIfNeeded(self: *ClusterManager, cluster: *Cluster) !void {
                if (cluster.sub_clusters.items.len == 0 or cluster.vectors.items.len >= self.optimal_cluster_size / 2) {
                    return;
                }

                // Merge all sub-clusters into this cluster
                for (cluster.sub_clusters.items) |sub_cluster| {
                    try cluster.vectors.appendSlice(sub_cluster.vectors.items);
                    self.deallocateCluster(sub_cluster);
                }

                cluster.sub_clusters.clearRetainingCapacity();
                try self.updateClusterCentroid(cluster);
            }

            fn optimizeClusterStructure(self: *ClusterManager, root_cluster: *Cluster, collection_name: []const u8) !void {
                std.log.info("Starting cluster structure optimization", .{});
                var stack = std.ArrayList(*Cluster).init(self.allocator);
                defer stack.deinit();

                try stack.append(root_cluster);

                while (stack.popOrNull()) |cluster| {
                    std.log.debug("Optimizing cluster. Level: {}, Vectors: {}, Sub-clusters: {}", .{ cluster.level, cluster.vectors.items.len, cluster.sub_clusters.items.len });
                    try self.splitClusterIfNeeded(cluster, collection_name);
                    try self.mergeClusterIfNeeded(cluster);

                    for (cluster.sub_clusters.items) |sub_cluster| {
                        try stack.append(sub_cluster);
                    }
                }
                std.log.info("Finished cluster structure optimization", .{});
            }

            fn updateClusterCentroid(self: *ClusterManager, cluster: *Cluster) !void {
                _ = self;
                var new_centroid: [dim]T = [_]T{0} ** dim;
                const total_vectors = cluster.vectors.items.len;

                for (cluster.vectors.items) |vec| {
                    for (0..dim) |i| {
                        new_centroid[i] += vec[i] / @as(T, @floatFromInt(total_vectors));
                    }
                }

                cluster.centroid = new_centroid;
            }

            fn deallocateCluster(self: *ClusterManager, cluster: *Cluster) void {
                for (cluster.sub_clusters.items) |sub_cluster| {
                    self.deallocateCluster(sub_cluster);
                }
                cluster.vectors.deinit();
                cluster.sub_clusters.deinit();
                self.allocator.free(cluster.vector_file);
                if (cluster.is_loaded) {
                    self.unloadCluster(cluster);
                }
                self.allocator.destroy(cluster);
            }

            fn loadCluster(self: *ClusterManager, cluster: *Cluster) !void {
                _ = self;
                if (cluster.is_loaded) return;

                const file = try fs.cwd().openFile(cluster.vector_file, .{ .mode = .read_write });
                defer file.close();

                const file_size = try file.getEndPos();
                if (file_size == 0) {
                    return error.EmptyFile;
                }

                const aligned_size = std.mem.alignForward(usize, file_size, std.mem.page_size);

                const mapped_memory = try posix.mmap(
                    null,
                    aligned_size,
                    posix.PROT.READ | posix.PROT.WRITE,
                    posix.MAP{ .TYPE = .SHARED },
                    file.handle,
                    0,
                );

                cluster.mapped_memory = mapped_memory;
                cluster.is_loaded = true;
            }

            fn unloadCluster(self: *ClusterManager, cluster: *Cluster) void {
                _ = self;
                if (!cluster.is_loaded) return;

                if (cluster.mapped_memory) |memory| {
                    const aligned_size = std.mem.alignForward(usize, memory.len, std.mem.page_size);
                    posix.munmap(memory.ptr[0..aligned_size]);
                    cluster.mapped_memory = null;
                    cluster.is_loaded = false;
                }
            }

            fn manageMemory(self: *ClusterManager, root_cluster: *Cluster) !void {
                var total_memory_used: usize = 0;
                var clusters_to_unload = std.ArrayList(*Cluster).init(self.allocator);
                defer clusters_to_unload.deinit();

                var stack = std.ArrayList(*Cluster).init(self.allocator);
                defer stack.deinit();

                try stack.append(root_cluster);

                while (stack.popOrNull()) |cluster| {
                    if (cluster.is_loaded) {
                        total_memory_used += cluster.mapped_memory.?.len;
                        try clusters_to_unload.append(cluster);
                    }

                    for (cluster.sub_clusters.items) |sub_cluster| {
                        try stack.append(sub_cluster);
                    }
                }

                // If we're over budget, start unloading clusters
                while (total_memory_used > self.memory_budget and clusters_to_unload.items.len > 0) {
                    const cluster_to_unload = clusters_to_unload.pop();
                    total_memory_used -= cluster_to_unload.mapped_memory.?.len;
                    self.unloadCluster(cluster_to_unload);
                }
            }
        };

        pub fn init(allocator: Allocator, memory_budget: usize) Self {
            return .{
                .allocator = allocator,
                .collections = std.StringHashMap(Collection).init(allocator),
                .cluster_manager = ClusterManager.init(allocator, memory_budget),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.collections.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.name);
                self.cluster_manager.deallocateCluster(entry.value_ptr.root_cluster);
            }
            self.collections.deinit();
        }

        pub fn createCollection(self: *Self, name: []const u8) !void {
            if (self.collections.contains(name)) {
                return error.CollectionAlreadyExists;
            }

            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);

            const root_cluster = try self.cluster_manager.createCluster(null, 0, name_copy);
            errdefer self.cluster_manager.deallocateCluster(root_cluster);

            const collection = Collection{
                .name = name_copy,
                .root_cluster = root_cluster,
                .metadata_index = MetadataIndex{ .total_vectors = 0 },
            };

            try self.collections.put(name_copy, collection);
        }

        pub fn insert(self: *Self, collection_name: []const u8, vector: [dim]T) !void {
            std.log.info("Inserting vector into collection: {s}", .{collection_name});
            var collection = self.collections.getPtr(collection_name) orelse return error.CollectionNotFound;

            try self.insertIntoCluster(collection.root_cluster, vector, collection_name);
            collection.metadata_index.total_vectors += 1;

            std.log.info("Optimizing cluster structure for collection: {s}", .{collection_name});
            try self.cluster_manager.optimizeClusterStructure(collection.root_cluster, collection_name);
            try self.cluster_manager.manageMemory(collection.root_cluster);
        }

        fn insertIntoCluster(self: *Self, cluster: *Cluster, vector: [dim]T, collection_name: []const u8) !void {
            if (cluster.sub_clusters.items.len > 0) {
                const nearest_sub_cluster = try self.cluster_manager.findNearestCluster(cluster.sub_clusters.items, vector);
                return self.insertIntoCluster(nearest_sub_cluster, vector, collection_name);
            }

            try cluster.vectors.append(vector);
            try self.cluster_manager.updateClusterCentroid(cluster);
            std.log.debug("Checking if cluster needs splitting. Level: {}, Vectors: {}", .{ cluster.level, cluster.vectors.items.len });
            try self.cluster_manager.splitClusterIfNeeded(cluster, collection_name);
        }

        pub fn search(self: *Self, collection_name: []const u8, query: [dim]T, k: usize) ![][dim]T {
            const collection = self.collections.getPtr(collection_name) orelse return error.CollectionNotFound;

            var candidates = std.ArrayList([dim]T).init(self.allocator);
            defer candidates.deinit();

            try self.searchCluster(collection.root_cluster, query, &candidates);

            return self.findKNearest(query, candidates.items, k);
        }

        fn searchCluster(self: *Self, cluster: *Cluster, query: [dim]T, candidates: *std.ArrayList([dim]T)) !void {
            if (cluster.sub_clusters.items.len > 0) {
                const nearest_sub_cluster = try self.cluster_manager.findNearestCluster(cluster.sub_clusters.items, query);
                return self.searchCluster(nearest_sub_cluster, query, candidates);
            }

            if (!cluster.is_loaded) {
                try self.cluster_manager.loadCluster(cluster);
            }

            try candidates.appendSlice(cluster.vectors.items);
        }

        fn findKNearest(self: *Self, query: [dim]T, candidates: [][dim]T, k: usize) ![][dim]T {
            const results = try self.allocator.alloc([dim]T, @min(k, candidates.len));
            errdefer self.allocator.free(results);

            const Context = struct {
                query: [dim]T,
                pub fn lessThan(ctx: @This(), a: [dim]T, b: [dim]T) bool {
                    const dist_a = distance.DistanceFunctions(T, dim).euclideanDistance(ctx.query, a);
                    const dist_b = distance.DistanceFunctions(T, dim).euclideanDistance(ctx.query, b);
                    return dist_a < dist_b;
                }
            };

            std.sort.insertion(
                [dim]T,
                candidates,
                Context{ .query = query },
                Context.lessThan,
            );

            @memcpy(results, candidates[0..results.len]);
            return results;
        }
    };
}

// K-means implementation for clustering
fn KMeans(comptime T: type, comptime dim: comptime_int) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        k: usize,
        points: [][dim]T,
        centroids: [][dim]T,

        pub fn init(allocator: Allocator, k: usize, points: [][dim]T) !Self {
            const centroids = try allocator.alloc([dim]T, k);
            errdefer allocator.free(centroids);

            // Initialize centroids randomly
            var prng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                std.crypto.random.bytes(std.mem.asBytes(&seed));
                break :blk seed;
            });
            var rand = prng.random();

            for (centroids) |*centroid| {
                const random_point = points[rand.intRangeAtMost(usize, 0, points.len - 1)];
                @memcpy(centroid, &random_point);
            }

            return Self{
                .allocator = allocator,
                .k = k,
                .points = points,
                .centroids = centroids,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.centroids);
        }

        pub fn run(self: *Self, max_iterations: usize) ![][dim]T {
            var iterations: usize = 0;
            while (iterations < max_iterations) : (iterations += 1) {
                var clusters = try self.allocator.alloc(std.ArrayList([dim]T), self.k);
                defer {
                    for (clusters) |*cluster| {
                        cluster.deinit();
                    }
                    self.allocator.free(clusters);
                }

                for (clusters) |*cluster| {
                    cluster.* = std.ArrayList([dim]T).init(self.allocator);
                }

                // Assign points to nearest centroids
                for (self.points) |point| {
                    const nearest_centroid_index = self.findNearestCentroidIndex(point);
                    try clusters[nearest_centroid_index].append(point);
                }

                // Update centroids
                var changed = false;
                for (self.centroids, 0..) |*centroid, i| {
                    if (clusters[i].items.len > 0) {
                        const new_centroid = self.calculateMean(clusters[i].items);
                        if (!std.mem.eql(T, &new_centroid, centroid)) {
                            changed = true;
                            @memcpy(centroid, &new_centroid);
                        }
                    }
                }

                if (!changed) {
                    break;
                }
            }

            return self.centroids;
        }

        fn findNearestCentroidIndex(self: *Self, point: [dim]T) usize {
            var nearest_index: usize = 0;
            var min_distance: T = std.math.inf(T);

            for (self.centroids, 0..) |centroid, i| {
                const dist = distance.DistanceFunctions(T, dim).euclideanDistance(centroid, point);
                if (dist < min_distance) {
                    min_distance = dist;
                    nearest_index = i;
                }
            }

            return nearest_index;
        }

        fn calculateMean(self: *Self, points: [][dim]T) [dim]T {
            _ = self;
            var mean: [dim]T = [_]T{0} ** dim;
            const total_points = points.len;

            for (points) |point| {
                for (0..dim) |i| {
                    mean[i] += point[i] / @as(T, @floatFromInt(total_points));
                }
            }

            return mean;
        }
    };
}
