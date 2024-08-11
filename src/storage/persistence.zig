const std = @import("std");
const Allocator = std.mem.Allocator;
const FileFormat = @import("file_format.zig").FileFormat;
const MemoryStorage = @import("memory.zig").MemoryStorage;
const ZVDB = @import("../zvdb.zig").ZVDB;
const index = @import("../index/index.zig");
const metadata = @import("../metadata.zig");

pub const Persistence = struct {
    allocator: Allocator,
    file_format: FileFormat,
    memory_storage: MemoryStorage,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .file_format = FileFormat.init(allocator),
            .memory_storage = MemoryStorage.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.file_format.deinit();
        self.memory_storage.deinit();
    }

    pub fn save(self: *Self, zvdb: *ZVDB, file_path: []const u8) !void {
        // Prepare file format data
        self.file_format.header = .{
            .magic_number = "ZVDB".*,
            .version = 1,
            .dimension = @intCast(zvdb.config.dimension),
            .distance_function = @intFromEnum(zvdb.config.distance_metric),
            .index_type = @intFromEnum(zvdb.config.index_config),
        };

        self.file_format.vector_count = self.memory_storage.count();

        // Prepare vector data
        const vector_data_size = self.file_format.vector_count * zvdb.config.dimension * @sizeOf(f32);
        self.file_format.vector_data = try self.allocator.alloc(u8, vector_data_size);
        var vector_data_stream = std.io.fixedBufferStream(self.file_format.vector_data);
        var vector_writer = vector_data_stream.writer();

        // Prepare metadata
        var metadata_list = std.ArrayList(u8).init(self.allocator);
        defer metadata_list.deinit();

        var i: u64 = 0;
        while (i < self.file_format.vector_count) : (i += 1) {
            const item = try self.memory_storage.get(i);
            try vector_writer.writeAll(std.mem.sliceAsBytes(item.vector));
            if (item.metadata) |md| {
                const md_bytes = try md.serialize();
                defer self.allocator.free(md_bytes);
                try metadata_list.appendSlice(md_bytes);
            } else {
                try metadata_list.append(0); // Indicate no metadata
            }
        }

        self.file_format.metadata = try metadata_list.toOwnedSlice();

        // Serialize index data
        var index_data = std.ArrayList(u8).init(self.allocator);
        defer index_data.deinit();
        var index_writer = index_data.writer();
        var any_writer = index_writer.any();
        try zvdb.index.serialize(&any_writer);
        self.file_format.index_data = try index_data.toOwnedSlice();

        // Write to file
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try self.file_format.write(file.writer());
    }

    pub fn load(self: *Self, zvdb: *ZVDB, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        try self.file_format.read(file.reader());

        // Validate file format
        if (!std.mem.eql(u8, &self.file_format.header.magic_number, "ZVDB")) {
            return error.InvalidFileFormat;
        }

        if (self.file_format.header.version != 1) {
            return error.UnsupportedVersion;
        }

        // Update ZVDB configuration
        zvdb.config.dimension = self.file_format.header.dimension;
        zvdb.config.distance_metric = @enumFromInt(self.file_format.header.distance_function);

        // Convert index_type to IndexConfig
        const index_type = @as(index.IndexType, @enumFromInt(self.file_format.header.index_type));
        zvdb.config.index_config = switch (index_type) {
            .HNSW => index.IndexConfig{
                .HNSW = .{
                    // You might need to load these values from the file as well
                    .max_connections = 16,
                    .ef_construction = 200,
                    .ef_search = 50,
                },
            },
            // Add cases for other index types here
        };

        // Load vectors and metadata into memory storage
        var vector_stream = std.io.fixedBufferStream(self.file_format.vector_data);
        var vector_reader = vector_stream.reader();

        var metadata_stream = std.io.fixedBufferStream(self.file_format.metadata);
        var metadata_reader = metadata_stream.reader();

        var i: u64 = 0;
        while (i < self.file_format.vector_count) : (i += 1) {
            const vector = try self.allocator.alloc(f32, zvdb.config.dimension);
            errdefer self.allocator.free(vector);
            try vector_reader.readNoEof(std.mem.sliceAsBytes(vector));

            const has_metadata = try metadata_reader.readByte();
            const md = if (has_metadata == 1) blk: {
                const metadata_size = try metadata_reader.readInt(u32, .little);
                const metadata_bytes = try self.allocator.alloc(u8, metadata_size);
                defer self.allocator.free(metadata_bytes);
                try metadata_reader.readNoEof(metadata_bytes);

                break :blk try metadata.MetadataSchema.deserialize(self.allocator, metadata_bytes);
            } else null;

            _ = try self.memory_storage.add(vector, md);
        }

        // Deserialize index data
        var index_stream = std.io.fixedBufferStream(self.file_format.index_data);
        const index_reader = index_stream.reader();
        var any_reader = index_reader.any();
        try zvdb.index.deserialize(&any_reader);
    }
};
