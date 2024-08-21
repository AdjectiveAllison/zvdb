const std = @import("std");

pub fn getGitCommit(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "HEAD" },
        .max_output_bytes = 128, // A git commit hash is typically 40 characters
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term.Exited != 0) {
        return error.GitCommandFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, "\n");
    return try allocator.dupe(u8, trimmed);
}

pub fn appendToCsv(file_path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer file.close();

    try file.seekFromEnd(0);
    try file.writeAll(data);
    try file.writeAll("\n");
}

pub fn getCsvFilePath(allocator: std.mem.Allocator, git_commit: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "benchmarks/results/{s}.csv", .{git_commit});
}

pub fn ensureCsvHeaderExists(file_path: []const u8) !void {
    const header = "operation,dimensions,k,num_threads,partition_size,total_time_ns,operations_performed,operations_per_second";

    // Create the directory if it doesn't exist
    const dir_path = std.fs.path.dirname(file_path) orelse ".";
    try std.fs.cwd().makePath(dir_path);

    const file = try std.fs.cwd().createFile(file_path, .{ .read = true, .truncate = false });
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0) {
        try file.writeAll(header);
        try file.writeAll("\n");
    }
}
