const std = @import("std");
const types = @import("../common/types.zig");

pub const DEFAULT_RESTART_INTERVAL: usize = 16;

/// Entry inside an encoded SSTable data or index block.
pub const BlockEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Builder constructing prefix-compressed data and index blocks for SSTables.
pub const BlockBuilder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    restarts: std.ArrayList(u32),
    restart_interval: usize,
    counter: usize,
    last_key: std.ArrayList(u8),
    finished: bool,

    pub fn init(allocator: std.mem.Allocator, restart_interval: usize) !BlockBuilder {
        var b = BlockBuilder{
            .allocator = allocator,
            .buffer = .empty,
            .restarts = .empty,
            .restart_interval = @max(restart_interval, 1),
            .counter = 0,
            .last_key = .empty,
            .finished = false,
        };
        // First restart point is always at offset 0
        try b.restarts.append(allocator, 0);
        return b;
    }

    pub fn deinit(self: *BlockBuilder) void {
        self.buffer.deinit(self.allocator);
        self.restarts.deinit(self.allocator);
        self.last_key.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *BlockBuilder) !void {
        self.buffer.clearRetainingCapacity();
        self.restarts.clearRetainingCapacity();
        self.last_key.clearRetainingCapacity();
        try self.restarts.append(self.allocator, 0);
        self.counter = 0;
        self.finished = false;
    }

    /// Add a key-value entry to the block. Keys must be added in strictly increasing order.
    pub fn add(self: *BlockBuilder, key: []const u8, value: []const u8) !void {
        std.debug.assert(!self.finished);
        var shared: usize = 0;

        if (self.counter < self.restart_interval) {
            // Calculate common prefix with last_key
            const min_len = @min(self.last_key.items.len, key.len);
            while (shared < min_len and self.last_key.items[shared] == key[shared]) : (shared += 1) {}
        } else {
            // New restart point
            try self.restarts.append(self.allocator, @as(u32, @intCast(self.buffer.items.len)));
            self.counter = 0;
        }

        const unshared = key.len - shared;

        // Encode: shared_len (u32), unshared_len (u32), value_len (u32)
        var header_buf: [12]u8 = undefined;
        std.mem.writeInt(u32, header_buf[0..4], @as(u32, @intCast(shared)), .little);
        std.mem.writeInt(u32, header_buf[4..8], @as(u32, @intCast(unshared)), .little);
        std.mem.writeInt(u32, header_buf[8..12], @as(u32, @intCast(value.len)), .little);

        try self.buffer.appendSlice(self.allocator, &header_buf);
        try self.buffer.appendSlice(self.allocator, key[shared..]);
        try self.buffer.appendSlice(self.allocator, value);

        // Update last_key
        self.last_key.clearRetainingCapacity();
        try self.last_key.appendSlice(self.allocator, key);
        self.counter += 1;
    }

    /// Current approximate size of the block including restart table.
    pub fn currentSizeEstimate(self: *const BlockBuilder) usize {
        return self.buffer.items.len + (self.restarts.items.len * 4) + 4;
    }

    /// Finalize block by appending restart offset array and count.
    pub fn finish(self: *BlockBuilder) ![]const u8 {
        if (self.finished) return self.buffer.items;

        // Append restart array
        for (self.restarts.items) |offset| {
            var offset_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &offset_buf, offset, .little);
            try self.buffer.appendSlice(self.allocator, &offset_buf);
        }

        // Append number of restart points
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @as(u32, @intCast(self.restarts.items.len)), .little);
        try self.buffer.appendSlice(self.allocator, &count_buf);

        self.finished = true;
        return self.buffer.items;
    }
};

/// Reader parsing and binary-searching SSTable data/index blocks.
pub const BlockReader = struct {
    data: []const u8,
    restart_offset: usize,
    num_restarts: u32,

    pub fn init(data: []const u8) !BlockReader {
        if (data.len < 4) return error.CorruptedData;

        // Number of restarts is stored in the last 4 bytes
        const num_restarts = std.mem.readInt(u32, data[data.len - 4 .. data.len][0..4], .little);
        const restart_array_bytes = @as(usize, num_restarts) * 4;

        if (data.len < restart_array_bytes + 4) return error.CorruptedData;
        const restart_offset = data.len - 4 - restart_array_bytes;

        return .{
            .data = data,
            .restart_offset = restart_offset,
            .num_restarts = num_restarts,
        };
    }

    pub fn getRestartOffset(self: BlockReader, index: u32) u32 {
        std.debug.assert(index < self.num_restarts);
        const offset_pos = self.restart_offset + (index * 4);
        return std.mem.readInt(u32, self.data[offset_pos .. offset_pos + 4][0..4], .little);
    }

    /// Iterator with binary search acceleration across restart points.
    pub const Iterator = struct {
        reader: BlockReader,
        allocator: std.mem.Allocator,
        current_offset: usize,
        current_key: std.ArrayList(u8),
        current_value: []const u8,
        is_valid: bool,

        pub fn init(reader: BlockReader, allocator: std.mem.Allocator) Iterator {
            return .{
                .reader = reader,
                .allocator = allocator,
                .current_offset = 0,
                .current_key = .empty,
                .current_value = "",
                .is_valid = false,
            };
        }

        pub fn deinit(self: *Iterator) void {
            self.current_key.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn valid(self: Iterator) bool {
            return self.is_valid;
        }

        pub fn key(self: Iterator) []const u8 {
            return self.current_key.items;
        }

        pub fn value(self: Iterator) []const u8 {
            return self.current_value;
        }

        pub fn seekToFirst(self: *Iterator) !void {
            self.current_offset = 0;
            self.current_key.clearRetainingCapacity();
            try self.parseNextEntry();
        }

        /// Binary search restart points, then linearly scan to target key.
        pub fn seek(self: *Iterator, target_key: []const u8) !void {
            if (self.reader.num_restarts == 0) {
                self.is_valid = false;
                return;
            }

            var left: u32 = 0;
            var right: u32 = self.reader.num_restarts - 1;

            while (left < right) {
                const mid = (left + right + 1) / 2;
                const restart_pos = self.reader.getRestartOffset(mid);

                // Parse restart key (shared length is always 0 at restart points)
                var view = self.reader.data[restart_pos..];
                if (view.len < 12) return error.CorruptedData;
                const unshared = std.mem.readInt(u32, view[4..8][0..4], .little);
                if (12 + unshared > view.len) return error.CorruptedData;
                const mid_key = view[12 .. 12 + unshared];

                if (std.mem.order(u8, mid_key, target_key) == .lt) {
                    left = mid;
                } else {
                    right = mid - 1;
                }
            }

            // Seek to the chosen restart point
            self.current_offset = self.reader.getRestartOffset(left);
            self.current_key.clearRetainingCapacity();
            try self.parseNextEntry();

            // Linearly step forward until key >= target_key or EOF
            while (self.valid() and std.mem.order(u8, self.key(), target_key) == .lt) {
                try self.next();
            }
        }

        pub fn next(self: *Iterator) !void {
            if (!self.is_valid) return;
            try self.parseNextEntry();
        }

        fn parseNextEntry(self: *Iterator) !void {
            if (self.current_offset >= self.reader.restart_offset) {
                self.is_valid = false;
                return;
            }

            const remaining = self.reader.data[self.current_offset..];
            if (remaining.len < 12) {
                self.is_valid = false;
                return;
            }

            const shared = std.mem.readInt(u32, remaining[0..4][0..4], .little);
            const unshared = std.mem.readInt(u32, remaining[4..8][0..4], .little);
            const val_len = std.mem.readInt(u32, remaining[8..12][0..4], .little);

            var cursor: usize = 12;
            if (cursor + unshared + val_len > remaining.len) return error.CorruptedData;

            const key_delta = remaining[cursor .. cursor + unshared];
            cursor += unshared;

            const val = remaining[cursor .. cursor + val_len];
            cursor += val_len;

            self.current_offset += cursor;

            // Reconstruct full key
            if (shared > self.current_key.items.len) return error.CorruptedData;
            self.current_key.shrinkRetainingCapacity(shared);
            try self.current_key.appendSlice(self.allocator, key_delta);

            self.current_value = val;
            self.is_valid = true;
        }
    };

    pub fn iterator(self: BlockReader, allocator: std.mem.Allocator) Iterator {
        return Iterator.init(self, allocator);
    }
};

test "block builder and binary-search reader" {
    const allocator = std.testing.allocator;
    var builder = try BlockBuilder.init(allocator, 2); // Restart every 2 keys
    defer builder.deinit();

    try builder.add("customer:001", "Alice");
    try builder.add("customer:002", "Bob");
    try builder.add("customer:003", "Charlie");
    try builder.add("customer:004", "David");
    try builder.add("customer:005", "Emma");

    const block_data = try builder.finish();

    const reader = try BlockReader.init(block_data);
    try std.testing.expect(reader.num_restarts >= 3);

    var it = reader.iterator(allocator);
    defer it.deinit();

    // Test sequential traversal
    try it.seekToFirst();
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings("customer:001", it.key());
    try std.testing.expectEqualStrings("Alice", it.value());

    try it.next();
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings("customer:002", it.key());
    try std.testing.expectEqualStrings("Bob", it.value());

    // Test binary search seek
    try it.seek("customer:004");
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings("customer:004", it.key());
    try std.testing.expectEqualStrings("David", it.value());

    // Test seek to non-existent key
    try it.seek("customer:0035");
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings("customer:004", it.key());
}
