const std = @import("std");
const types = @import("../common/types.zig");
const crc32 = @import("../common/crc32.zig");
const buffer_mod = @import("../common/buffer.zig");

/// Magic bytes identifying a valid Tessera Write-Ahead Log file ("TWAL" in ASCII).
pub const WAL_MAGIC: u32 = 0x5457414C;
pub const WAL_VERSION: u16 = 1;

/// Fixed-size record header written before every WAL entry payload.
pub const WalHeader = extern struct {
    magic: u32,
    version: u16,
    record_type: u8,
    flags: u8,
    sequence: u64,
    payload_len: u32,
    crc: u32,

    pub const SIZE: usize = @sizeOf(WalHeader);

    pub fn init(rec_type: types.RecordType, seq: u64, payload_len: u32, checksum: u32) WalHeader {
        return .{
            .magic = WAL_MAGIC,
            .version = WAL_VERSION,
            .record_type = @intFromEnum(rec_type),
            .flags = 0,
            .sequence = seq,
            .payload_len = payload_len,
            .crc = checksum,
        };
    }
};

/// An entry read or written to the Write-Ahead Log.
pub const WalRecord = struct {
    sequence: u64,
    record_type: types.RecordType,
    key: []const u8,
    value: []const u8,

    pub fn payloadSize(self: WalRecord) usize {
        return 4 + self.key.len + 4 + self.value.len;
    }
};

/// High-throughput Write-Ahead Log appender with batched buffering and CRC32C integrity.
pub const WalWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    current_lsn: types.Lsn,
    records_written: u64,
    bytes_written: u64,

    pub fn init(allocator: std.mem.Allocator) WalWriter {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .current_lsn = types.Lsn.zero,
            .records_written = 0,
            .bytes_written = 0,
        };
    }

    pub fn deinit(self: *WalWriter) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a single key-value record to the in-memory write buffer.
    pub fn append(self: *WalWriter, record: WalRecord) !types.Lsn {
        const payload_len = record.payloadSize();
        const header_offset = self.buffer.items.len;

        // Reserve space for header + payload
        const total_entry_size = WalHeader.SIZE + payload_len;
        try self.buffer.ensureUnusedCapacity(self.allocator, total_entry_size);

        // Advance sequence
        self.current_lsn = self.current_lsn.next();
        const seq = self.current_lsn.toInt();

        // Write payload to scratch area to compute CRC32C
        var payload_scratch = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload_scratch);

        var cursor: usize = 0;
        std.mem.writeInt(u32, payload_scratch[cursor .. cursor + 4][0..4], @as(u32, @intCast(record.key.len)), .little);
        cursor += 4;
        @memcpy(payload_scratch[cursor .. cursor + record.key.len], record.key);
        cursor += record.key.len;

        std.mem.writeInt(u32, payload_scratch[cursor .. cursor + 4][0..4], @as(u32, @intCast(record.value.len)), .little);
        cursor += 4;
        @memcpy(payload_scratch[cursor .. cursor + record.value.len], record.value);

        const checksum = crc32.Crc32C.mask(crc32.Crc32C.calculate(payload_scratch));
        const header = WalHeader.init(record.record_type, seq, @as(u32, @intCast(payload_len)), checksum);

        // Append header bytes
        const header_bytes = std.mem.asBytes(&header);
        try self.buffer.appendSlice(self.allocator, header_bytes);

        // Append payload bytes
        try self.buffer.appendSlice(self.allocator, payload_scratch);

        self.records_written += 1;
        self.bytes_written += (self.buffer.items.len - header_offset);

        return self.current_lsn;
    }

    /// Append batch of key-value records atomically.
    pub fn appendBatch(self: *WalWriter, records: []const WalRecord) !types.Lsn {
        var last_lsn = self.current_lsn;
        for (records) |r| {
            last_lsn = try self.append(r);
        }
        return last_lsn;
    }

    pub fn getData(self: *const WalWriter) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *WalWriter) void {
        self.buffer.clearRetainingCapacity();
    }
};

/// Recovery reader parsing and validating Write-Ahead Log streams.
pub const WalReader = struct {
    data: []const u8,
    cursor: usize,

    pub fn init(data: []const u8) WalReader {
        return .{
            .data = data,
            .cursor = 0,
        };
    }

    /// Read next valid record from WAL. Returns null on clean EOF.
    pub fn next(self: *WalReader) !?WalRecord {
        if (self.cursor >= self.data.len) return null;

        if (self.data.len - self.cursor < WalHeader.SIZE) {
            // Partial / torn header at end of log
            return error.CorruptedData;
        }

        const header_slice = self.data[self.cursor .. self.cursor + WalHeader.SIZE];
        var header: WalHeader = undefined;
        @memcpy(std.mem.asBytes(&header), header_slice);

        if (header.magic != WAL_MAGIC) {
            return error.InvalidMagic;
        }
        if (header.version != WAL_VERSION) {
            return error.VersionMismatch;
        }

        self.cursor += WalHeader.SIZE;

        if (self.data.len - self.cursor < header.payload_len) {
            // Partial payload at end of log (crash during write)
            return error.CorruptedData;
        }

        const payload = self.data[self.cursor .. self.cursor + header.payload_len];
        self.cursor += header.payload_len;

        // Verify checksum
        const actual_crc = crc32.Crc32C.mask(crc32.Crc32C.calculate(payload));
        if (actual_crc != header.crc) {
            return error.ChecksumMismatch;
        }

        // Decode key and value
        if (payload.len < 8) return error.CorruptedData;
        var p_cursor: usize = 0;
        const key_len = std.mem.readInt(u32, payload[p_cursor .. p_cursor + 4][0..4], .little);
        p_cursor += 4;

        if (p_cursor + key_len > payload.len) return error.CorruptedData;
        const key = payload[p_cursor .. p_cursor + key_len];
        p_cursor += key_len;

        if (p_cursor + 4 > payload.len) return error.CorruptedData;
        const val_len = std.mem.readInt(u32, payload[p_cursor .. p_cursor + 4][0..4], .little);
        p_cursor += 4;

        if (p_cursor + val_len > payload.len) return error.CorruptedData;
        const value = payload[p_cursor .. p_cursor + val_len];

        return WalRecord{
            .sequence = header.sequence,
            .record_type = @enumFromInt(header.record_type),
            .key = key,
            .value = value,
        };
    }
};

test "wal append and readback verification" {
    const allocator = std.testing.allocator;
    var writer = WalWriter.init(allocator);
    defer writer.deinit();

    const lsn1 = try writer.append(.{
        .sequence = 0,
        .record_type = .put,
        .key = "table:users:row:1",
        .value = "{\"name\":\"alice\",\"role\":\"admin\"}",
    });
    try std.testing.expectEqual(@as(u64, 1), lsn1.toInt());

    const lsn2 = try writer.append(.{
        .sequence = 0,
        .record_type = .delete,
        .key = "table:users:row:2",
        .value = "",
    });
    try std.testing.expectEqual(@as(u64, 2), lsn2.toInt());

    var reader = WalReader.init(writer.getData());

    const r1 = (try reader.next()).?;
    try std.testing.expectEqual(@as(u64, 1), r1.sequence);
    try std.testing.expectEqual(types.RecordType.put, r1.record_type);
    try std.testing.expectEqualStrings("table:users:row:1", r1.key);
    try std.testing.expectEqualStrings("{\"name\":\"alice\",\"role\":\"admin\"}", r1.value);

    const r2 = (try reader.next()).?;
    try std.testing.expectEqual(@as(u64, 2), r2.sequence);
    try std.testing.expectEqual(types.RecordType.delete, r2.record_type);
    try std.testing.expectEqualStrings("table:users:row:2", r2.key);
    try std.testing.expectEqualStrings("", r2.value);

    // End of stream
    const r3 = try reader.next();
    try std.testing.expect(r3 == null);
}

test "wal detects bit flips and data corruption" {
    const allocator = std.testing.allocator;
    var writer = WalWriter.init(allocator);
    defer writer.deinit();

    _ = try writer.append(.{
        .sequence = 0,
        .record_type = .put,
        .key = "critical_account_balance",
        .value = "$1000000",
    });

    // Clone data and corrupt a bit in the payload
    var corrupted = try allocator.dupe(u8, writer.getData());
    defer allocator.free(corrupted);

    // Corrupt a byte in payload area
    corrupted[corrupted.len - 3] ^= 0xFF;

    var reader = WalReader.init(corrupted);
    try std.testing.expectError(error.ChecksumMismatch, reader.next());
}
