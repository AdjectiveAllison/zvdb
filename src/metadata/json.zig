const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Schema = @import("schema.zig").Schema;

pub const Metadata = struct {
    allocator: Allocator,
    data: json.Value,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .data = json.Value{ .object = json.ObjectMap.init(allocator) },
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.data) {
            .null => {},
            .bool => {},
            .integer => {},
            .float => {},
            .number_string => |str| self.allocator.free(str),
            .string => |str| self.allocator.free(str),
            .array => |*arr| arr.deinit(),
            .object => |*obj| obj.deinit(),
        }
    }

    pub fn set(self: *Self, key: []const u8, value: json.Value) !void {
        try self.data.object.put(key, value);
    }

    pub fn get(self: *const Self, key: []const u8) ?json.Value {
        return self.data.object.get(key);
    }

    pub fn validate(self: *const Self, schema: *const Schema) !void {
        try schema.validate(self);
    }

    pub fn toJsonString(self: *const Self) ![]u8 {
        var string = std.ArrayList(u8).init(self.allocator);
        defer string.deinit();

        try json.stringify(self.data, .{}, string.writer());
        return string.toOwnedSlice();
    }

    //TODO: This likely needs to be an arena specific allocator otherwise we can't use parseFromSliceLeaky.
    pub fn fromJsonString(allocator: Allocator, json_string: []const u8) !Self {
        const parsed_value = try json.parseFromSliceLeaky(json.Value, allocator, json_string, .{});
        return Self{
            .allocator = allocator,
            .data = parsed_value,
        };
    }

    pub fn getValue(self: *const Self) json.Value {
        return self.data;
    }
};
