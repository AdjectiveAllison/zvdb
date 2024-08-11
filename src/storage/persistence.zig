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
        std.debug.print("Saving ZVDB to file: {s}\n", .{file_path});
        std.debug.print("Total nodes before serialization: {}\n", .{zvdb.index.getNodeCount()});

        // Prepare file format data
        self.file_format.header = .{
            .magic_number = "ZVDB".*,
            .version = 1,
            .dimension = @intCast(zvdb.config.dimension),
            .distance_function = @intFromEnum(zvdb.config.distance_metric),
            .index_type = @intFromEnum(zvdb.config.index_config),
        };

        const vector_count = zvdb.memory_storage.count();
        self.file_format.vector_count = vector_count;
        self.file_format.vector_data = try zvdb.memory_storage.serializeVectors(self.allocator);
        errdefer self.allocator.free(self.file_format.vector_data);
        self.file_format.metadata = try zvdb.memory_storage.serializeMetadata(self.allocator);
        errdefer self.allocator.free(self.file_format.metadata);

        std.debug.print("Preparing file format data:\n", .{});
        std.debug.print("  Vector count: {}\n", .{vector_count});
        std.debug.print("  Vector data size: {} bytes\n", .{self.file_format.vector_data.len});
        std.debug.print("  Metadata size: {} bytes\n", .{self.file_format.metadata.len});
        std.debug.print("  Index data size: {} bytes\n", .{self.file_format.index_data.len});
        std.debug.print("File header prepared: magic={s}, version={}, dimension={}, distance_function={}, index_type={}\n",
            .{self.file_format.header.magic_number, self.file_format.header.version, self.file_format.header.dimension,
             self.file_format.header.distance_function, self.file_format.header.index_type});

        // Serialize index data
        var index_data = std.ArrayList(u8).init(self.allocator);
        defer index_data.deinit();
        var index_writer = index_data.writer();
        var any_writer = index_writer.any();
        try zvdb.index.serialize(&any_writer);
        self.file_format.index_data = try index_data.toOwnedSlice();

        std.debug.print("Index data serialized: {} bytes\n", .{self.file_format.index_data.len});

        // Write to file
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        const writer = file.writer();
        try self.file_format.write(writer);

        std.debug.print("File written successfully\n", .{});
        std.debug.print("Total size of serialized data: {} bytes\n", .{
            self.file_format.vector_data.len +
            self.file_format.metadata.len +
            self.file_format.index_data.len
        });
    }

    pub fn load(self: *Self, zvdb: *ZVDB, file_path: []const u8) !void {
        std.debug.print("Loading ZVDB from file: {s}\n", .{file_path});

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        std.debug.print("File size: {} bytes\n", .{file_size});

        if (file_size == 0) {
            return error.EmptyFile;
        }

        const reader = file.reader();

        self.file_format.freeAllocatedMemory(); // Clear any existing data
        self.file_format = FileFormat.init(self.allocator);

        // Read and validate file header
        self.file_format.read(reader) catch |err| {
            std.debug.print("Error reading file format: {}\n", .{err});
            switch (err) {
                error.MetadataTooLarge => std.debug.print("Metadata size exceeds the limit. Please check the file integrity.\n", .{}),
                error.MetadataAllocationFailed => std.debug.print("Failed to allocate memory for metadata. This might be due to insufficient memory or an incorrect metadata size in the file.\n", .{}),
                error.EndOfStream => std.debug.print("Unexpected end of file while reading. The file might be truncated.\n", .{}),
                error.InputOutput => std.debug.print("I/O error occurred while reading the file.\n", .{}),
                error.IncompleteRead => std.debug.print("Incomplete read of metadata. The file might be corrupted or truncated.\n", .{}),
                else => std.debug.print("An unexpected error occurred: {}\n", .{err}),
            }
            return err;
        };
        std.debug.print("File format read successfully\n", .{});
        self.validateFileHeader() catch |err| {
            std.debug.print("Error validating file header: {}\n", .{err});
            return err;
        };

        std.debug.print("File header read: magic={s}, version={}, dimension={}, distance_function={}, index_type={}\n",
            .{self.file_format.header.magic_number, self.file_format.header.version, self.file_format.header.dimension,
             self.file_format.header.distance_function, self.file_format.header.index_type});

        // Update ZVDB configuration
        zvdb.config.dimension = self.file_format.header.dimension;
        zvdb.config.distance_metric = @enumFromInt(self.file_format.header.distance_function);

        std.debug.print("ZVDB configuration updated\n", .{});

        // Deserialize index data
        var index_stream = std.io.fixedBufferStream(self.file_format.index_data);
        const index_reader = index_stream.reader();
        var any_reader = index_reader.any();

        zvdb.index.deinit(); // Clear existing index
        zvdb.index = try index.createIndex(self.allocator, zvdb.config.index_config);

        std.debug.print("Deserializing index data ({} bytes)\n", .{self.file_format.index_data.len});
        try zvdb.index.deserialize(&any_reader);

        std.debug.print("Index data deserialized successfully\n", .{});
        std.debug.print("Loaded {} vectors\n", .{zvdb.index.getNodeCount()});

        // Deserialize vectors and metadata
        try zvdb.memory_storage.deserializeVectors(self.allocator, self.file_format.vector_data);
        try zvdb.memory_storage.deserializeMetadata(self.allocator, self.file_format.metadata);

        std.debug.print("Vectors and metadata deserialized successfully\n", .{});
        std.debug.print("Loaded {} vectors into memory storage\n", .{zvdb.memory_storage.count()});
    }
    fn validateFileHeader(self: *Self) !void {
        if (!std.mem.eql(u8, &self.file_format.header.magic_number, "ZVDB")) {
            return error.InvalidFileFormat;
        }

        if (self.file_format.header.version != 1) {
            return error.UnsupportedVersion;
        }

        // Add more validations as needed
    }
};
