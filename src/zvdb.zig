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

    pub fn init(allocator: Allocator, zvdb_config: config.Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .index = undefined,
            .config = zvdb_config,
            .metadata_schema = try metadata.schema.Schema.init(allocator, zvdb_config.metadata_schema),
            .persistence = storage.Persistence.init(allocator),
            .memory_storage = memory.MemoryStorage.init(allocator),
        };

        errdefer self.deinit();

        self.index = try index.createIndex(allocator, zvdb_config.index_config);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.index.deinit();
        self.metadata_schema.deinit();
        self.persistence.deinit();
        self.memory_storage.deinit();
        self.config.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn add(self: *Self, vector: []const f32, new_metadata: ?metadata.json.Metadata) !u64 {
        if (vector.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        if (new_metadata) |*md| {
            try self.metadata_schema.validate(md);
        }

        const id = try self.index.add(vector);
        const metadata_bytes = if (new_metadata) |md| try std.json.stringifyAlloc(self.allocator, md.getValue(), .{}) else null;
        defer if (metadata_bytes) |mb| self.allocator.free(mb);

        _ = try self.memory_storage.add(vector, metadata_bytes);
        return id;
    }

    pub fn search(self: *Self, query: []const f32, limit: usize) ![]SearchResult {
        if (query.len != self.config.dimension) {
            return error.InvalidVectorDimension;
        }

        const results = try self.index.search(self.allocator, query, limit);
        defer self.allocator.free(results);

        var search_results = try self.allocator.alloc(SearchResult, results.len);
        errdefer self.allocator.free(search_results);

        for (results, 0..) |result, i| {
            const stored_item = try self.memory_storage.get(result.id);

            search_results[i] = .{
                .id = result.id,
                .distance = 1.0 - result.similarity,
                .metadata = if (stored_item.metadata.len > 0)
                    try metadata.json.Metadata.fromJsonString(self.allocator, stored_item.metadata)
                else
                    null,
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

        if (new_metadata) |*md| {
            try self.metadata_schema.validate(md);
        }

        try self.index.update(id, vector);
        const metadata_bytes = if (new_metadata) |md| try std.json.stringifyAlloc(self.allocator, md.getValue(), .{}) else null;
        defer if (metadata_bytes) |mb| self.allocator.free(mb);

        try self.memory_storage.update(id, vector, metadata_bytes);
    }

    pub fn save(self: *Self, file_path: []const u8) !void {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        var buffered_writer = std.io.bufferedWriter(file.writer());
        var any_writer = buffered_writer.writer().any();
        try self.index.serialize(&any_writer);
        try buffered_writer.flush();
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

    pub fn deinit(self: *SearchResult) void {
        if (self.metadata) |*md| {
            md.deinit();
        }
    }
};
