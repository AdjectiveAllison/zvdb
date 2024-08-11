const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const metadata = @import("../metadata.zig");

pub const MemoryStorage = struct {
    allocator: Allocator,
    vectors: ArrayList([]f32),
    metadata: ArrayList(?*metadata.MetadataSchema),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .vectors = ArrayList([]f32).init(allocator),
            .metadata = ArrayList(?*metadata.MetadataSchema).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.vectors.items) |vector| {
            self.allocator.free(vector);
        }
        self.vectors.deinit();

        for (self.metadata.items) |md| {
            if (md) |m| {
                m.deinit();
            }
        }
        self.metadata.deinit();
    }

    pub fn add(self: *Self, vector: []const f32, md: ?*metadata.MetadataSchema) !u64 {
        const new_vector = try self.allocator.dupe(f32, vector);
        try self.vectors.append(new_vector);
        try self.metadata.append(md);

        return self.vectors.items.len - 1;
    }

    pub fn get(self: *Self, id: u64) !struct { vector: []const f32, metadata: ?*metadata.MetadataSchema } {
        if (id >= self.vectors.items.len) {
            return error.IdNotFound;
        }

        return .{
            .vector = self.vectors.items[id],
            .metadata = self.metadata.items[id],
        };
    }

    pub fn update(self: *Self, id: u64, vector: []const f32, md: ?*metadata.MetadataSchema) !void {
        if (id >= self.vectors.items.len) {
            return error.IdNotFound;
        }

        self.allocator.free(self.vectors.items[id]);
        self.vectors.items[id] = try self.allocator.dupe(f32, vector);

        if (self.metadata.items[id]) |old_md| {
            old_md.deinit();
        }
        self.metadata.items[id] = md;
    }

    pub fn delete(self: *Self, id: u64) !void {
        if (id >= self.vectors.items.len) {
            return error.IdNotFound;
        }

        self.allocator.free(self.vectors.items[id]);
        _ = self.vectors.orderedRemove(id);

        if (self.metadata.items[id]) |md| {
            md.deinit();
        }
        _ = self.metadata.orderedRemove(id);
    }

    pub fn count(self: *const Self) u64 {
        return self.vectors.items.len;
    }
};
