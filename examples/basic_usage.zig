const std = @import("std");
const zvdb = @import("zvdb");

pub fn main() !void {
    // Initialize the allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure ZVDB
    const zvdb_config = zvdb.config.Config{
        .dimension = 3,
        .distance_metric = .Euclidean,
        .index_config = .{ .HNSW = .{
            .max_connections = 16,
            .ef_construction = 200,
            .ef_search = 50,
        } },
        .metadata_schema =
        \\{
        \\    "type": "object",
        \\    "properties": {
        \\        "name": { "type": "string" },
        \\        "value": { "type": "number" }
        \\    },
        \\    "required": ["name", "value"]
        \\}
        ,
        .storage_path = "zvdb_data.bin",
    };

    // Initialize ZVDB
    var db = try zvdb.ZVDB.init(allocator, zvdb_config);
    defer db.deinit();

    // Add vectors with metadata
    const vector1 = [_]f32{ 1.0, 2.0, 3.0 };
    var metadata1 = zvdb.metadata.json.Metadata.init(allocator);
    defer metadata1.deinit();
    try metadata1.set("name", .{ .string = "Point A" });
    try metadata1.set("value", .{ .float = 42.0 });

    const id1 = try db.add(&vector1, metadata1);
    std.debug.print("Added vector with ID: {}\n", .{id1});

    const vector2 = [_]f32{ 4.0, 5.0, 6.0 };
    var metadata2 = zvdb.metadata.json.Metadata.init(allocator);
    defer metadata2.deinit();
    try metadata2.set("name", .{ .string = "Point B" });
    try metadata2.set("value", .{ .float = 73.0 });

    const id2 = try db.add(&vector2, metadata2);
    std.debug.print("Added vector with ID: {}\n", .{id2});

    // Perform a search
    const query = [_]f32{ 2.0, 3.0, 4.0 };
    const search_results = try db.search(&query, 2);
    defer allocator.free(search_results);

    std.debug.print("Search results:\n", .{});
    for (search_results) |result| {
        std.debug.print("  ID: {}, Distance: {d:.4}\n", .{ result.id, result.distance });
        if (result.metadata) |md| {
            const name = md.get("name").?.string;
            const value = md.get("value").?.float;
            std.debug.print("    Metadata: name={s}, value={d:.2}\n", .{ name, value });
        }
    }

    // Update a vector and its metadata
    const updated_vector = [_]f32{ 1.5, 2.5, 3.5 };
    var updated_metadata = zvdb.metadata.json.Metadata.init(allocator);
    defer updated_metadata.deinit();
    try updated_metadata.set("name", .{ .string = "Updated Point A" });
    try updated_metadata.set("value", .{ .float = 50.0 });

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
    defer allocator.free(loaded_search_results);

    std.debug.print("Search results after loading:\n", .{});
    for (loaded_search_results) |result| {
        std.debug.print("  ID: {}, Distance: {d:.4}\n", .{ result.id, result.distance });
        if (result.metadata) |md| {
            const name = md.get("name").?.string;
            const value = md.get("value").?.float;
            std.debug.print("    Metadata: name={s}, value={d:.2}\n", .{ name, value });
        }
    }
}
