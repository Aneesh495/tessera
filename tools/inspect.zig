const std = @import("std");
const tessera = @import("tessera");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    std.debug.print("========================================================\n", .{});
    std.debug.print("  Tessera Storage Inspector & Offline Validator v0.1.0\n", .{});
    std.debug.print("========================================================\n\n", .{});

    // Run self-test validation on an in-memory generated SSTable
    try validateSampleSSTable(allocator);
    try validateSampleWal(allocator);

    std.debug.print("Storage inspection verification passed cleanly.\n\n", .{});
}

fn validateSampleSSTable(allocator: std.mem.Allocator) !void {
    std.debug.print("--> Validating Leveled SSTable Binary Layout & Checksums...\n", .{});

    var builder = try tessera.storage.sstable.SSTableBuilder.init(allocator, 1, 4096);
    defer builder.deinit();

    // Populate keys in lexicographical order
    const num_keys = 500;
    var key_buf: [32]u8 = undefined;
    var val_buf: [64]u8 = undefined;
    @memset(&val_buf, 0x55);

    for (0..num_keys) |i| {
        const k = std.fmt.bufPrint(&key_buf, "key_{d:0>6}", .{i}) catch unreachable;
        try builder.add(k, &val_buf);
    }

    const table_bytes = try builder.finish();

    // Validate using SSTableReader
    const cache = try tessera.storage.block_cache.BlockCache.init(allocator, 1024 * 1024);
    defer cache.deinit(allocator);

    const reader = try tessera.storage.sstable.SSTableReader.init(table_bytes, 1, cache);

    std.debug.print("    Total SSTable Size: {d} bytes\n", .{table_bytes.len});
    std.debug.print("    Entries Written:    {d}\n", .{num_keys});
    std.debug.print("    Footer Magic:       0x{X}\n", .{reader.footer.magic});
    std.debug.print("    Index Block Size:   {d} bytes\n", .{reader.footer.index_handle.size});

    // Verify key 250
    const test_k = "key_000250";
    if (try reader.get(allocator, test_k)) |v| {
        defer allocator.free(v);
        std.debug.print("    Point Lookup Verification for '{s}': OK (val len: {d})\n", .{ test_k, v.len });
    } else {
        std.debug.print("    Point Lookup Verification FAILED for '{s}'\n", .{test_k});
        return error.VerificationFailed;
    }

    // Verify non-existent key correctly rejected by Bloom filter
    const missing_k = "key_999999";
    const missing_res = try reader.get(allocator, missing_k);
    if (missing_res == null) {
        std.debug.print("    Bloom Filter Negative Rejection for '{s}': OK\n\n", .{missing_k});
    } else {
        std.debug.print("    Bloom Filter Negative Rejection FAILED\n\n", .{});
        return error.VerificationFailed;
    }
}

fn validateSampleWal(allocator: std.mem.Allocator) !void {
    std.debug.print("--> Validating Write-Ahead Log Framing & CRC32C...\n", .{});

    var wal = tessera.storage.wal.WalWriter.init(allocator);
    defer wal.deinit();

    _ = try wal.append(.{
        .sequence = 1,
        .record_type = .put,
        .key = "alpha",
        .value = "val_alpha",
    });

    _ = try wal.append(.{
        .sequence = 2,
        .record_type = .delete,
        .key = "beta",
        .value = "",
    });

    std.debug.print("    WAL Serialized Size: {d} bytes\n", .{wal.buffer.items.len});

    var reader = tessera.storage.wal.WalReader.init(wal.buffer.items);
    var count: usize = 0;
    while (try reader.next()) |rec| {
        count += 1;
        std.debug.print("    Record #{d}: Seq={d}, Type={s}, Key='{s}'\n", .{
            count,
            rec.sequence,
            @tagName(rec.record_type),
            rec.key,
        });
    }
    std.debug.print("    All WAL records verified with zero corruption.\n\n", .{});
}
