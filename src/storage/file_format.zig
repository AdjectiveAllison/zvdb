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

    pub fn verifyFileFormat(file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var buffer: [1024]u8 = undefined;
        const bytes_read = try file.readAll(&buffer);

        std.debug.print("File format verification:\n", .{});
        std.debug.print("Total bytes read: {}\n", .{bytes_read});

        if (bytes_read < 16) {
            return error.InvalidFileFormat;
        }

        // Verify magic number
        if (!std.mem.eql(u8, buffer[0..4], "ZVDB")) {
            return error.InvalidMagicNumber;
        }
        std.debug.print("Magic number: OK\n", .{});

        // Verify version
        const version = std.mem.readIntLittle(u32, buffer[4..8]);
        std.debug.print("Version: {}\n", .{version});

        // Verify dimension
        const dimension = std.mem.readIntLittle(u32, buffer[8..12]);
        std.debug.print("Dimension: {}\n", .{dimension});

        // Verify distance function and index type
        std.debug.print("Distance function: {}\n", .{buffer[12]});
        std.debug.print("Index type: {}\n", .{buffer[13]});

        // Print the rest of the buffer for inspection
        std.debug.print("File content preview:\n", .{});
        var i: usize = 0;
        while (i < bytes_read) : (i += 1) {
            if (i % 16 == 0) {
                std.debug.print("\n{X:0>4}: ", .{i});
            }
            std.debug.print("{X:0>2} ", .{buffer[i]});
        }
        std.debug.print("\n", .{});
    }

    pub fn readHeader(self: *Self, reader: anytype) !void {
        self.header.magic_number = try reader.readBytesNoEof(4);
        self.header.version = try reader.readInt(u32, .little);
        self.header.dimension = try reader.readInt(u32, .little);
        self.header.distance_function = try reader.readByte();
        self.header.index_type = try reader.readByte();
        std.debug.print("Header read: {any}\n", .{self.header});
    }

    pub fn readVectorData(self: *Self, reader: anytype) !void {
        self.vector_count = try reader.readInt(u64, .little);
        const vector_data_size = self.vector_count * self.header.dimension * @sizeOf(f32);
        self.vector_data = try self.allocator.alloc(u8, vector_data_size);
        const bytes_read = try reader.readAll(self.vector_data);
        if (bytes_read != vector_data_size) {
            return error.IncompleteVectorData;
        }
        std.debug.print("Vector data read: count={}, size={} bytes\n", .{self.vector_count, vector_data_size});
    }

    pub fn readMetadata(self: *Self, reader: anytype) !void {
        const metadata_size = try reader.readInt(u32, .little);
        std.debug.print("Metadata size read: {} bytes\n", .{metadata_size});
        if (metadata_size > 10_000_000) { // 10 MB limit
            return error.MetadataTooLarge;
        }
        self.metadata = try self.allocator.alloc(u8, metadata_size);
        const bytes_read = try reader.readAll(self.metadata);
        if (bytes_read != metadata_size) {
            return error.IncompleteMetadata;
        }
        std.debug.print("Metadata read: {} bytes\n", .{bytes_read});
    }

    pub fn read(self: *Self, reader: anytype) !void {
        try self.readHeader(reader);
        try self.readVectorData(reader);
        try self.readMetadata(reader);
    }
};
