const std = @import("std");
const zvdb = @import("zvdb");

pub fn main() !void {
    // Initialize the allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure ZVDB
    var zvdb_config = try zvdb.config.Config.init(
        allocator,
        3,
        .Euclidean,
        .{ .HNSW = .{
            .max_connections = 16,
            .ef_construction = 200,
            .ef_search = 50,
        } },
        "zvdb_data.bin",
    );
    defer zvdb_config.deinit();

    // Initialize ZVDB
    var db = try zvdb.ZVDB.init(allocator, zvdb_config);
    defer db.deinit();

    // Add vectors with metadata
    const vector1 = [_]f32{ 1.0, 2.0, 3.0 };
    var metadata1 = try allocator.create(zvdb.metadata.MetadataSchema);
    metadata1.* = zvdb.metadata.MetadataSchema.init(allocator);
    defer {
        metadata1.deinit();
        allocator.destroy(metadata1);
    }
    try metadata1.setName("Point A");
    metadata1.value = 42.0;
    try metadata1.addTag("tag1");
    try metadata1.addTag("tag2");

    // ... and similarly for metadata2 ...

    const id1 = try db.add(&vector1, metadata1);
    std.debug.print("Added vector with ID: {}\n", .{id1});

    const vector2 = [_]f32{ 4.0, 5.0, 6.0 };
    var metadata2 = try allocator.create(zvdb.metadata.MetadataSchema);
    metadata2.* = zvdb.metadata.MetadataSchema.init(allocator);
    defer {
        metadata2.deinit();
        allocator.destroy(metadata2);
    }
    try metadata2.setName("Point B");
    metadata2.value = 73.0;
    try metadata2.addTag("tag3");

    const id2 = try db.add(&vector2, metadata2);
    std.debug.print("Added vector with ID: {}\n", .{id2});

    // Perform a search
    const query = [_]f32{ 2.0, 3.0, 4.0 };
    const search_results = try db.search(&query, 2);
    defer {
        for (search_results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(search_results);
    }

    std.debug.print("Search results:\n", .{});
    for (search_results) |result| {
        std.debug.print("  ID: {}, Distance: {d:.4}\n", .{ result.id, result.distance });
        if (result.metadata) |md| {
            if (md.name) |name| {
                std.debug.print("    Name: {s}\n", .{name});
            }
            if (md.value) |value| {
                std.debug.print("    Value: {d:.2}\n", .{value});
            }
            if (md.tags.items.len > 0) {
                const tags = md.tags.items;
                std.debug.print("    Tags: ", .{});
                for (tags) |tag| {
                    std.debug.print("{s} ", .{tag});
                }
                std.debug.print("\n", .{});
            }
        } else {
            std.debug.print("    No metadata\n", .{});
        }
    }

    // Update a vector and its metadata
    const updated_vector = [_]f32{ 1.5, 2.5, 3.5 };
    var updated_metadata = zvdb.metadata.MetadataSchema.init(allocator);
    defer updated_metadata.deinit();
    try updated_metadata.setName("Updated Point A");
    updated_metadata.value = 50.0;

    try db.update(id1, &updated_vector, updated_metadata);
    std.debug.print("Updated vector with ID: {}\n", .{id1});

    // Delete a vector
    try db.delete(id2);
    std.debug.print("Deleted vector with ID: {}\n", .{id2});

    // Save the database to disk
    try db.save("zvdb_data.bin");
    std.debug.print("Database saved to disk\n", .{});

    // Load the database from disk
    var loaded_db = try zvdb.ZVDB.init(allocator, zvdb_config);
    defer loaded_db.deinit();
    try loaded_db.load("zvdb_data.bin");
    std.debug.print("Database loaded from disk\n", .{});

    // Perform a search on the loaded database
    const loaded_search_results = try loaded_db.search(&query, 2);
    defer {
        for (loaded_search_results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(loaded_search_results);
    }

    std.debug.print("Search results after loading:\n", .{});
    for (loaded_search_results) |result| {
        std.debug.print("  ID: {}, Distance: {d:.4}\n", .{ result.id, result.distance });
        if (result.metadata) |md| {
            std.debug.print("    Metadata: name={s}, value={d:.2}\n", .{ md.name orelse "N/A", md.value orelse 0 });
        } else {
            std.debug.print("    Metadata: None\n", .{});
        }
    }
}
