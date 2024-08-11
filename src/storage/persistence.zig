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


        std.debug.print("Preparing file format data:\n", .{});
        std.debug.print("  Vector count: {}\n", .{zvdb.memory_storage.count()});
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

        const reader = file.reader();
        try self.file_format.read(reader);

        std.debug.print("File header read: magic={s}, version={}, dimension={}, distance_function={}, index_type={}\n",
            .{self.file_format.header.magic_number, self.file_format.header.version, self.file_format.header.dimension,
             self.file_format.header.distance_function, self.file_format.header.index_type});

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

        std.debug.print("ZVDB configuration updated\n", .{});

        // Deserialize index data
        std.debug.print("Index data size before deserialization: {} bytes\n", .{self.file_format.index_data.len});

        var index_stream = std.io.fixedBufferStream(self.file_format.index_data);
        const index_reader = index_stream.reader();
        var any_reader = index_reader.any();
        try zvdb.index.deserialize(&any_reader);

        std.debug.print("Index data deserialized successfully\n", .{});

        std.debug.print("Loaded file format data:\n", .{});
        std.debug.print("  Vector count: {}\n", .{self.file_format.vector_count});
        std.debug.print("  Vector data size: {} bytes\n", .{self.file_format.vector_data.len});
        std.debug.print("  Metadata size: {} bytes\n", .{self.file_format.metadata.len});
        std.debug.print("  Index data size: {} bytes\n", .{self.file_format.index_data.len});
    }
};
