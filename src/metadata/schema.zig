const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Metadata = @import("json.zig").Metadata;

pub const SchemaError = error{
    InvalidSchema,
    ValidationFailed,
};

pub const Schema = struct {
    allocator: Allocator,
    schema: json.Value,

    const Self = @This();

    pub fn init(allocator: Allocator, schema_str: []const u8) !Self {
        var parsed = try json.parseFromSlice(json.Value, allocator, schema_str, .{});
        defer parsed.deinit();

        return Self{
            .allocator = allocator,
            .schema = try cloneValue(allocator, parsed.value),
        };
    }

    pub fn deinit(self: *Self) void {
        deinitValue(self.allocator, self.schema);
    }

    pub fn validate(self: *const Self, metadata: *const Metadata) SchemaError!void {
        // TODO: Implement schema validation
        // This is a placeholder implementation
        _ = self;
        _ = metadata.getValue();
    }

    pub fn update(self: *Self, new_schema_str: []const u8) !void {
        var parsed = try json.parseFromSlice(json.Value, self.allocator, new_schema_str, .{});
        defer parsed.deinit();

        const new_schema = try cloneValue(self.allocator, parsed.value);
        self.schema.deinit(self.allocator);
        self.schema = new_schema;
    }
};

// I doubt this is needed, I was just getting past build errors. Probably something in std lib would work better.
pub fn cloneValue(allocator: Allocator, value: json.Value) !json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = try json.Array.initCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                try new_arr.append(try cloneValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                try new_obj.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = new_obj };
        },
    };
}

pub fn deinitValue(allocator: Allocator, value: json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| {
                deinitValue(allocator, item);
            }
            arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitValue(allocator, entry.value_ptr.*);
            }
            // Create a mutable copy of the object to call deinit()
            var mutable_obj = obj;
            mutable_obj.deinit();
        },
        else => {},
    }
}
