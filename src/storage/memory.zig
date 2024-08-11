const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const MemoryStorage = struct {
    allocator: Allocator,
    vectors: ArrayList([]f32),
    metadata: ArrayList([]u8),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .vectors = ArrayList([]f32).init(allocator),
            .metadata = ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.vectors.items) |vector| {
            self.allocator.free(vector);
        }
        self.vectors.deinit();

        for (self.metadata.items) |md| {
            self.allocator.free(md);
        }
        self.metadata.deinit();
    }

    pub fn add(self: *Self, vector: []const f32, metadata: ?[]const u8) !u64 {
        const new_vector = try self.allocator.dupe(f32, vector);
        try self.vectors.append(new_vector);

        if (metadata) |md| {
            const new_metadata = try self.allocator.dupe(u8, md);
            try self.metadata.append(new_metadata);
        } else {
            try self.metadata.append(&[_]u8{});
        }

        return self.vectors.items.len - 1;
    }

    pub fn get(self: *Self, id: u64) !struct { vector: []const f32, metadata: []const u8 } {
        if (id >= self.vectors.items.len) {
            return error.IdNotFound;
        }

        return .{
            .vector = self.vectors.items[id],
            .metadata = self.metadata.items[id],
        };
    }

    pub fn update(self: *Self, id: u64, vector: []const f32, metadata: ?[]const u8) !void {
        if (id >= self.vectors.items.len) {
            return error.IdNotFound;
        }

        self.allocator.free(self.vectors.items[id]);
        self.vectors.items[id] = try self.allocator.dupe(f32, vector);

        if (metadata) |md| {
            self.allocator.free(self.metadata.items[id]);
            self.metadata.items[id] = try self.allocator.dupe(u8, md);
        }
    }

    pub fn delete(self: *Self, id: u64) !void {
        if (id >= self.vectors.items.len) {
            return error.IdNotFound;
        }

        self.allocator.free(self.vectors.items[id]);
        _ = self.vectors.orderedRemove(id);

        self.allocator.free(self.metadata.items[id]);
        _ = self.metadata.orderedRemove(id);
    }

    pub fn count(self: *const Self) u64 {
        return self.vectors.items.len;
    }
};
