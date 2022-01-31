const std = @import("std");

/// Cache-line alignment constant for modern x86-64 and aarch64 architectures.
pub const CACHE_LINE_SIZE: usize = 64;

/// A byte buffer guaranteed to be aligned to cache-line boundaries (64 bytes).
/// This prevents false sharing and optimizes SIMD/AVX2/NEON vector loads.
pub const AlignedBuffer = struct {
    raw_memory: []align(CACHE_LINE_SIZE) u8,
    allocator: std.mem.Allocator,
    len: usize,

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) !AlignedBuffer {
        const raw = try allocator.alignedAlloc(u8, .@"64", initial_capacity);
        return .{
            .raw_memory = raw,
            .allocator = allocator,
            .len = 0,
        };
    }

    pub fn deinit(self: *AlignedBuffer) void {
        self.allocator.free(self.raw_memory);
        self.* = undefined;
    }

    pub fn capacity(self: AlignedBuffer) usize {
        return self.raw_memory.len;
    }

    pub fn slice(self: AlignedBuffer) []const u8 {
        return self.raw_memory[0..self.len];
    }

    pub fn sliceMut(self: *AlignedBuffer) []u8 {
        return self.raw_memory[0..self.len];
    }

    pub fn clear(self: *AlignedBuffer) void {
        self.len = 0;
    }

    pub fn append(self: *AlignedBuffer, bytes: []const u8) !void {
        if (self.len + bytes.len > self.raw_memory.len) {
            return error.OutOfMemory;
        }
        @memcpy(self.raw_memory[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn appendByte(self: *AlignedBuffer, byte: u8) !void {
        if (self.len >= self.raw_memory.len) {
            return error.OutOfMemory;
        }
        self.raw_memory[self.len] = byte;
        self.len += 1;
    }

    pub fn appendU16Le(self: *AlignedBuffer, val: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, val, .little);
        try self.append(&buf);
    }

    pub fn appendU32Le(self: *AlignedBuffer, val: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, val, .little);
        try self.append(&buf);
    }

    pub fn appendU64Le(self: *AlignedBuffer, val: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, val, .little);
        try self.append(&buf);
    }
};

/// A non-owning read-only byte view with zero-copy decoding primitives.
pub const ByteView = struct {
    data: []const u8,
    cursor: usize = 0,

    pub fn init(data: []const u8) ByteView {
        return .{ .data = data, .cursor = 0 };
    }

    pub fn remaining(self: ByteView) usize {
        return self.data.len - self.cursor;
    }

    pub fn hasRemaining(self: ByteView) bool {
        return self.cursor < self.data.len;
    }

    pub fn readByte(self: *ByteView) !u8 {
        if (self.cursor >= self.data.len) return error.EndOfStream;
        const b = self.data[self.cursor];
        self.cursor += 1;
        return b;
    }

    pub fn readBytes(self: *ByteView, n: usize) ![]const u8 {
        if (self.cursor + n > self.data.len) return error.EndOfStream;
        const sub = self.data[self.cursor .. self.cursor + n];
        self.cursor += n;
        return sub;
    }

    pub fn readU16Le(self: *ByteView) !u16 {
        const slice_bytes = try self.readBytes(2);
        return std.mem.readInt(u16, slice_bytes[0..2], .little);
    }

    pub fn readU32Le(self: *ByteView) !u32 {
        const slice_bytes = try self.readBytes(4);
        return std.mem.readInt(u32, slice_bytes[0..4], .little);
    }

    pub fn readU64Le(self: *ByteView) !u64 {
        const slice_bytes = try self.readBytes(8);
        return std.mem.readInt(u64, slice_bytes[0..8], .little);
    }

    pub fn readVarint32(self: *ByteView) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (shift < 35) : (shift += 7) {
            const b = try self.readByte();
            result |= @as(u32, b & 0x7F) << shift;
            if ((b & 0x80) == 0) return result;
        }
        return error.InvalidVarint;
    }

    pub fn readVarint64(self: *ByteView) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (shift < 70) : (shift += 7) {
            const b = try self.readByte();
            result |= @as(u64, b & 0x7F) << shift;
            if ((b & 0x80) == 0) return result;
        }
        return error.InvalidVarint;
    }
};

/// Fixed size memory slab pool to reduce allocation overhead during scans.
pub const SlicePool = struct {
    allocator: std.mem.Allocator,
    slot_size: usize,
    free_list: std.ArrayList([]align(CACHE_LINE_SIZE) u8),

    pub fn init(allocator: std.mem.Allocator, slot_size: usize, initial_capacity: usize) !SlicePool {
        var pool = SlicePool{
            .allocator = allocator,
            .slot_size = slot_size,
            .free_list = .empty,
        };
        var i: usize = 0;
        while (i < initial_capacity) : (i += 1) {
            const buf = try allocator.alignedAlloc(u8, .@"64", slot_size);
            try pool.free_list.append(allocator, buf);
        }
        return pool;
    }

    pub fn deinit(self: *SlicePool) void {
        for (self.free_list.items) |buf| {
            self.allocator.free(buf);
        }
        self.free_list.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn acquire(self: *SlicePool) ![]align(CACHE_LINE_SIZE) u8 {
        if (self.free_list.items.len > 0) {
            return self.free_list.pop().?;
        }
        return try self.allocator.alignedAlloc(u8, .@"64", self.slot_size);
    }

    pub fn release(self: *SlicePool, buf: []align(CACHE_LINE_SIZE) u8) !void {
        if (buf.len == self.slot_size) {
            try self.free_list.append(self.allocator, buf);
        } else {
            self.allocator.free(buf);
        }
    }
};

test "aligned buffer operations" {
    const allocator = std.testing.allocator;
    var buf = try AlignedBuffer.init(allocator, 1024);
    defer buf.deinit();

    try buf.append("TESSERA");
    try buf.appendU32Le(12345);
    try buf.appendU64Le(9876543210);

    try std.testing.expectEqual(@as(usize, 7 + 4 + 8), buf.len);

    var view = ByteView.init(buf.slice());
    const tag = try view.readBytes(7);
    try std.testing.expectEqualStrings("TESSERA", tag);

    const v32 = try view.readU32Le();
    try std.testing.expectEqual(@as(u32, 12345), v32);

    const v64 = try view.readU64Le();
    try std.testing.expectEqual(@as(u64, 9876543210), v64);
}

test "slice pool acquire and release" {
    const allocator = std.testing.allocator;
    var pool = try SlicePool.init(allocator, 256, 4);
    defer pool.deinit();

    const slab1 = try pool.acquire();
    const slab2 = try pool.acquire();

    try std.testing.expectEqual(@as(usize, 256), slab1.len);
    try std.testing.expectEqual(@as(usize, 256), slab2.len);

    try pool.release(slab1);
    try pool.release(slab2);
}
