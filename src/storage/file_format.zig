const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FileHeader = struct {
    magic_number: [4]u8,
    version: u32,
    dimension: u32,
    distance_function: u8,
    index_type: u8,
};

pub const FileFormat = struct {
    allocator: Allocator,
    header: FileHeader,
    vector_count: u64,
    vector_data: []u8,
    metadata: []u8,
    index_data: []u8,
    has_allocated: bool,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .header = undefined,
            .vector_count = 0,
            .vector_data = &[_]u8{},
            .metadata = &[_]u8{},
            .index_data = &[_]u8{},
            .has_allocated = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.has_allocated) {
            self.allocator.free(self.vector_data);
            self.allocator.free(self.metadata);
            self.allocator.free(self.index_data);
            self.has_allocated = false;
        }
    }

    pub fn freeAllocatedMemory(self: *Self) void {
        self.deinit();
        self.vector_data = &[_]u8{};
        self.metadata = &[_]u8{};
        self.index_data = &[_]u8{};
    }

    pub fn write(self: *const Self, writer: anytype) !void {
        std.debug.print("Writing file format: vector_count={}, vector_data={} bytes, metadata={} bytes, index_data={} bytes\n", .{
            self.vector_count,
            self.vector_data.len,
            self.metadata.len,
            self.index_data.len,
        });
        try writer.writeAll(&self.header.magic_number);
        try writer.writeInt(u32, self.header.version, .little);
        try writer.writeInt(u32, self.header.dimension, .little);
        try writer.writeByte(self.header.distance_function);
        try writer.writeByte(self.header.index_type);

        try writer.writeInt(u64, self.vector_count, .little);
        try writer.writeAll(self.vector_data);
        try writer.writeAll(self.metadata);
        try writer.writeAll(self.index_data);
    }

    pub fn read(self: *Self, reader: anytype) !void {
        // Free previously allocated memory if any
        self.deinit();

        self.header.magic_number = try reader.readBytesNoEof(4);
        self.header.version = try reader.readInt(u32, .little);
        self.header.dimension = try reader.readInt(u32, .little);
        self.header.distance_function = try reader.readByte();
        self.header.index_type = try reader.readByte();

        self.vector_count = try reader.readInt(u64, .little);
        const vector_data_size = self.vector_count * self.header.dimension * @sizeOf(f32);
        self.vector_data = try self.allocator.alloc(u8, vector_data_size);
        errdefer self.allocator.free(self.vector_data);
        const bytes_read = try reader.readAll(self.vector_data);
        if (bytes_read != vector_data_size) {
            return error.IncompleteRead;
        }

        const metadata_size = reader.readInt(u64, .little) catch |err| {
            std.debug.print("Error reading metadata size: {}\n", .{err});
            return err;
        };
        std.debug.print("Read metadata size: {} bytes\n", .{metadata_size});
        if (metadata_size > 10_000_000_000) { // 10 GB limit
            std.debug.print("Metadata size exceeds limit of 10 GB\n", .{});
            return error.MetadataTooLarge;
        }
        if (metadata_size == 0) {
            std.debug.print("Warning: Metadata size is 0\n", .{});
            self.metadata = &[_]u8{};
        } else {
            self.metadata = self.allocator.alloc(u8, metadata_size) catch |err| {
                std.debug.print("Failed to allocate memory for metadata. Size: {} bytes, Error: {}\n", .{metadata_size, err});
                return error.MetadataAllocationFailed;
            };
        }
        std.debug.print("Allocated memory for metadata: {} bytes\n", .{self.metadata.len});
        errdefer self.allocator.free(self.metadata);
        const metadata_bytes_read = try reader.readAll(self.metadata);
        if (metadata_bytes_read != metadata_size) {
            return error.IncompleteRead;
        }

        const index_data_size = try reader.readInt(u64, .little);
        self.index_data = try self.allocator.alloc(u8, index_data_size);
        errdefer self.allocator.free(self.index_data);
        const index_bytes_read = try reader.readAll(self.index_data);
        if (index_bytes_read != index_data_size) {
            return error.IncompleteRead;
        }

        self.has_allocated = true;

        std.debug.print("Read file format: vector_count={}, vector_data={} bytes, metadata={} bytes, index_data={} bytes\n", .{
            self.vector_count,
            self.vector_data.len,
            self.metadata.len,
            self.index_data.len,
        });
    }
};
