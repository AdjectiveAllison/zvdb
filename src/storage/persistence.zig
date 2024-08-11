const std = @import("std");
const Allocator = std.mem.Allocator;
const FileFormat = @import("file_format.zig").FileFormat;
const MemoryStorage = @import("memory.zig").MemoryStorage;
const ZVDB = @import("../zvdb.zig").ZVDB;

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
            .metadata_schema_length = @intCast(zvdb.config.metadata_schema.len),
        };

        self.file_format.metadata_schema = try self.allocator.dupe(u8, zvdb.config.metadata_schema);
        self.file_format.vector_count = self.memory_storage.count();

        // Prepare vector data
        const vector_data_size = self.file_format.vector_count * zvdb.config.dimension * @sizeOf(f32);
        self.file_format.vector_data = try self.allocator.alloc(u8, vector_data_size);
        var vector_writer = std.io.fixedBufferStream(self.file_format.vector_data).writer();

        // Prepare metadata
        var metadata_list = std.ArrayList(u8).init(self.allocator);
        defer metadata_list.deinit();

        var i: u64 = 0;
        while (i < self.file_format.vector_count) : (i += 1) {
            const item = try self.memory_storage.get(i);
            try vector_writer.writeAll(std.mem.sliceAsBytes(item.vector));
            try metadata_list.appendSlice(item.metadata);
        }

        self.file_format.metadata = try metadata_list.toOwnedSlice();

        // Serialize index data (this part may need to be adjusted based on your index implementation)
        var index_data = std.ArrayList(u8).init(self.allocator);
        defer index_data.deinit();
        try zvdb.index.serialize(index_data.writer());
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
        zvdb.config.index_config = @enumFromInt(self.file_format.header.index_type);
        zvdb.config.metadata_schema = try self.allocator.dupe(u8, self.file_format.metadata_schema);

        // Load vectors and metadata into memory storage
        var vector_reader = std.io.fixedBufferStream(self.file_format.vector_data).reader();
        var metadata_reader = std.io.fixedBufferStream(self.file_format.metadata).reader();

        var i: u64 = 0;
        while (i < self.file_format.vector_count) : (i += 1) {
            const vector = try self.allocator.alloc(f32, zvdb.config.dimension);
            try vector_reader.readNoEof(std.mem.sliceAsBytes(vector));

            const metadata = try self.allocator.alloc(u8, zvdb.config.metadata_schema.len);
            try metadata_reader.readNoEof(metadata);

            _ = try self.memory_storage.add(vector, metadata);
        }

        // Deserialize index data (this part may need to be adjusted based on your index implementation)
        const index_reader = std.io.fixedBufferStream(self.file_format.index_data).reader();
        try zvdb.index.deserialize(index_reader);
    }
};
