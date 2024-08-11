const std = @import("std");
const Allocator = std.mem.Allocator;
const hnsw = @import("hnsw.zig");
const config = @import("../config.zig");

pub const IndexType = enum {
    HNSW,
    // Add other index types here in the future
};

pub const IndexConfig = union(IndexType) {
    HNSW: hnsw.HNSWConfig,
    // Add configurations for other index types here in the future
};

pub const Index = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque) void,
        addFn: *const fn (ptr: *anyopaque, vector: []const f32) Allocator.Error!u64,
        searchFn: *const fn (allocator: Allocator, ptr: *anyopaque, query: []const f32, limit: usize) Allocator.Error![]SearchResult,
        deleteFn: *const fn (ptr: *anyopaque, id: u64) (Allocator.Error || error{NodeNotFound})!void,
        updateFn: *const fn (ptr: *anyopaque, id: u64, vector: []const f32) (Allocator.Error || error{NodeNotFound})!void,
        serializeFn: *const fn (ptr: *anyopaque, writer: *std.io.AnyWriter) anyerror!void,
        deserializeFn: *const fn (ptr: *anyopaque, reader: *std.io.AnyReader) anyerror!void,
    };

    pub fn deinit(self: *Index) void {
        self.vtable.deinitFn(self.ptr);
    }

    pub fn add(self: *Index, vector: []const f32) Allocator.Error!u64 {
        return self.vtable.addFn(self.ptr, vector);
    }

    pub fn search(self: *Index, allocator: std.mem.Allocator, query: []const f32, limit: usize) Allocator.Error![]SearchResult {
        return self.vtable.searchFn(allocator, self.ptr, query, limit);
    }

    pub fn delete(self: *Index, id: u64) (Allocator.Error || error{NodeNotFound})!void {
        return self.vtable.deleteFn(self.ptr, id);
    }

    pub fn update(self: *Index, id: u64, vector: []const f32) (Allocator.Error || error{NodeNotFound})!void {
        return self.vtable.updateFn(self.ptr, id, vector);
    }

    pub fn serialize(self: *Index, writer: *std.io.AnyWriter) !void {
        return self.vtable.serializeFn(self.ptr, writer);
    }

    pub fn deserialize(self: *Index, reader: *std.io.AnyReader) !void{
        return self.vtable.deserializeFn(self.ptr, reader);
    }
};

pub const SearchResult = struct {
    id: u64,
    similarity: f32,
};

pub fn createIndex(allocator: Allocator, index_config: IndexConfig) Allocator.Error!Index {
    switch (index_config) {
        .HNSW => |hnsw_config| {
            const hnsw_ptr = try allocator.create(hnsw.HNSW);
            errdefer allocator.destroy(hnsw_ptr);
            hnsw_ptr.* = try hnsw.HNSW.init(allocator, hnsw_config, .Euclidean);

            const vtable = &.{
                .deinitFn = &deinitHNSW,
                .addFn = &addHNSW,
                .searchFn = &searchHNSW,
                .deleteFn = &deleteHNSW,
                .updateFn = &updateHNSW,
                .serializeFn = &serializeHNSW,
                .deserializeFn = &deserializeHNSW,
            };

            return Index{
                .ptr = hnsw_ptr,
                .vtable = vtable,
            };
        },
        // Add cases for other index types here in the future
    }
}

fn deinitHNSW(ptr: *anyopaque) void {
    const self = @as(*hnsw.HNSW, @ptrCast(@alignCast(ptr)));
    self.deinit();
    self.allocator.destroy(self);
}

fn addHNSW(ptr: *anyopaque, vector: []const f32) Allocator.Error!u64 {
    const self = @as(*hnsw.HNSW, @ptrCast(@alignCast(ptr)));
    return self.addItem(vector);
}

fn searchHNSW(allocator: std.mem.Allocator, ptr: *anyopaque, query: []const f32, limit: usize) Allocator.Error![]SearchResult {
    const self = @as(*hnsw.HNSW, @ptrCast(@alignCast(ptr)));
    const results = try self.searchKnn(query, limit);
    defer allocator.free(results);

    var search_results = try allocator.alloc(SearchResult, results.len);
    for (results, 0..) |result, i| {
        search_results[i] = SearchResult{
            .id = result.id,
            .similarity = 1.0 - result.distance, // Convert distance to similarity
        };
    }
    return search_results;
}

fn deleteHNSW(ptr: *anyopaque, id: u64) (Allocator.Error || error{NodeNotFound})!void {
    const self = @as(*hnsw.HNSW, @ptrCast(@alignCast(ptr)));
    try self.deleteItem(id);
}

fn updateHNSW(ptr: *anyopaque, id: u64, vector: []const f32) (Allocator.Error || error{NodeNotFound})!void {
    const self = @as(*hnsw.HNSW, @ptrCast(@alignCast(ptr)));
    try self.updateItem(id, vector);
}

fn serializeHNSW(ptr: *anyopaque, writer: *std.io.AnyWriter) !void {
    const self = @as(*hnsw.HNSW, @ptrCast(@alignCast(ptr)));
    try self.serialize(writer);
}

fn deserializeHNSW(ptr: *anyopaque, reader: *std.io.AnyReader) !void {
    const self = @as(*hnsw.HNSW, @ptrCast(@alignCast(ptr)));
    try self.deserialize(reader);
}
