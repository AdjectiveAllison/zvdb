const std = @import("std");
const distance = @import("distance/distance.zig");
const DistanceMetric = distance.DistanceMetric;
const index = @import("index/index.zig");

pub const Config = struct {
    // General configuration
    dimension: usize,
    distance_metric: DistanceMetric,

    // Index configuration
    index_config: index.IndexConfig,

    // Metadata configuration
    metadata_schema: []const u8,

    // Storage configuration
    storage_path: ?[]const u8,

    pub fn init(
        dimension: usize,
        distance_metric: DistanceMetric,
        index_config: index.IndexConfig,
        metadata_schema: []const u8,
        storage_path: ?[]const u8,
    ) Config {
        return .{
            .dimension = dimension,
            .distance_metric = distance_metric,
            .index_config = index_config,
            .metadata_schema = metadata_schema,
            .storage_path = storage_path,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.storage_path) |path| {
            allocator.free(path);
        }
    }
};

pub const ConfigBuilder = struct {
    dimension: ?usize = null,
    distance_metric: ?DistanceMetric = null,
    index_config: ?index.IndexConfig = null,
    metadata_schema: ?[]const u8 = null,
    storage_path: ?[]const u8 = null,

    pub fn init() ConfigBuilder {
        return .{};
    }

    pub fn setDimension(self: *ConfigBuilder, dim: usize) *ConfigBuilder {
        self.dimension = dim;
        return self;
    }

    pub fn setDistanceMetric(self: *ConfigBuilder, metric: DistanceMetric) *ConfigBuilder {
        self.distance_metric = metric;
        return self;
    }

    pub fn setIndexConfig(self: *ConfigBuilder, idx_config: index.IndexConfig) *ConfigBuilder {
        self.index_config = idx_config;
        return self;
    }

    pub fn setMetadataSchema(self: *ConfigBuilder, schema: []const u8) *ConfigBuilder {
        self.metadata_schema = schema;
        return self;
    }

    pub fn setStoragePath(self: *ConfigBuilder, path: []const u8) *ConfigBuilder {
        self.storage_path = path;
        return self;
    }

    pub fn build(self: *ConfigBuilder, allocator: std.mem.Allocator) !Config {
        if (self.dimension == null or self.distance_metric == null or self.index_config == null or self.metadata_schema == null) {
            return error.MissingRequiredConfiguration;
        }

        return Config.init(
            self.dimension.?,
            distance.getDistanceFunction(self.distance_metric.?),
            self.index_config.?,
            try allocator.dupe(u8, self.metadata_schema.?),
            if (self.storage_path) |path| try allocator.dupe(u8, path) else null,
        );
    }
};
