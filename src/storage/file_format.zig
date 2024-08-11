const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FileHeader = struct {
    magic_number: [4]u8,
    version: u32,
    dimension: u32,
    distance_function: u8,
    index_type: u8,
    metadata_schema_length: u32,
};

pub const FileFormat = struct {
    allocator: Allocator,
    header: FileHeader,
    metadata_schema: []u8,
    vector_count: u64,
    vector_data: []u8,
    metadata: []u8,
    index_data: []u8,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .header = undefined,
            .metadata_schema = &[_]u8{},
            .vector_count = 0,
            .vector_data = &[_]u8{},
            .metadata = &[_]u8{},
            .index_data = &[_]u8{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.metadata_schema);
        self.allocator.free(self.vector_data);
        self.allocator.free(self.metadata);
        self.allocator.free(self.index_data);
    }

    pub fn write(self: *const Self, writer: anytype) !void {
        try writer.writeAll(&self.header.magic_number);
        try writer.writeIntLittle(u32, self.header.version);
        try writer.writeIntLittle(u32, self.header.dimension);
        try writer.writeByte(self.header.distance_function);
        try writer.writeByte(self.header.index_type);
        try writer.writeIntLittle(u32, self.header.metadata_schema_length);

        try writer.writeAll(self.metadata_schema);
        try writer.writeIntLittle(u64, self.vector_count);
        try writer.writeAll(self.vector_data);
        try writer.writeAll(self.metadata);
        try writer.writeAll(self.index_data);
    }

    pub fn read(self: *Self, reader: anytype) !void {
        self.header.magic_number = try reader.readBytesNoEof(4);
        self.header.version = try reader.readIntLittle(u32);
        self.header.dimension = try reader.readIntLittle(u32);
        self.header.distance_function = try reader.readByte();
        self.header.index_type = try reader.readByte();
        self.header.metadata_schema_length = try reader.readIntLittle(u32);

        self.metadata_schema = try self.allocator.alloc(u8, self.header.metadata_schema_length);
        try reader.readNoEof(self.metadata_schema);

        self.vector_count = try reader.readIntLittle(u64);
        const vector_data_size = self.vector_count * self.header.dimension * @sizeOf(f32);
        self.vector_data = try self.allocator.alloc(u8, vector_data_size);
        try reader.readNoEof(self.vector_data);

        // Read metadata and index data
        // Note: The exact format of metadata and index data may need to be adjusted
        // based on your specific implementation requirements
        const remaining_size = try reader.readAll(self.allocator.allocator);
        const metadata_size = remaining_size / 2;
        self.metadata = remaining_size[0..metadata_size];
        self.index_data = remaining_size[metadata_size..];
    }
};
