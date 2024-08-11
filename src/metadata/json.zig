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
            .data = json.Value{ .Object = json.ObjectMap.init(allocator) },
        };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }

    pub fn set(self: *Self, key: []const u8, value: json.Value) !void {
        try self.data.Object.put(key, value);
    }

    pub fn get(self: *const Self, key: []const u8) ?json.Value {
        return self.data.Object.get(key);
    }

    pub fn validate(self: *const Self, schema: *const Schema) !void {
        try schema.validate(self.data);
    }

    pub fn toJsonString(self: *const Self) ![]u8 {
        var string = std.ArrayList(u8).init(self.allocator);
        try json.stringify(self.data, .{}, string.writer());
        return string.toOwnedSlice();
    }

    pub fn fromJsonString(allocator: Allocator, json_string: []const u8) !Self {
        var parser = json.Parser.init(allocator, false);
        defer parser.deinit();

        const data = try parser.parse(json_string);

        return Self{
            .allocator = allocator,
            .data = data,
        };
    }
};
