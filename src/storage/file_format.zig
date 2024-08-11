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

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .header = undefined,
            .vector_count = 0,
            .vector_data = &[_]u8{},
            .metadata = &[_]u8{},
            .index_data = &[_]u8{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.vector_data);
        self.allocator.free(self.metadata);
        self.allocator.free(self.index_data);
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
        self.header.magic_number = try reader.readBytesNoEof(4);
        self.header.version = try reader.readInt(u32, .little);
        self.header.dimension = try reader.readInt(u32, .little);
        self.header.distance_function = try reader.readByte();
        self.header.index_type = try reader.readByte();

        self.vector_count = try reader.readInt(u64, .little);
        const vector_data_size = self.vector_count * self.header.dimension * @sizeOf(f32);
        self.vector_data = try self.allocator.alloc(u8, vector_data_size);
        try reader.readNoEof(self.vector_data);

        // Read metadata and index data
        var remaining_data = std.ArrayList(u8).init(self.allocator);
        defer remaining_data.deinit();
        try reader.readAllArrayList(&remaining_data, std.math.maxInt(usize));

        const metadata_size = remaining_data.items.len / 2;
        self.metadata = try self.allocator.dupe(u8, remaining_data.items[0..metadata_size]);
        self.index_data = try self.allocator.dupe(u8, remaining_data.items[metadata_size..]);
        std.debug.print("Read file format: vector_count={}, vector_data={} bytes, metadata={} bytes, index_data={} bytes\n", .{
            self.vector_count,
            self.vector_data.len,
            self.metadata.len,
            self.index_data.len,
        });
    }
};
