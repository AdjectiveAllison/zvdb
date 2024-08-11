const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const config = @import("config.zig");
pub const index = @import("index/index.zig");
pub const distance = @import("distance/distance.zig");
pub const DistanceMetric = distance.DistanceMetric;
pub const storage = @import("storage/persistence.zig");
pub const memory = @import("storage/memory.zig");
pub const metadata = struct {
    pub const schema = @import("metadata/schema.zig");
    pub const json = @import("metadata/json.zig");
};

pub const ZVDB = struct {
    allocator: Allocator,
    index: index.Index,
    config: config.Config,
    metadata_schema: metadata.schema.Schema,
    persistence: storage.Persistence,
    memory_storage: memory.MemoryStorage,

    const Self = @This();

    pub fn init(allocator: Allocator, zvdb_config: config.Config) !Self {
        const zvdb = Self{
            .allocator = allocator,
            .index = try index.createIndex(allocator, zvdb_config.index_config),
            .config = zvdb_config,
            .metadata_schema = try metadata.schema.Schema.init(allocator, zvdb_config.metadata_schema),
            .persistence = storage.Persistence.init(allocator),
            .memory_storage = memory.MemoryStorage.init(allocator),
        };
        return zvdb;
    }

    pub fn deinit(self: *Self) void {
        self.index.deinit();
        self.metadata_schema.deinit();
        self.persistence.deinit();
        self.memory_storage.deinit();
    }

    pub fn add(self: *Self, vector: []const f32, new_metadata: ?metadata.json.Metadata) !u64 {
        if (vector.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        if (new_metadata) |md| {
            try self.metadata_schema.validate(md);
        }

        const id = try self.index.add(vector);
        const metadata_bytes = if (new_metadata) |md| try std.json.stringifyAlloc(self.allocator, md, .{}) else null;
        defer if (metadata_bytes) |mb| self.allocator.free(mb);

        try self.memory_storage.add(vector, metadata_bytes);
        return id;
    }

    pub fn search(self: *Self, query: []const f32, limit: usize) ![]SearchResult {
        if (query.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        const distance_fn = self.config.distance_function;
        const results = try self.index.search(query, limit, distance_fn);

        var search_results = try self.allocator.alloc(SearchResult, results.len);
        for (results, 0..) |result, i| {
            const stored_item = try self.memory_storage.get(result.id);
            const parsed_metadata = if (stored_item.metadata.len > 0)
                try std.json.parseFromSlice(metadata.json.Metadata, self.allocator, stored_item.metadata, .{})
            else
                null;

            search_results[i] = .{
                .id = result.id,
                .distance = result.distance,
                .metadata = parsed_metadata,
            };
        }

        return search_results;
    }

    pub fn delete(self: *Self, id: u64) !void {
        try self.index.delete(id);
        try self.memory_storage.delete(id);
    }

    pub fn update(self: *Self, id: u64, vector: []const f32, new_metadata: ?metadata.json.Metadata) !void {
        if (vector.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        if (new_metadata) |md| {
            try self.metadata_schema.validate(md);
        }

        try self.index.update(id, vector);
        const metadata_bytes = if (new_metadata) |md| try std.json.stringifyAlloc(self.allocator, md, .{}) else null;
        defer if (metadata_bytes) |mb| self.allocator.free(mb);

        try self.memory_storage.update(id, vector, metadata_bytes);
    }

    pub fn save(self: *Self, file_path: []const u8) !void {
        try self.persistence.save(self, file_path);
    }

    pub fn load(self: *Self, file_path: []const u8) !void {
        try self.persistence.load(self, file_path);
    }

    pub fn updateMetadataSchema(self: *Self, new_schema: []const u8) !void {
        try self.metadata_schema.update(new_schema);
        // TODO: Validate existing metadata against new schema
    }
};

pub const SearchResult = struct {
    id: u64,
    distance: f32,
    metadata: ?metadata.json.Metadata,
};
