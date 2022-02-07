const std = @import("std");

/// Castagnoli CRC32 polynomial (0x82F63B78 reversed / reflected).
pub const CRC32C_POLYNOMIAL: u32 = 0x82F63B78;

/// Table-driven Castagnoli CRC32C implementation.
pub const Crc32C = struct {
    const TABLE: [256]u32 = initTable();

    fn initTable() [256]u32 {
        @setEvalBranchQuota(50000);
        var table: [256]u32 = undefined;
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            var crc: u32 = i;
            var j: u32 = 0;
            while (j < 8) : (j += 1) {
                if ((crc & 1) != 0) {
                    crc = (crc >> 1) ^ CRC32C_POLYNOMIAL;
                } else {
                    crc >>= 1;
                }
            }
            table[i] = crc;
        }
        return table;
    }

    /// Calculate CRC32C over a byte slice.
    pub fn calculate(data: []const u8) u32 {
        return update(0, data);
    }

    /// Incrementally update CRC32C with additional bytes.
    pub fn update(initial: u32, data: []const u8) u32 {
        var crc: u32 = ~initial;
        for (data) |byte| {
            const table_index = @as(u8, @truncate(crc ^ byte));
            crc = (crc >> 8) ^ TABLE[table_index];
        }
        return ~crc;
    }

    /// Mask CRC to prevent checksum collision when storing CRC values inside logs.
    pub fn mask(crc: u32) u32 {
        const rot = (crc >> 15) | (crc << 17);
        return rot +% 0xa282ead8;
    }

    /// Unmask masked CRC back to original CRC32C.
    pub fn unmask(masked_crc: u32) u32 {
        const rot = masked_crc -% 0xa282ead8;
        return (rot >> 17) | (rot << 15);
    }
};

test "crc32c known vector verification" {
    // Standard test vectors for CRC-32C:
    // Empty string
    try std.testing.expectEqual(@as(u32, 0), Crc32C.calculate(""));

    // "123456789" -> 0xe3069283
    const data = "123456789";
    const expected: u32 = 0xe3069283;
    try std.testing.expectEqual(expected, Crc32C.calculate(data));

    // Mask and unmask roundtrip
    const masked = Crc32C.mask(expected);
    try std.testing.expectEqual(expected, Crc32C.unmask(masked));
}

test "crc32c incremental update matches one-shot" {
    const piece1 = "Tessera ";
    const piece2 = "Storage ";
    const piece3 = "Engine";
    const combined = "Tessera Storage Engine";

    const one_shot = Crc32C.calculate(combined);

    var incremental = Crc32C.update(0, piece1);
    incremental = Crc32C.update(incremental, piece2);
    incremental = Crc32C.update(incremental, piece3);

    try std.testing.expectEqual(one_shot, incremental);
}
