const std = @import("std");

/// Strongly typed 64-bit identifier for graph nodes.
pub const NodeId = enum(u64) {
    invalid = 0,
    _,

    pub fn init(id: u64) NodeId {
        return @enumFromInt(id);
    }

    pub fn toInt(self: NodeId) u64 {
        return @intFromEnum(self);
    }

    pub fn isValid(self: NodeId) bool {
        return self != .invalid;
    }

    pub fn format(self: NodeId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Node({d})", .{self.toInt()});
    }
};

/// Strongly typed 64-bit identifier for graph edges.
pub const EdgeId = enum(u64) {
    invalid = 0,
    _,

    pub fn init(id: u64) EdgeId {
        return @enumFromInt(id);
    }

    pub fn toInt(self: EdgeId) u64 {
        return @intFromEnum(self);
    }

    pub fn isValid(self: EdgeId) bool {
        return self != .invalid;
    }

    pub fn format(self: EdgeId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Edge({d})", .{self.toInt()});
    }
};

/// Strongly typed 64-bit identifier for MVCC transactions.
pub const TxnId = enum(u64) {
    invalid = 0,
    _,

    pub fn init(id: u64) TxnId {
        return @enumFromInt(id);
    }

    pub fn toInt(self: TxnId) u64 {
        return @intFromEnum(self);
    }

    pub fn isValid(self: TxnId) bool {
        return self != .invalid;
    }

    pub fn next(self: TxnId) TxnId {
        return @enumFromInt(self.toInt() + 1);
    }

    pub fn format(self: TxnId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Txn({d})", .{self.toInt()});
    }
};

/// Log Sequence Number tracking order in Write-Ahead Log.
pub const Lsn = enum(u64) {
    zero = 0,
    _,

    pub fn init(seq: u64) Lsn {
        return @enumFromInt(seq);
    }

    pub fn toInt(self: Lsn) u64 {
        return @intFromEnum(self);
    }

    pub fn next(self: Lsn) Lsn {
        return @enumFromInt(self.toInt() + 1);
    }

    pub fn advance(self: Lsn, delta: u64) Lsn {
        return @enumFromInt(self.toInt() + delta);
    }

    pub fn format(self: Lsn, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("LSN({d})", .{self.toInt()});
    }
};

/// Unique 64-bit identifier for high-dimensional vector embeddings.
pub const VectorId = enum(u64) {
    invalid = 0,
    _,

    pub fn init(id: u64) VectorId {
        return @enumFromInt(id);
    }

    pub fn toInt(self: VectorId) u64 {
        return @intFromEnum(self);
    }

    pub fn isValid(self: VectorId) bool {
        return self != .invalid;
    }

    pub fn format(self: VectorId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Vec({d})", .{self.toInt()});
    }
};

/// Microsecond or nanosecond epoch timestamp.
pub const Timestamp = enum(u64) {
    zero = 0,
    max = std.math.maxInt(u64),
    _,

    pub fn now() Timestamp {
        return @enumFromInt(@as(u64, @intCast(std.time.microTimestamp())));
    }

    pub fn init(micros: u64) Timestamp {
        return @enumFromInt(micros);
    }

    pub fn toInt(self: Timestamp) u64 {
        return @intFromEnum(self);
    }

    pub fn format(self: Timestamp, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Ts({d})", .{self.toInt()});
    }
};

/// Type tag for storage records in the Write-Ahead Log and MemTable.
pub const RecordType = enum(u8) {
    put = 1,
    delete = 2,
    merge = 3,
    tombstone = 4,
    checkpoint = 5,
    txn_begin = 6,
    txn_commit = 7,
    txn_abort = 8,

    pub fn isWrite(self: RecordType) bool {
        return self == .put or self == .delete or self == .merge;
    }

    pub fn isTxnBoundary(self: RecordType) bool {
        return self == .txn_begin or self == .txn_commit or self == .txn_abort;
    }
};

/// Operational status codes for database transactions and queries.
pub const Status = enum(u8) {
    ok = 0,
    not_found = 1,
    key_exists = 2,
    txn_conflict = 3,
    txn_aborted = 4,
    corrupted_data = 5,
    out_of_space = 6,
    invalid_argument = 7,
    io_error = 8,
    version_mismatch = 9,
    timeout = 10,
    not_supported = 11,

    pub fn isSuccess(self: Status) bool {
        return self == .ok;
    }

    pub fn toError(self: Status) !void {
        switch (self) {
            .ok => return,
            .not_found => return error.NotFound,
            .key_exists => return error.KeyExists,
            .txn_conflict => return error.TxnConflict,
            .txn_aborted => return error.TxnAborted,
            .corrupted_data => return error.CorruptedData,
            .out_of_space => return error.OutOfSpace,
            .invalid_argument => return error.InvalidArgument,
            .io_error => return error.IoError,
            .version_mismatch => return error.VersionMismatch,
            .timeout => return error.Timeout,
            .not_supported => return error.NotSupported,
        }
    }
};

/// Common error set for Tessera operations.
pub const Error = error{
    NotFound,
    KeyExists,
    TxnConflict,
    TxnAborted,
    CorruptedData,
    OutOfSpace,
    InvalidArgument,
    IoError,
    VersionMismatch,
    Timeout,
    NotSupported,
    ChecksumMismatch,
    OutOfMemory,
    DiskFull,
    InvalidMagic,
    WalFull,
    ManifestCorrupt,
};

/// Key-Value pair slice with ownership semantics.
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
    timestamp: Timestamp = .zero,
    record_type: RecordType = .put,

    pub fn clone(self: KeyValue, allocator: std.mem.Allocator) !KeyValue {
        return .{
            .key = try allocator.dupe(u8, self.key),
            .value = try allocator.dupe(u8, self.value),
            .timestamp = self.timestamp,
            .record_type = self.record_type,
        };
    }

    pub fn deinit(self: KeyValue, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// Memory slice with byte span metadata.
pub const ByteSpan = struct {
    offset: u64,
    length: u32,

    pub fn end(self: ByteSpan) u64 {
        return self.offset + self.length;
    }

    pub fn contains(self: ByteSpan, point: u64) bool {
        return point >= self.offset and point < self.end();
    }
};

test "strongly typed identifiers" {
    const node = NodeId.init(101);
    try std.testing.expect(node.isValid());
    try std.testing.expectEqual(@as(u64, 101), node.toInt());

    const edge = EdgeId.init(202);
    try std.testing.expect(edge.isValid());
    try std.testing.expectEqual(@as(u64, 202), edge.toInt());

    const txn = TxnId.init(5);
    try std.testing.expectEqual(TxnId.init(6), txn.next());

    const lsn = Lsn.init(100);
    try std.testing.expectEqual(Lsn.init(101), lsn.next());
    try std.testing.expectEqual(Lsn.init(125), lsn.advance(25));
}

test "status and errors" {
    const s = Status.ok;
    try std.testing.expect(s.isSuccess());

    const not_found = Status.not_found;
    try std.testing.expectError(error.NotFound, not_found.toError());
}

test "record type classification" {
    try std.testing.expect(RecordType.put.isWrite());
    try std.testing.expect(RecordType.delete.isWrite());
    try std.testing.expect(!RecordType.checkpoint.isWrite());
    try std.testing.expect(RecordType.txn_begin.isTxnBoundary());
    try std.testing.expect(RecordType.txn_commit.isTxnBoundary());
}
