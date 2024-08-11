const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const index = @import("index/index.zig");
const distance = @import("distance/distance.zig");
const DistanceMetric = distance.DistanceMetric;
const storage = @import("storage/persistence.zig");
const metadata = @import("metadata/schema.zig");

pub const ZVDB = struct {
    allocator: Allocator,
    index: index.Index,
    config: config.Config,
    metadata_schema: metadata.Schema,

    const Self = @This();

    pub fn init(allocator: Allocator, zvdb_config: config.Config) !Self {
        const zvdb = Self{
            .allocator = allocator,
            .index = try index.createIndex(allocator, zvdb_config.index_config),
            .config = zvdb_config,
            .metadata_schema = try metadata.Schema.init(allocator, zvdb_config.metadata_schema),
        };
        return zvdb;
    }

    pub fn deinit(self: *Self) void {
        self.index.deinit();
        self.metadata_schema.deinit();
    }

    pub fn add(self: *Self, vector: []const f32, new_metadata: ?json.Value) !u64 {
        if (vector.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        if (new_metadata) |md| {
            try self.metadata_schema.validate(md);
        }

        const id = try self.index.add(vector);
        // TODO: Store metadata separately
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
            search_results[i] = .{
                .id = result.id,
                .distance = result.distance,
                .metadata = null, // TODO: Fetch and include metadata in results
            };
        }

        return search_results;
    }

    pub fn delete(self: *Self, id: u64) !void {
        try self.index.delete(id);
        // TODO: Delete associated metadata
    }

    pub fn update(self: *Self, id: u64, vector: []const f32, new_metadata: ?json.Value) !void {
        if (vector.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        if (new_metadata) |md| {
            try self.metadata_schema.validate(md);
        }

        try self.index.update(id, vector);
        // TODO: Update associated metadata
    }

    pub fn save(self: *Self, file_path: []const u8) !void {
        try storage.save(self, file_path);
    }

    pub fn load(self: *Self, file_path: []const u8) !void {
        try storage.load(self, file_path);
    }

    pub fn updateMetadataSchema(self: *Self, new_schema: []const u8) !void {
        try self.metadata_schema.update(new_schema);
        // TODO: Validate existing metadata against new schema
    }
};

pub const SearchResult = struct {
    id: u64,
    distance: f32,
    metadata: ?json.Value,
};
