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

        const writer = file.writer();
        try self.file_format.write(writer);
    }

    pub fn load(self: *Self, zvdb: *ZVDB, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const reader = file.reader();
        try self.file_format.read(reader);

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

        // Deserialize index data
        var index_stream = std.io.fixedBufferStream(self.file_format.index_data);
        const index_reader = index_stream.reader();
        var any_reader = index_reader.any();
        try zvdb.index.deserialize(&any_reader);
    }
};
