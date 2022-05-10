const std = @import("std");
const types = @import("../common/types.zig");
const bloom = @import("../common/bloom.zig");
const block_mod = @import("block.zig");
const block_cache = @import("block_cache.zig");
const BlockBuilder = block_mod.BlockBuilder;
const BlockReader = block_mod.BlockReader;

/// 64-bit magic number marking valid Tessera SSTable file ("TESSERA1" in ASCII).
pub const SSTABLE_MAGIC: u64 = 0x5445535345524131;
pub const DEFAULT_BLOCK_SIZE: usize = 4096;

/// Pointer referencing a byte span in the SSTable file.
pub const BlockHandle = struct {
    offset: u64,
    size: u64,

    pub const ENCODED_SIZE: usize = 16;

    pub fn encode(self: BlockHandle) [16]u8 {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.offset, .little);
        std.mem.writeInt(u64, buf[8..16], self.size, .little);
        return buf;
    }

    pub fn decode(buf: [16]u8) BlockHandle {
        return .{
            .offset = std.mem.readInt(u64, buf[0..8], .little),
            .size = std.mem.readInt(u64, buf[8..16], .little),
        };
    }
};

/// Fixed-size 48-byte footer at end of SSTable file.
pub const TableFooter = struct {
    metaindex_handle: BlockHandle,
    index_handle: BlockHandle,
    magic: u64,

    pub const SIZE: usize = 48;

    pub fn encode(self: TableFooter) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        @memset(&buf, 0);
        const meta_bytes = self.metaindex_handle.encode();
        @memcpy(buf[0..16], &meta_bytes);
        const index_bytes = self.index_handle.encode();
        @memcpy(buf[16..32], &index_bytes);
        std.mem.writeInt(u64, buf[40..48], self.magic, .little);
        return buf;
    }

    pub fn decode(buf: [SIZE]u8) !TableFooter {
        const magic = std.mem.readInt(u64, buf[40..48], .little);
        if (magic != SSTABLE_MAGIC) return error.InvalidMagic;

        var meta_slice: [16]u8 = undefined;
        @memcpy(&meta_slice, buf[0..16]);
        var idx_slice: [16]u8 = undefined;
        @memcpy(&idx_slice, buf[16..32]);

        return TableFooter{
            .metaindex_handle = BlockHandle.decode(meta_slice),
            .index_handle = BlockHandle.decode(idx_slice),
            .magic = magic,
        };
    }
};

/// Builder producing immutable, sorted SSTable files.
pub const SSTableBuilder = struct {
    allocator: std.mem.Allocator,
    file_buffer: std.ArrayList(u8),
    data_block: BlockBuilder,
    index_block: BlockBuilder,
    filter: bloom.BloomFilter,
    target_block_size: usize,
    last_key: std.ArrayList(u8),
    num_entries: usize,
    finished: bool,

    pub fn init(allocator: std.mem.Allocator, target_block_size: usize, estimated_keys: usize) !SSTableBuilder {
        return .{
            .allocator = allocator,
            .file_buffer = .empty,
            .data_block = try BlockBuilder.init(allocator, block_mod.DEFAULT_RESTART_INTERVAL),
            .index_block = try BlockBuilder.init(allocator, 1),
            .filter = try bloom.BloomFilter.init(allocator, @max(estimated_keys, 64), 10),
            .target_block_size = target_block_size,
            .last_key = .empty,
            .num_entries = 0,
            .finished = false,
        };
    }

    pub fn deinit(self: *SSTableBuilder) void {
        self.file_buffer.deinit(self.allocator);
        self.data_block.deinit();
        self.index_block.deinit();
        self.filter.deinit();
        self.last_key.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *SSTableBuilder, key: []const u8, value: []const u8) !void {
        std.debug.assert(!self.finished);

        // Add to Bloom filter
        self.filter.insert(key);

        // Check if data block is full
        if (self.data_block.currentSizeEstimate() >= self.target_block_size) {
            try self.flushDataBlock();
        }

        try self.data_block.add(key, value);

        self.last_key.clearRetainingCapacity();
        try self.last_key.appendSlice(self.allocator, key);
        self.num_entries += 1;
    }

    fn flushDataBlock(self: *SSTableBuilder) !void {
        if (self.data_block.counter == 0 and self.data_block.buffer.items.len == 0) return;

        const block_bytes = try self.data_block.finish();
        const offset = self.file_buffer.items.len;
        const size = block_bytes.len;

        try self.file_buffer.appendSlice(self.allocator, block_bytes);

        // Record entry in index block: key = last_key, value = encoded BlockHandle
        const handle = BlockHandle{ .offset = offset, .size = size };
        const enc_handle = handle.encode();
        try self.index_block.add(self.last_key.items, &enc_handle);

        try self.data_block.reset();
    }

    /// Complete SSTable construction and return final byte slice.
    pub fn finish(self: *SSTableBuilder) ![]const u8 {
        if (self.finished) return self.file_buffer.items;

        // Flush remaining data in data_block
        try self.flushDataBlock();

        // 1. Write Filter Block
        const filter_offset = self.file_buffer.items.len;
        const filter_bytes = self.filter.toBytes();
        try self.file_buffer.appendSlice(self.allocator, filter_bytes);
        const filter_handle = BlockHandle{ .offset = filter_offset, .size = filter_bytes.len };

        // 2. Write MetaIndex Block (mapping "filter.bloom" -> filter_handle)
        var metaindex_builder = try BlockBuilder.init(self.allocator, 1);
        defer metaindex_builder.deinit();
        const enc_filter_handle = filter_handle.encode();
        try metaindex_builder.add("filter.bloom", &enc_filter_handle);
        const metaindex_bytes = try metaindex_builder.finish();

        const metaindex_offset = self.file_buffer.items.len;
        try self.file_buffer.appendSlice(self.allocator, metaindex_bytes);
        const metaindex_handle = BlockHandle{ .offset = metaindex_offset, .size = metaindex_bytes.len };

        // 3. Write Index Block
        const index_bytes = try self.index_block.finish();
        const index_offset = self.file_buffer.items.len;
        try self.file_buffer.appendSlice(self.allocator, index_bytes);
        const index_handle = BlockHandle{ .offset = index_offset, .size = index_bytes.len };

        // 4. Write Footer
        const footer = TableFooter{
            .metaindex_handle = metaindex_handle,
            .index_handle = index_handle,
            .magic = SSTABLE_MAGIC,
        };
        const footer_bytes = footer.encode();
        try self.file_buffer.appendSlice(self.allocator, &footer_bytes);

        self.finished = true;
        return self.file_buffer.items;
    }
};

/// Reader parsing and performing point and range queries over SSTables.
pub const SSTableReader = struct {
    data: []const u8,
    footer: TableFooter,
    index_reader: BlockReader,
    filter: ?bloom.BloomFilter,
    file_number: u64,
    cache: ?*block_cache.BlockCache,

    pub fn init(data: []const u8, file_number: u64, cache: ?*block_cache.BlockCache) !SSTableReader {
        if (data.len < TableFooter.SIZE) return error.CorruptedData;

        // Parse footer
        var footer_buf: [TableFooter.SIZE]u8 = undefined;
        @memcpy(&footer_buf, data[data.len - TableFooter.SIZE .. data.len]);
        const footer = try TableFooter.decode(footer_buf);

        // Load index block
        const idx_start = footer.index_handle.offset;
        const idx_end = idx_start + footer.index_handle.size;
        if (idx_end > data.len) return error.CorruptedData;
        const index_reader = try BlockReader.init(data[idx_start..idx_end]);

        // Load Bloom filter if present
        var loaded_filter: ?bloom.BloomFilter = null;
        if (footer.metaindex_handle.size > 0) {
            const meta_start = footer.metaindex_handle.offset;
            const meta_end = meta_start + footer.metaindex_handle.size;
            if (meta_end <= data.len) {
                const meta_reader = try BlockReader.init(data[meta_start..meta_end]);
                var meta_it = meta_reader.iterator(std.heap.page_allocator);
                defer meta_it.deinit();
                try meta_it.seek("filter.bloom");
                if (meta_it.valid() and std.mem.eql(u8, meta_it.key(), "filter.bloom")) {
                    if (meta_it.value().len == 16) {
                        var fh_buf: [16]u8 = undefined;
                        @memcpy(&fh_buf, meta_it.value()[0..16]);
                        const filter_handle = BlockHandle.decode(fh_buf);
                        const f_start = filter_handle.offset;
                        const f_end = f_start + filter_handle.size;
                        if (f_end <= data.len) {
                            loaded_filter = bloom.BloomFilter.fromBytes(data[f_start..f_end]);
                        }
                    }
                }
            }
        }

        return .{
            .data = data,
            .footer = footer,
            .index_reader = index_reader,
            .filter = loaded_filter,
            .file_number = file_number,
            .cache = cache,
        };
    }

    /// Fast-path filter check. Returns true if key could be in SSTable.
    pub fn mayContain(self: SSTableReader, key: []const u8) bool {
        if (self.filter) |f| {
            return f.mayContain(key);
        }
        return true;
    }

    /// Point lookup for a key inside the SSTable.
    pub fn get(self: SSTableReader, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        // Fast-path: Bloom filter check
        if (!self.mayContain(key)) {
            return null;
        }

        // Seek index block to locate the data block that could contain key
        var idx_it = self.index_reader.iterator(allocator);
        defer idx_it.deinit();

        try idx_it.seek(key);
        if (!idx_it.valid()) {
            return null;
        }

        // Decode BlockHandle from index entry value
        if (idx_it.value().len < 16) return error.CorruptedData;
        var h_buf: [16]u8 = undefined;
        @memcpy(&h_buf, idx_it.value()[0..16]);
        const handle = BlockHandle.decode(h_buf);

        // Read data block (consulting block cache if enabled)
        const d_start = handle.offset;
        const d_end = d_start + handle.size;
        if (d_end > self.data.len) return error.CorruptedData;

        var block_data = self.data[d_start..d_end];
        if (self.cache) |c| {
            if (c.get(self.file_number, handle.offset)) |cached| {
                block_data = cached;
            } else {
                try c.insert(self.file_number, handle.offset, block_data);
            }
        }

        const data_reader = try BlockReader.init(block_data);
        var data_it = data_reader.iterator(allocator);
        defer data_it.deinit();

        try data_it.seek(key);
        if (data_it.valid() and std.mem.eql(u8, data_it.key(), key)) {
            return try allocator.dupe(u8, data_it.value());
        }

        return null;
    }
};

test "sstable builder and reader end to end" {
    const allocator = std.testing.allocator;
    var builder = try SSTableBuilder.init(allocator, 128, 10);
    defer builder.deinit();

    try builder.add("key:001", "val:001");
    try builder.add("key:002", "val:002");
    try builder.add("key:003", "val:003");
    try builder.add("key:004", "val:004");
    try builder.add("key:005", "val:005");

    const sst_data = try builder.finish();

    const reader = try SSTableReader.init(sst_data, 1, null);

    // Filter rejection check
    try std.testing.expect(!reader.mayContain("missing:key:999"));

    // Key lookup
    const v1 = try reader.get(allocator, "key:001");
    defer if (v1) |v| allocator.free(v);
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("val:001", v1.?);

    const v4 = try reader.get(allocator, "key:004");
    defer if (v4) |v| allocator.free(v);
    try std.testing.expect(v4 != null);
    try std.testing.expectEqualStrings("val:004", v4.?);

    const v_missing = try reader.get(allocator, "key:009");
    defer if (v_missing) |v| allocator.free(v);
    try std.testing.expect(v_missing == null);
}
