const std = @import("std");

/// A wrapper around a std.mem.Allocator that tracks allocations and frees.
pub const TrackedAllocator = struct {
    allocator: std.mem.Allocator,
    total_allocated: usize,
    total_freed: usize,

    const Self = @This();

    /// Initialize a new TrackedAllocator.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .total_allocated = 0,
            .total_freed = 0,
        };
    }

    /// Allocate memory and track the allocation.
    pub fn allocate(self: *Self, len: usize, ptr_align: u29, ret_addr: usize) ?[*]u8 {
        const result = self.allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            self.total_allocated += len;
        }
        return result;
    }

    /// Free memory and track the deallocation.
    pub fn free(self: *Self, ptr: [*]u8, len: usize, ptr_align: u29, ret_addr: usize) void {
        self.allocator.rawFree(ptr, len, ptr_align, ret_addr);
        self.total_freed += len;
    }

    /// Get the current memory usage.
    pub fn getCurrentUsage(self: *const Self) usize {
        return self.total_allocated - self.total_freed;
    }

    /// Create a std.mem.Allocator from this TrackedAllocator.
    pub fn toAllocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = freeImpl,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u29, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.allocate(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u29, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.allocator.rawResize(buf.ptr, buf.len, buf_align, new_len, ret_addr)) {
            if (new_len > buf.len) {
                self.total_allocated += new_len - buf.len;
            } else {
                self.total_freed += buf.len - new_len;
            }
            return true;
        }
        return false;
    }

    fn freeImpl(ctx: *anyopaque, buf: []u8, buf_align: u29, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.free(buf.ptr, buf.len, buf_align, ret_addr);
    }
};

/// Create a TrackedAllocator from a std.mem.Allocator.
pub fn createTrackedAllocator(allocator: std.mem.Allocator) TrackedAllocator {
    return TrackedAllocator.init(allocator);
}
