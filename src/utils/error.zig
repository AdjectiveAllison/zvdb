const std = @import("std");

/// Custom error set for ZVDB operations.
pub const ZVDBError = error{
    InvalidDimension,
    InvalidMetadata,
    ItemNotFound,
    IndexError,
    PersistenceError,
    OutOfMemory,
    InvalidConfiguration,
};

/// A wrapper around errors that includes additional context.
pub const ErrorContext = struct {
    err: anyerror,
    context: []const u8,

    /// Create a new ErrorContext.
    pub fn init(err: anyerror, context: []const u8) ErrorContext {
        return .{
            .err = err,
            .context = context,
        };
    }

    /// Convert the ErrorContext to a string.
    pub fn toString(self: *const ErrorContext, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "Error: {s}. Context: {s}", .{ @errorName(self.err), self.context });
    }
};

/// A helper function to wrap an error with context.
pub fn wrapError(err: anyerror, context: []const u8) ErrorContext {
    return ErrorContext.init(err, context);
}

/// A helper function to handle errors and optionally print them.
pub fn handleError(err: anyerror, context: []const u8, print: bool) void {
    const wrapped_err = wrapError(err, context);
    if (print) {
        std.debug.print("Error occurred: {s}\n", .{@errorName(err)});
        std.debug.print("Context: {s}\n", .{context});
    }
    // Here you can add additional error handling logic if needed
    _ = wrapped_err;
}
