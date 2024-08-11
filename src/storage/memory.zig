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

    pub fn clear(self: *Self) void {
        var vector_it = self.vectors.iterator();
        while (vector_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.vectors.clearAndFree();

        var metadata_it = self.metadata.iterator();
        while (metadata_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.metadata.clearAndFree();
    }

    pub fn serializeVectors(self: *const Self, allocator: Allocator) ![]u8 {
        var serialized_data = std.ArrayList(u8).init(allocator);
        errdefer serialized_data.deinit();

        var it = self.vectors.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const vector = entry.value_ptr.*;

            try serialized_data.writer().writeInt(u64, id, .little);
            try serialized_data.writer().writeInt(u32, @intCast(vector.len), .little);
            for (vector) |value| {
                const bits: u32 = @bitCast(value);
                try serialized_data.writer().writeInt(u32, bits, .little);
            }
        }

        return serialized_data.toOwnedSlice();
    }

    pub fn serializeMetadata(self: *const Self, allocator: Allocator) ![]u8 {
        var serialized_data = std.ArrayList(u8).init(allocator);
        errdefer serialized_data.deinit();

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const md = entry.value_ptr.*;

            try serialized_data.writer().writeInt(u64, id, .little);
            
            // Serialize only the serializable fields of MetadataSchema
            const serializable_md = .{
                .name = md.name,
                .value = md.value,
                .tags = md.tags.items,
            };
            
            const md_json = try std.json.stringifyAlloc(allocator, serializable_md, .{});
            defer allocator.free(md_json);
            try serialized_data.writer().writeInt(u32, @intCast(md_json.len), .little);
            try serialized_data.writer().writeAll(md_json);
        }

        return serialized_data.toOwnedSlice();
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
