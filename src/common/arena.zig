const std = @import("std");

/// Chunked memory arena for fast bump-allocation during query execution and compaction passes.
/// All memory is released or recycled together when reset() or deinit() is called.
pub const ChunkedArena = struct {
    pub const DEFAULT_CHUNK_SIZE: usize = 64 * 1024; // 64 KB

    backing_allocator: std.mem.Allocator,
    chunk_size: usize,
    chunks: std.ArrayList([]align(8) u8),
    current_chunk_idx: usize,
    current_offset: usize,
    total_allocated: usize,

    pub fn init(backing_allocator: std.mem.Allocator, chunk_size: usize) ChunkedArena {
        return .{
            .backing_allocator = backing_allocator,
            .chunk_size = @max(chunk_size, 1024),
            .chunks = .empty,
            .current_chunk_idx = 0,
            .current_offset = 0,
            .total_allocated = 0,
        };
    }

    pub fn deinit(self: *ChunkedArena) void {
        for (self.chunks.items) |chunk| {
            self.backing_allocator.free(chunk);
        }
        self.chunks.deinit(self.backing_allocator);
        self.* = undefined;
    }

    /// Reset allocator for reuse without releasing backing memory back to OS.
    pub fn reset(self: *ChunkedArena) void {
        self.current_chunk_idx = 0;
        self.current_offset = 0;
        self.total_allocated = 0;
    }

    /// Allocator interface compatible with std.mem.Allocator.
    pub fn allocator(self: *ChunkedArena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *ChunkedArena = @ptrCast(@alignCast(ctx));
        const alignment_bytes = ptr_align.toByteUnits();

        // Check if current chunk has enough capacity
        while (true) {
            if (self.current_chunk_idx < self.chunks.items.len) {
                const chunk = self.chunks.items[self.current_chunk_idx];
                const aligned_offset = std.mem.alignForward(usize, self.current_offset, alignment_bytes);
                if (aligned_offset + len <= chunk.len) {
                    self.current_offset = aligned_offset + len;
                    self.total_allocated += len;
                    return chunk.ptr + aligned_offset;
                }
                // Advance to next existing chunk if available
                self.current_chunk_idx += 1;
                self.current_offset = 0;
            } else {
                // Allocate a new chunk
                const alloc_size = @max(self.chunk_size, len + alignment_bytes);
                const new_chunk = self.backing_allocator.alignedAlloc(u8, .@"8", alloc_size) catch return null;
                self.chunks.append(self.backing_allocator, new_chunk) catch {
                    self.backing_allocator.free(new_chunk);
                    return null;
                };
                // Loop around will select this chunk
            }
        }
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "chunked arena allocation and reset" {
    const backing = std.testing.allocator;
    var arena = ChunkedArena.init(backing, 256);
    defer arena.deinit();

    const alloc_interface = arena.allocator();

    const slice1 = try alloc_interface.alloc(u8, 100);
    @memset(slice1, 0xAA);
    try std.testing.expectEqual(@as(usize, 100), slice1.len);

    const slice2 = try alloc_interface.alloc(u32, 50);
    @memset(slice2, 42);
    try std.testing.expectEqual(@as(usize, 50), slice2.len);

    try std.testing.expect(arena.chunks.items.len >= 1);

    // Reset without deallocating chunks
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.total_allocated);

    // Reuse existing capacity
    const slice3 = try alloc_interface.alloc(u8, 120);
    @memset(slice3, 0xBB);
    try std.testing.expectEqual(@as(usize, 120), slice3.len);
}
