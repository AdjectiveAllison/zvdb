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
        max_top_clusters: usize,
        max_sub_clusters: usize,

        const Collection = struct {
            name: []const u8,
            top_clusters: std.ArrayList(TopCluster),
            metadata_index: MetadataIndex,
        };

        const TopCluster = struct {
            centroid: [dim]T,
            sub_clusters: std.ArrayList(SubCluster),
            vector_file: []const u8,
            is_loaded: bool,
            mapped_memory: ?[]align(std.mem.page_size) u8,
        };

        const SubCluster = struct {
            centroid: [dim]T,
            vector_range: struct { start: usize, end: usize },
        };

        const MetadataIndex = struct {
            cluster_count: usize,
        };

        pub fn init(allocator: Allocator, max_top_clusters: usize, max_sub_clusters: usize) Self {
            return .{
                .allocator = allocator,
                .collections = std.StringHashMap(Collection).init(allocator),
                .max_top_clusters = max_top_clusters,
                .max_sub_clusters = max_sub_clusters,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.collections.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.name);
                for (entry.value_ptr.top_clusters.items) |*top_cluster| {
                    self.allocator.free(top_cluster.vector_file);
                    top_cluster.sub_clusters.deinit();
                    if (top_cluster.is_loaded) {
                        self.unloadCluster(top_cluster);
                    }
                }
                entry.value_ptr.top_clusters.deinit();
            }
            self.collections.deinit();
        }

        pub fn createCollection(self: *Self, name: []const u8) !void {
            if (self.collections.contains(name)) {
                return error.CollectionAlreadyExists;
            }

            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);

            const collection = Collection{
                .name = name_copy,
                .top_clusters = std.ArrayList(TopCluster).init(self.allocator),
                .metadata_index = MetadataIndex{ .cluster_count = 0 },
            };

            try self.collections.put(name_copy, collection);
        }

        pub fn insert(self: *Self, collection_name: []const u8, vector: [dim]T) !void {
            var collection = self.collections.getPtr(collection_name) orelse return error.CollectionNotFound;

            if (collection.top_clusters.items.len == 0) {
                try self.createNewTopCluster(collection, vector);
                return;
            }

            const nearest_top_cluster = try self.findNearestTopCluster(collection, vector);
            if (nearest_top_cluster.sub_clusters.items.len < self.max_sub_clusters) {
                try self.insertIntoTopCluster(nearest_top_cluster, vector);
            } else {
                if (collection.top_clusters.items.len < self.max_top_clusters) {
                    try self.createNewTopCluster(collection, vector);
                } else {
                    return error.MaxClustersReached;
                }
            }

            collection.metadata_index.cluster_count += 1;
        }

        fn createNewTopCluster(self: *Self, collection: *Collection, vector: [dim]T) !void {
            const file_name = try std.fmt.allocPrint(self.allocator, "{s}_cluster_{d}.bin", .{ collection.name, collection.top_clusters.items.len });
            errdefer self.allocator.free(file_name);

            // Create the file and write initial data
            const file = try fs.cwd().createFile(file_name, .{ .read = true, .truncate = true });
            defer file.close();

            // Allocate space for more vectors (e.g., 10000)
            const initial_size = 10000 * dim * @sizeOf(T);
            try file.setEndPos(initial_size);

            // Write initial vector to the file
            try file.writeAll(std.mem.sliceAsBytes(&vector));

            const new_top_cluster = TopCluster{
                .centroid = vector,
                .sub_clusters = std.ArrayList(SubCluster).init(self.allocator),
                .vector_file = file_name,
                .is_loaded = false,
                .mapped_memory = null,
            };

            try collection.top_clusters.append(new_top_cluster);
            try self.insertIntoTopCluster(&collection.top_clusters.items[collection.top_clusters.items.len - 1], vector);
        }

        fn insertIntoTopCluster(self: *Self, top_cluster: *TopCluster, vector: [dim]T) !void {
            if (!top_cluster.is_loaded) {
                try self.loadCluster(top_cluster);
            }

            // std.debug.print("Cluster loaded. Is mapped_memory null? {}\n", .{top_cluster.mapped_memory == null});
            // if (top_cluster.mapped_memory) |memory| {
            //     std.debug.print("Mapped memory size: {}\n", .{memory.len});
            // }

            const new_sub_cluster = SubCluster{
                .centroid = vector,
                .vector_range = .{ .start = top_cluster.sub_clusters.items.len * dim, .end = (top_cluster.sub_clusters.items.len + 1) * dim },
            };

            // std.debug.print("New sub-cluster range: start={}, end={}\n", .{ new_sub_cluster.vector_range.start, new_sub_cluster.vector_range.end });

            if (top_cluster.mapped_memory) |memory| {
                if (new_sub_cluster.vector_range.end * @sizeOf(T) > memory.len) {
                    // Need to grow the file and remap
                    try self.growClusterFile(top_cluster);
                }

                const vector_ptr = @as([*]T, @ptrCast(memory.ptr)) + new_sub_cluster.vector_range.start;
                @memcpy(vector_ptr[0..dim], &vector);
            } else {
                return error.MappedMemoryNotInitialized;
            }

            try top_cluster.sub_clusters.append(new_sub_cluster);
            try self.updateTopClusterCentroid(top_cluster);
        }

        fn growClusterFile(self: *Self, top_cluster: *TopCluster) !void {
            _ = self;
            const file = try fs.cwd().openFile(top_cluster.vector_file, .{ .mode = .read_write });
            defer file.close();

            const current_size = try file.getEndPos();
            const new_size = current_size * 2; // Double the size

            try file.setEndPos(new_size);

            // Sync the current memory before unmapping
            if (top_cluster.mapped_memory) |memory| {
                try posix.msync(memory, posix.MSF.SYNC);
                posix.munmap(memory);
            }

            // Remap with the new size
            const mapped_memory = try posix.mmap(
                null,
                new_size,
                posix.PROT.READ | posix.PROT.WRITE,
                posix.MAP{ .TYPE = .SHARED },
                file.handle,
                0,
            );

            top_cluster.mapped_memory = mapped_memory;
            std.debug.print("Grew cluster file. New size: {}\n", .{new_size});
        }

        fn updateTopClusterCentroid(self: *Self, top_cluster: *TopCluster) !void {
            _ = self;
            var new_centroid: [dim]T = [_]T{0} ** dim;
            const total_vectors = top_cluster.sub_clusters.items.len;

            for (top_cluster.sub_clusters.items) |sub_cluster| {
                for (0..dim) |i| {
                    new_centroid[i] += sub_cluster.centroid[i] / @as(T, @floatFromInt(total_vectors));
                }
            }

            top_cluster.centroid = new_centroid;
        }

        fn loadCluster(self: *Self, cluster: *TopCluster) !void {
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

        fn unloadCluster(self: *Self, cluster: *TopCluster) void {
            _ = self; // silence unused parameter warning
            if (!cluster.is_loaded) return;

            if (cluster.mapped_memory) |memory| {
                const aligned_size = std.mem.alignForward(usize, memory.len, std.mem.page_size);
                posix.munmap(memory.ptr[0..aligned_size]);
                cluster.mapped_memory = null;
                cluster.is_loaded = false;
            }
        }
        pub fn search(self: *Self, collection_name: []const u8, query: [dim]T, k: usize) ![][dim]T {
            const collection = self.collections.getPtr(collection_name) orelse return error.CollectionNotFound;

            const nearest_top_cluster = try self.findNearestTopCluster(collection, query);
            try self.loadCluster(nearest_top_cluster);
            defer self.unloadCluster(nearest_top_cluster);

            var candidates = std.ArrayList([dim]T).init(self.allocator);
            defer candidates.deinit();

            for (nearest_top_cluster.sub_clusters.items) |sub_cluster| {
                if (nearest_top_cluster.mapped_memory) |memory| {
                    const vector_ptr = @as([*]const T, @ptrCast(memory.ptr)) + sub_cluster.vector_range.start;
                    const vector = vector_ptr[0..dim].*;
                    try candidates.append(vector);
                }
            }

            const results = try self.findKNearest(query, candidates.items, k);
            return results;
        }

        fn findNearestTopCluster(self: *Self, collection: *Collection, query: [dim]T) !*TopCluster {
            _ = self;
            var nearest: ?*TopCluster = null;
            var min_distance: T = std.math.inf(T);

            // std.debug.print("Finding nearest top cluster for query. Total clusters: {}\n", .{collection.top_clusters.items.len});

            for (collection.top_clusters.items) |*top_cluster| {
                const dist = distance.DistanceFunctions(T, dim).euclideanDistance(top_cluster.centroid, query);
                // std.debug.print("Cluster {}: distance = {}\n", .{ i, dist });
                if (dist < min_distance) {
                    min_distance = dist;
                    nearest = top_cluster;
                }
            }

            // if (nearest) |n| {
            //     std.debug.print("Selected cluster with {} sub-clusters\n", .{n.sub_clusters.items.len});
            // }
            //
            return nearest orelse error.NoTopClustersFound;
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
