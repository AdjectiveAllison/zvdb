const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const metadata = @import("../metadata.zig");

pub const MemoryStorage = struct {
    allocator: Allocator,
    vectors: std.AutoHashMap(u64, []f32),
    metadata: std.AutoHashMap(u64, *metadata.MetadataSchema),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .vectors = std.AutoHashMap(u64, []f32).init(allocator),
            .metadata = std.AutoHashMap(u64, *metadata.MetadataSchema).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var vector_it = self.vectors.iterator();
        while (vector_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.vectors.deinit();

        var metadata_it = self.metadata.iterator();
        while (metadata_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }

    pub fn add(self: *Self, id: u64, vector: []const f32, md: *const metadata.MetadataSchema) !void {
        const new_vector = try self.allocator.dupe(f32, vector);
        const new_metadata = try md.clone(self.allocator);

        try self.vectors.put(id, new_vector);
        try self.metadata.put(id, new_metadata);
    }

    pub fn get(self: *Self, id: u64) !struct { vector: []const f32, metadata: ?*metadata.MetadataSchema } {
        const vector = self.vectors.get(id) orelse return error.IdNotFound;
        const md = self.metadata.get(id);

        return .{
            .vector = vector,
            .metadata = md,
        };
    }

    pub fn update(self: *Self, id: u64, vector: []const f32, md: ?metadata.MetadataSchema) !void {
        if (self.vectors.getPtr(id)) |vector_ptr| {
            self.allocator.free(vector_ptr.*);
            vector_ptr.* = try self.allocator.dupe(f32, vector);
        } else {
            return error.IdNotFound;
        }

        if (self.metadata.getPtr(id)) |old_md_ptr| {
            old_md_ptr.*.deinit();
            self.allocator.destroy(old_md_ptr.*);
        }

        if (md) |new_md| {
            const cloned_md = try new_md.clone(self.allocator);
            try self.metadata.put(id, cloned_md);
        } else {
            _ = self.metadata.remove(id);
        }
    }

    pub fn delete(self: *Self, id: u64) !void {
        if (self.vectors.get(id)) |vector| {
            self.allocator.free(vector);
            _ = self.vectors.remove(id);
        } else {
            return error.IdNotFound;
        }

        if (self.metadata.get(id)) |md| {
            md.deinit();
            self.allocator.destroy(md);
            _ = self.metadata.remove(id);
        }
    }

    pub fn count(self: *const Self) u64 {
        return self.vectors.count();
    }

    pub fn clone(self: *const Self, allocator: Allocator) !*metadata.MetadataSchema {
        var new_metadata = try allocator.create(metadata.MetadataSchema);
        new_metadata.* = .{
            .allocator = allocator,
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
