const std = @import("std");
const types = @import("types.zig");

/// Direction of key comparison.
pub const Order = math_order;
const math_order = std.math.Order;

/// Key comparator interface.
pub const Comparator = struct {
    name: []const u8,
    compareFn: *const fn (ctx: *const anyopaque, a: []const u8, b: []const u8) Order,
    context: *const anyopaque,

    pub fn compare(self: Comparator, a: []const u8, b: []const u8) Order {
        return self.compareFn(self.context, a, b);
    }
};

/// Default lexicographical byte comparator.
pub const BytewiseComparator = struct {
    const dummy: u8 = 0;

    fn compareFn(_: *const anyopaque, a: []const u8, b: []const u8) Order {
        const min_len = @min(a.len, b.len);
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            if (a[i] < b[i]) return .lt;
            if (a[i] > b[i]) return .gt;
        }
        if (a.len < b.len) return .lt;
        if (a.len > b.len) return .gt;
        return .eq;
    }

    pub fn comparator() Comparator {
        return .{
            .name = "BytewiseComparator",
            .compareFn = compareFn,
            .context = &dummy,
        };
    }
};

/// Internal key representation used across LSM MemTable, WAL, and SSTables.
/// Encodes: UserKey + 56-bit SequenceNumber + 8-bit RecordType (little-endian u64 trailer).
pub const InternalKey = struct {
    user_key: []const u8,
    sequence: u64,
    record_type: types.RecordType,

    pub const TRAILER_SIZE: usize = 8;

    pub fn init(user_key: []const u8, sequence: u64, record_type: types.RecordType) InternalKey {
        return .{
            .user_key = user_key,
            .sequence = sequence,
            .record_type = record_type,
        };
    }

    pub fn encodeTrailer(sequence: u64, record_type: types.RecordType) [8]u8 {
        var buf: [8]u8 = undefined;
        const packed_val = (sequence << 8) | @as(u64, @intFromEnum(record_type));
        std.mem.writeInt(u64, &buf, packed_val, .little);
        return buf;
    }

    pub fn decodeTrailer(trailer: [8]u8) struct { sequence: u64, record_type: types.RecordType } {
        const packed_val = std.mem.readInt(u64, &trailer, .little);
        const seq = packed_val >> 8;
        const tag = @as(u8, @truncate(packed_val & 0xFF));
        return .{
            .sequence = seq,
            .record_type = @enumFromInt(tag),
        };
    }

    /// Encode internal key into a contiguous allocated slice.
    pub fn encode(self: InternalKey, allocator: std.mem.Allocator) ![]u8 {
        const total_len = self.user_key.len + TRAILER_SIZE;
        const buf = try allocator.alloc(u8, total_len);
        @memcpy(buf[0..self.user_key.len], self.user_key);
        const trailer = encodeTrailer(self.sequence, self.record_type);
        @memcpy(buf[self.user_key.len..total_len], &trailer);
        return buf;
    }

    /// Decode internal key from a raw slice.
    pub fn decode(raw: []const u8) !InternalKey {
        if (raw.len < TRAILER_SIZE) return error.InvalidArgument;
        const user_key = raw[0 .. raw.len - TRAILER_SIZE];
        var trailer: [8]u8 = undefined;
        @memcpy(&trailer, raw[raw.len - TRAILER_SIZE .. raw.len]);
        const decoded = decodeTrailer(trailer);
        return .{
            .user_key = user_key,
            .sequence = decoded.sequence,
            .record_type = decoded.record_type,
        };
    }

    /// Compare two internal keys:
    /// 1. User key in ascending lexicographical order.
    /// 2. If user keys match, compare sequence numbers in DESCENDING order (newest first).
    /// 3. If sequences match, compare record types.
    pub fn compare(a_raw: []const u8, b_raw: []const u8) Order {
        if (a_raw.len < TRAILER_SIZE or b_raw.len < TRAILER_SIZE) {
            return BytewiseComparator.compareFn(&BytewiseComparator.dummy, a_raw, b_raw);
        }
        const a_user = a_raw[0 .. a_raw.len - TRAILER_SIZE];
        const b_user = b_raw[0 .. b_raw.len - TRAILER_SIZE];

        const user_order = BytewiseComparator.compareFn(&BytewiseComparator.dummy, a_user, b_user);
        if (user_order != .eq) return user_order;

        var a_trailer: [8]u8 = undefined;
        var b_trailer: [8]u8 = undefined;
        @memcpy(&a_trailer, a_raw[a_raw.len - TRAILER_SIZE .. a_raw.len]);
        @memcpy(&b_trailer, b_raw[b_raw.len - TRAILER_SIZE .. b_raw.len]);

        const a_val = std.mem.readInt(u64, &a_trailer, .little);
        const b_val = std.mem.readInt(u64, &b_trailer, .little);

        // Sequence number is higher bits, descending order: larger sequence sorts earlier (.lt)
        if (a_val > b_val) return .lt;
        if (a_val < b_val) return .gt;
        return .eq;
    }
};

test "bytewise comparator ordering" {
    const cmp = BytewiseComparator.comparator();
    try std.testing.expectEqual(Order.lt, cmp.compare("alpha", "beta"));
    try std.testing.expectEqual(Order.gt, cmp.compare("beta", "alpha"));
    try std.testing.expectEqual(Order.eq, cmp.compare("gamma", "gamma"));
    try std.testing.expectEqual(Order.lt, cmp.compare("a", "aa"));
}

test "internal key encode, decode, and ordering" {
    const allocator = std.testing.allocator;

    const key1 = InternalKey.init("customer:42", 100, .put);
    const key2 = InternalKey.init("customer:42", 90, .put);
    const key3 = InternalKey.init("customer:43", 50, .put);

    const enc1 = try key1.encode(allocator);
    defer allocator.free(enc1);
    const enc2 = try key2.encode(allocator);
    defer allocator.free(enc2);
    const enc3 = try key3.encode(allocator);
    defer allocator.free(enc3);

    const dec1 = try InternalKey.decode(enc1);
    try std.testing.expectEqualStrings("customer:42", dec1.user_key);
    try std.testing.expectEqual(@as(u64, 100), dec1.sequence);
    try std.testing.expectEqual(types.RecordType.put, dec1.record_type);

    // Same user key: seq 100 must sort BEFORE seq 90 (descending sequence ordering)
    try std.testing.expectEqual(Order.lt, InternalKey.compare(enc1, enc2));
    try std.testing.expectEqual(Order.gt, InternalKey.compare(enc2, enc1));

    // Different user keys: customer:42 must sort BEFORE customer:43
    try std.testing.expectEqual(Order.lt, InternalKey.compare(enc1, enc3));
}
