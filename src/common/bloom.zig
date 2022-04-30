const std = @import("std");

/// Bloom filter with double-hashing for SSTable key existence checks.
pub const BloomFilter = struct {
    bits: []u8,
    num_probes: u8,
    allocator: ?std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_keys: usize, bits_per_key: usize) !BloomFilter {
        var total_bits = num_keys * bits_per_key;
        if (total_bits < 64) total_bits = 64;

        // Round up to multiple of 8 for whole bytes
        const total_bytes = (total_bits + 7) / 8;
        // Allocate total_bytes + 1 to store num_probes as trailer byte
        const bits = try allocator.alloc(u8, total_bytes + 1);
        @memset(bits, 0);

        var k = @as(u32, @intFromFloat(@as(f64, @floatFromInt(bits_per_key)) * 0.693));
        if (k < 1) k = 1;
        if (k > 30) k = 30;

        bits[total_bytes] = @as(u8, @intCast(k));

        return .{
            .bits = bits,
            .num_probes = @as(u8, @intCast(k)),
            .allocator = allocator,
        };
    }

    /// Wrap existing byte slice as read-only BloomFilter with self-describing probe count.
    pub fn fromBytes(bytes: []const u8) BloomFilter {
        if (bytes.len <= 1) {
            return .{
                .bits = &.{},
                .num_probes = 0,
                .allocator = null,
            };
        }
        const k = bytes[bytes.len - 1];
        return .{
            .bits = @constCast(bytes),
            .num_probes = k,
            .allocator = null,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        if (self.allocator) |alloc| {
            alloc.free(self.bits);
            self.* = undefined;
        }
    }

    fn hashKey(key: []const u8) u64 {
        return std.hash.Wyhash.hash(0x9e3779b97f4a7c15, key);
    }

    /// Insert a key into the filter.
    pub fn insert(self: *BloomFilter, key: []const u8) void {
        if (self.bits.len <= 1) return;
        const total_bits = (self.bits.len - 1) * 8;
        const h = hashKey(key);
        const h1 = @as(u32, @truncate(h));
        const h2 = @as(u32, @truncate(h >> 32)) | 1;

        var i: u32 = 0;
        while (i < self.num_probes) : (i += 1) {
            const bit_idx = (h1 +% (i *% h2)) % @as(u32, @intCast(total_bits));
            const byte_idx = bit_idx / 8;
            const bit_offset = @as(u3, @truncate(bit_idx % 8));
            self.bits[byte_idx] |= (@as(u8, 1) << bit_offset);
        }
    }

    /// Query whether a key may be present. False positives possible, false negatives impossible.
    pub fn mayContain(self: BloomFilter, key: []const u8) bool {
        if (self.bits.len <= 1 or self.num_probes == 0) return true;
        const total_bits = (self.bits.len - 1) * 8;
        const h = hashKey(key);
        const h1 = @as(u32, @truncate(h));
        const h2 = @as(u32, @truncate(h >> 32)) | 1;

        var i: u32 = 0;
        while (i < self.num_probes) : (i += 1) {
            const bit_idx = (h1 +% (i *% h2)) % @as(u32, @intCast(total_bits));
            const byte_idx = bit_idx / 8;
            const bit_offset = @as(u3, @truncate(bit_idx % 8));
            if ((self.bits[byte_idx] & (@as(u8, 1) << bit_offset)) == 0) {
                return false;
            }
        }
        return true;
    }

    pub fn toBytes(self: BloomFilter) []const u8 {
        return self.bits;
    }
};

test "bloom filter insertion and lookup" {
    const allocator = std.testing.allocator;
    var filter = try BloomFilter.init(allocator, 1000, 10);
    defer filter.deinit();

    // Insert keys
    filter.insert("user:1001:profile");
    filter.insert("user:1002:profile");
    filter.insert("user:1003:profile");

    // All inserted keys must be present
    try std.testing.expect(filter.mayContain("user:1001:profile"));
    try std.testing.expect(filter.mayContain("user:1002:profile"));
    try std.testing.expect(filter.mayContain("user:1003:profile"));

    // Missing key should be absent (with high probability)
    try std.testing.expect(!filter.mayContain("missing:key:9999"));
}

test "bloom filter serialization roundtrip" {
    const allocator = std.testing.allocator;
    var original = try BloomFilter.init(allocator, 100, 12);
    defer original.deinit();

    original.insert("metric:latency_p99");
    original.insert("metric:cpu_core_0");

    const serialized = original.toBytes();
    const loaded = BloomFilter.fromBytes(serialized);

    try std.testing.expect(loaded.mayContain("metric:latency_p99"));
    try std.testing.expect(loaded.mayContain("metric:cpu_core_0"));
    try std.testing.expect(!loaded.mayContain("metric:non_existent"));
}
