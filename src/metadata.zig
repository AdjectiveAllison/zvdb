const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const MetadataSchema = struct {
    allocator: Allocator,
    name: ?[]const u8,
    value: ?f64,
    tags: ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .name = null,
            .value = null,
            .tags = ArrayList([]const u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.name) |name| self.allocator.free(name);
        for (self.tags.items) |tag| {
            self.allocator.free(tag);
        }
        self.tags.deinit();
        self.allocator.destroy(self);
    }

    pub fn validate(self: *const Self) !void {
        if (self.name == null and self.value == null and self.tags.items.len == 0) {
            return error.InvalidMetadata;
        }
    }

    pub fn serialize(self: *const Self) ![]u8 {
        var list = ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

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
        var self = try Self.init(allocator);
        errdefer self.deinit();

        var lines = std.mem.splitSequence(u8, data, "\n");
        while (lines.next()) |line| {
            var kv = std.mem.splitSequence(u8, line, ":");
            const key = kv.next() orelse continue;
            const value = kv.next() orelse continue;

            if (std.mem.eql(u8, key, "name")) {
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
};
