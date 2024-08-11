const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

pub const MetadataVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn init(major: u32, minor: u32, patch: u32) MetadataVersion {
        return MetadataVersion{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn compare(self: MetadataVersion, other: MetadataVersion) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }
};

pub const MetadataSchema = struct {
    allocator: Allocator,
    version: MetadataVersion,
    name: ?[]u8,
    value: ?f64,
    tags: ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: Allocator) MetadataSchema {
        return MetadataSchema{
            .allocator = allocator,
            .version = MetadataVersion.init(1, 0, 0),
            .name = null,
            .value = null,
            .tags = ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.name) |name| {
            self.allocator.free(name);
        }
        for (self.tags.items) |tag| {
            self.allocator.free(tag);
        }
        self.tags.deinit();
    }

    pub fn validate(self: *const Self) !void {
        if (self.name == null and self.value == null and self.tags.items.len == 0) {
            return error.InvalidMetadata;
        }
        // Add more validation checks as needed
    }

    pub fn serialize(self: *const Self) ![]u8 {
        var list = ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

        try list.writer().print("version:{}.{}.{}\n", .{ self.version.major, self.version.minor, self.version.patch });

        if (self.name) |name| {
            try list.writer().print("name:{s}\n", .{name});
        }
        if (self.value) |value| {
            try list.writer().print("value:{d}\n", .{value});
        }

        for (self.tags.items) |tag| {
            try list.writer().print("tag:{s}\n", .{tag});
        }

        return list.toOwnedSlice();
    }

    pub fn deserialize(allocator: Allocator, data: []const u8) !*Self {
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .version = MetadataVersion.init(1, 0, 0),
            .name = null,
            .value = null,
            .tags = ArrayList([]const u8).init(allocator),
        };

        var lines = std.mem.splitSequence(u8, data, "\n");
        while (lines.next()) |line| {
            var kv = std.mem.splitSequence(u8, line, ":");
            const key = kv.next() orelse continue;
            const value = kv.next() orelse continue;

            if (std.mem.eql(u8, key, "version")) {
                var version_parts = std.mem.splitSequence(u8, value, ".");
                self.version.major = try std.fmt.parseInt(u32, version_parts.next() orelse "0", 10);
                self.version.minor = try std.fmt.parseInt(u32, version_parts.next() orelse "0", 10);
                self.version.patch = try std.fmt.parseInt(u32, version_parts.next() orelse "0", 10);
            } else if (std.mem.eql(u8, key, "name")) {
                self.name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "value")) {
                self.value = try std.fmt.parseFloat(f64, value);
            } else if (std.mem.eql(u8, key, "tag")) {
                try self.tags.append(try allocator.dupe(u8, value));
            }
        }

        return self;
    }

    pub fn addTag(self: *Self, tag: []const u8) !void {
        try self.tags.append(try self.allocator.dupe(u8, tag));
    }

    pub fn setName(self: *Self, name: []const u8) !void {
        if (self.name) |old_name| {
            self.allocator.free(old_name);
        }
        self.name = try self.allocator.dupe(u8, name);
    }

    pub fn clone(self: *const MetadataSchema, allocator: Allocator) !*MetadataSchema {
        var new_metadata = try allocator.create(MetadataSchema);
        errdefer allocator.destroy(new_metadata);

        new_metadata.* = .{
            .allocator = allocator,
            .version = self.version,
            .name = if (self.name) |name| try allocator.dupe(u8, name) else null,
            .value = self.value,
            .tags = try ArrayList([]const u8).initCapacity(allocator, self.tags.items.len),
        };

        for (self.tags.items) |tag| {
            try new_metadata.tags.append(try allocator.dupe(u8, tag));
        }

        return new_metadata;
    }
};

pub const MetadataManager = struct {
    allocator: Allocator,
    metadata_store: AutoHashMap(u64, *MetadataSchema),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .metadata_store = AutoHashMap(u64, *MetadataSchema).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.metadata_store.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.metadata_store.deinit();
    }

    pub fn storeMetadata(self: *Self, id: u64, metadata: *const MetadataSchema) !void {
        const new_metadata = try metadata.clone(self.allocator);
        try self.metadata_store.put(id, new_metadata);
    }

    pub fn retrieveMetadata(self: *Self, id: u64) ?*MetadataSchema {
        return self.metadata_store.get(id);
    }

    pub fn updateMetadata(self: *Self, id: u64, metadata: *const MetadataSchema) !void {
        if (self.metadata_store.getPtr(id)) |old_metadata| {
            old_metadata.*.deinit();
            self.allocator.destroy(old_metadata.*);
        }
        try self.storeMetadata(id, metadata);
    }

    pub fn deleteMetadata(self: *Self, id: u64) !void {
        if (self.metadata_store.fetchRemove(id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    pub fn migrateMetadata(self: *Self, id: u64, to_version: MetadataVersion) !void {
        if (self.metadata_store.getPtr(id)) |metadata| {
            // Implement migration logic here
            // This is a placeholder and should be replaced with actual migration code
            if (metadata.*.version.compare(to_version) == .lt) {
                metadata.*.version = to_version;
                // Perform necessary transformations on the metadata
            }
        }
    }

    pub fn upgradeAllMetadata(self: *Self) !void {
        const latest_version = MetadataVersion.init(1, 0, 0); // Update this as needed
        var it = self.metadata_store.iterator();
        while (it.next()) |entry| {
            try self.migrateMetadata(entry.key_ptr.*, latest_version);
        }
    }
};
