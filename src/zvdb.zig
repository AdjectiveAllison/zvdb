pub const HNSW = @import("hnsw.zig").HNSW;
pub const HMMIS = @import("hmmis.zig").HMMIS;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Database = struct {
    const Self = @This();
    alllocator: Allocator,
    collections: std.AutoHashMap([]const u8, Collection),

    pub fn init(allocator: Allocator) Database {
        return Database{
            .alllocator = allocator,
            .collections = std.AutoHashMap([]const u8, Collection).init(allocator),
        };
    }

    pub fn deinit(self: *Self) !void {
        // more crap for handling memory and stuff to go here
        self.collections.deinit();
    }
    // do some stuff here

    pub fn create_collection(self: *Database, name: []const u8, comptime embedding_type: type, comptime embedding_length: comptime_int) !void {
        if (self.collections.contains(name)) {
            return error.CollectionAlreadyInDatabase;
        }

        var new_collection: Collection = undefined;
        try new_collection.init(self.allocator, embedding_type, embedding_length);
        // self.collections[name]
    }
};

pub const Collection = struct {
    const Self = @This();
    // other collection-based proprties
    allocator: Allocator,
    index: HMMIS,

    pub fn init(self: *Self, allocator: Allocator, comptime embedding_type: type, comptime embedding_length: comptime_int) !void {
        self.* = .{
            .allocator = allocator,
            .index = HMMIS(embedding_type, embedding_length).init(allocator, .{}),
        };
    }
};
