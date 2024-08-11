const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const config = @import("config.zig");
pub const index = @import("index/index.zig");
pub const distance = @import("distance/distance.zig");
pub const DistanceMetric = distance.DistanceMetric;
pub const storage = @import("storage/persistence.zig");
pub const memory = @import("storage/memory.zig");
pub const metadata = @import("metadata.zig");

pub const ZVDB = struct {
    allocator: Allocator,
    index: index.Index,
    config: config.Config,
    persistence: storage.Persistence,
    memory_storage: memory.MemoryStorage,

    const Self = @This();

    pub fn init(allocator: Allocator, zvdb_config: config.Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .index = undefined,
            .config = zvdb_config,
            .persistence = storage.Persistence.init(allocator),
            .memory_storage = memory.MemoryStorage.init(allocator),
        };

        // If storage_path is provided, make a copy of it
        if (zvdb_config.storage_path) |path| {
            self.config.storage_path = try allocator.dupe(u8, path);
        }

        errdefer self.deinit();

        self.index = try index.createIndex(allocator, zvdb_config.index_config);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.index.deinit();
        self.persistence.deinit();
        self.memory_storage.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    pub fn add(self: *Self, vector: []const f32, new_metadata: *const metadata.MetadataSchema) !u64 {
        if (vector.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        try new_metadata.validate();

        const id = try self.index.add(vector);

        try self.memory_storage.add(id, vector, new_metadata);
        std.debug.print("Added node. Total nodes: {}\n", .{self.index.getNodeCount()});
        return id;
    }

    pub fn search(self: *Self, query: []const f32, limit: usize) ![]SearchResult {
        if (query.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        const results = try self.index.search(self.allocator, query, limit);
        defer {
            for (results) |*result| {
                if (result.metadata) |md| {
                    md.deinit();
                    self.allocator.destroy(md);
                }
            }
            self.allocator.free(results);
        }

        var search_results = try self.allocator.alloc(SearchResult, results.len);
        errdefer {
            for (search_results) |*result| {
                if (result.metadata) |md| {
                    md.deinit();
                    self.allocator.destroy(md);
                }
            }
            self.allocator.free(search_results);
        }

        for (results, 0..) |result, i| {
            const stored_item = try self.memory_storage.get(result.id);

            search_results[i] = .{
                .id = result.id,
                .distance = 1.0 - result.similarity,
                .metadata = if (stored_item.metadata) |md| try md.clone(self.allocator) else null,
            };
        }

        return search_results;
    }

    pub fn delete(self: *Self, id: u64) !void {
        try self.index.delete(id);
        try self.memory_storage.delete(id);
    }

    pub fn update(self: *Self, id: u64, vector: []const f32, new_metadata: ?metadata.MetadataSchema) !void {
        if (vector.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        if (new_metadata) |md| {
            try md.validate();
        }

        try self.index.update(id, vector);
        try self.memory_storage.update(id, vector, new_metadata);
    }

    pub fn save(self: *Self, file_path: []const u8) !void {
        std.debug.print("Saving database to file: {s}\n", .{file_path});
        std.debug.print("Saving ZVDB: {} vectors in memory storage\n", .{self.memory_storage.count()});
        try self.persistence.save(self, file_path);
        std.debug.print("Database saved successfully\n", .{});
    }

    pub fn load(self: *Self, file_path: []const u8) !void {
        std.debug.print("Loading database from file: {s}\n", .{file_path});

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        std.debug.print("File size: {} bytes\n", .{file_size});

        if (file_size == 0) {
            return error.EmptyFile;
        }

        self.memory_storage.clear(); // Clear existing data before loading

        const load_result = self.persistence.load(self, file_path);
        if (load_result) |_| {
            std.debug.print("Database loaded successfully\n", .{});
            std.debug.print("Loaded ZVDB: {} vectors in memory storage\n", .{self.memory_storage.count()});
        } else |err| {
            std.debug.print("Error loading database: {}\n", .{err});
            // Clean up partially loaded data
            self.memory_storage.clear();
            self.index.deinit();
            self.index = try index.createIndex(self.allocator, self.config.index_config);
            return err;
        }
    }
};

pub const SearchResult = struct {
    id: u64,
    distance: f32,
    metadata: ?*metadata.MetadataSchema,

    pub fn deinit(self: *SearchResult, allocator: Allocator) void {
        if (self.metadata) |md| {
            md.deinit();
            allocator.destroy(md);
        }
    }
};
