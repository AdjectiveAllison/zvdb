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
        .string => |s| {
            const new_str = try allocator.dupe(u8, s);
            return .{ .string = new_str };
        },
        .array => |arr| {
            var new_arr = try json.Array.initCapacity(allocator, arr.items.len);
            errdefer new_arr.deinit();
            for (arr.items) |item| {
                const new_item = try cloneValue(allocator, item);
                errdefer deinitValue(allocator, new_item);
                try new_arr.append(new_item);
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = json.ObjectMap.init(allocator);
            errdefer {
                var it = new_obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitValue(allocator, entry.value_ptr.*);
                }
                new_obj.deinit();
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const new_key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(new_key);
                const new_value = try cloneValue(allocator, entry.value_ptr.*);
                errdefer deinitValue(allocator, new_value);
                try new_obj.put(new_key, new_value);
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
