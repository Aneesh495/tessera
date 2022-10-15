const std = @import("std");
const sim_rng_mod = @import("sim_rng.zig");

pub const DiskFault = error{
    DiskIoError,
    NoSpaceLeft,
    SectorCorrupted,
    InvalidOffset,
};

pub const DiskMetrics = struct {
    read_ops: u64 = 0,
    write_ops: u64 = 0,
    sync_ops: u64 = 0,
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    faults_injected: u64 = 0,
};

pub const FaultConfig = struct {
    io_error_rate: f32 = 0.0,
    enospc_rate: f32 = 0.0,
    torn_write_rate: f32 = 0.0,
    bit_flip_rate: f32 = 0.0,
};

/// Simulated virtual storage device with fault injection capabilities.
/// Supports torn writes, bit flips, power failure crash rollback, and I/O stalling.
pub const SimDisk = struct {
    allocator: std.mem.Allocator,
    sector_size: usize,
    capacity_sectors: usize,
    committed_sectors: std.AutoHashMap(u64, []u8),
    volatile_sectors: std.AutoHashMap(u64, []u8),
    faults: FaultConfig,
    metrics: DiskMetrics,

    pub fn init(allocator: std.mem.Allocator, sector_size: usize, capacity_sectors: usize) SimDisk {
        return .{
            .allocator = allocator,
            .sector_size = sector_size,
            .capacity_sectors = capacity_sectors,
            .committed_sectors = std.AutoHashMap(u64, []u8).init(allocator),
            .volatile_sectors = std.AutoHashMap(u64, []u8).init(allocator),
            .faults = .{},
            .metrics = .{},
        };
    }

    pub fn deinit(self: *SimDisk) void {
        var it1 = self.committed_sectors.valueIterator();
        while (it1.next()) |buf| {
            self.allocator.free(buf.*);
        }
        self.committed_sectors.deinit();

        var it2 = self.volatile_sectors.valueIterator();
        while (it2.next()) |buf| {
            self.allocator.free(buf.*);
        }
        self.volatile_sectors.deinit();

        self.* = undefined;
    }

    pub fn setFaults(self: *SimDisk, faults: FaultConfig) void {
        self.faults = faults;
    }

    /// Read raw sector into destination buffer.
    pub fn readSector(self: *SimDisk, sector_idx: u64, dest: []u8, rng: ?*sim_rng_mod.SimRng) !void {
        if (sector_idx >= self.capacity_sectors) return DiskFault.InvalidOffset;
        if (dest.len < self.sector_size) return DiskFault.InvalidOffset;

        self.metrics.read_ops += 1;
        self.metrics.bytes_read += self.sector_size;

        if (rng) |r| {
            if (r.chance(self.faults.io_error_rate)) {
                self.metrics.faults_injected += 1;
                return DiskFault.DiskIoError;
            }
        }

        // Check volatile un-synced cache first, then committed storage
        if (self.volatile_sectors.get(sector_idx)) |buf| {
            @memcpy(dest[0..self.sector_size], buf);
            return;
        }

        if (self.committed_sectors.get(sector_idx)) |buf| {
            @memcpy(dest[0..self.sector_size], buf);
            return;
        }

        // Unwritten sector reads as zeroes
        @memset(dest[0..self.sector_size], 0);
    }

    /// Write raw sector into volatile storage buffer.
    pub fn writeSector(self: *SimDisk, sector_idx: u64, src: []const u8, rng: ?*sim_rng_mod.SimRng) !void {
        if (sector_idx >= self.capacity_sectors) return DiskFault.InvalidOffset;
        if (src.len < self.sector_size) return DiskFault.InvalidOffset;

        self.metrics.write_ops += 1;
        self.metrics.bytes_written += self.sector_size;

        if (rng) |r| {
            if (r.chance(self.faults.io_error_rate)) {
                self.metrics.faults_injected += 1;
                return DiskFault.DiskIoError;
            }
            if (r.chance(self.faults.enospc_rate)) {
                self.metrics.faults_injected += 1;
                return DiskFault.NoSpaceLeft;
            }
        }

        const entry = try self.volatile_sectors.getOrPut(sector_idx);
        if (!entry.found_existing) {
            entry.value_ptr.* = try self.allocator.alloc(u8, self.sector_size);
            if (self.committed_sectors.get(sector_idx)) |committed| {
                @memcpy(entry.value_ptr.*, committed);
            } else {
                @memset(entry.value_ptr.*, 0);
            }
        }

        var to_copy = self.sector_size;
        // Inject torn write: partial page flush before failure
        if (rng) |r| {
            if (r.chance(self.faults.torn_write_rate)) {
                to_copy = self.sector_size / 2;
                self.metrics.faults_injected += 1;
            }
        }

        @memcpy(entry.value_ptr.*[0..to_copy], src[0..to_copy]);

        // Inject bit flip
        if (rng) |r| {
            if (r.chance(self.faults.bit_flip_rate)) {
                const flip_byte = r.nextRange(0, to_copy);
                const flip_bit: u3 = @as(u3, @intCast(r.nextRange(0, 8)));
                entry.value_ptr.*[flip_byte] ^= (@as(u8, 1) << flip_bit);
                self.metrics.faults_injected += 1;
            }
        }
    }

    /// Synchronize all volatile sectors to durable committed storage (simulating fsync).
    pub fn sync(self: *SimDisk) !void {
        self.metrics.sync_ops += 1;

        var it = self.volatile_sectors.iterator();
        while (it.next()) |entry| {
            const sector_idx = entry.key_ptr.*;
            const vol_buf = entry.value_ptr.*;

            const committed_entry = try self.committed_sectors.getOrPut(sector_idx);
            if (!committed_entry.found_existing) {
                committed_entry.value_ptr.* = try self.allocator.alloc(u8, self.sector_size);
            }
            @memcpy(committed_entry.value_ptr.*, vol_buf);
        }

        // Clear volatile cache
        var free_it = self.volatile_sectors.valueIterator();
        while (free_it.next()) |buf| {
            self.allocator.free(buf.*);
        }
        self.volatile_sectors.clearRetainingCapacity();
    }

    /// Simulate sudden power loss or kernel crash: discards un-synced volatile sectors.
    pub fn crash(self: *SimDisk) void {
        var it = self.volatile_sectors.valueIterator();
        while (it.next()) |buf| {
            self.allocator.free(buf.*);
        }
        self.volatile_sectors.clearRetainingCapacity();
    }

    /// Arbitrary offset write convenience helper.
    pub fn writeAt(self: *SimDisk, offset: u64, data: []const u8, rng: ?*sim_rng_mod.SimRng) !void {
        var remaining = data;
        var curr_offset = offset;

        var sector_buf = try self.allocator.alloc(u8, self.sector_size);
        defer self.allocator.free(sector_buf);

        while (remaining.len > 0) {
            const sector_idx = curr_offset / self.sector_size;
            const sector_off = @as(usize, @intCast(curr_offset % self.sector_size));
            const chunk_len = @min(remaining.len, self.sector_size - sector_off);

            try self.readSector(sector_idx, sector_buf, null);
            @memcpy(sector_buf[sector_off .. sector_off + chunk_len], remaining[0..chunk_len]);
            try self.writeSector(sector_idx, sector_buf, rng);

            remaining = remaining[chunk_len..];
            curr_offset += chunk_len;
        }
    }

    /// Arbitrary offset read convenience helper.
    pub fn readAt(self: *SimDisk, offset: u64, dest: []u8, rng: ?*sim_rng_mod.SimRng) !void {
        var remaining = dest;
        var curr_offset = offset;

        var sector_buf = try self.allocator.alloc(u8, self.sector_size);
        defer self.allocator.free(sector_buf);

        while (remaining.len > 0) {
            const sector_idx = curr_offset / self.sector_size;
            const sector_off = @as(usize, @intCast(curr_offset % self.sector_size));
            const chunk_len = @min(remaining.len, self.sector_size - sector_off);

            try self.readSector(sector_idx, sector_buf, rng);
            @memcpy(remaining[0..chunk_len], sector_buf[sector_off .. sector_off + chunk_len]);

            remaining = remaining[chunk_len..];
            curr_offset += chunk_len;
        }
    }
};

test "sim_disk basic write read and sync" {
    const allocator = std.testing.allocator;
    var disk = SimDisk.init(allocator, 512, 1024);
    defer disk.deinit();

    var write_buf: [512]u8 = undefined;
    @memset(&write_buf, 0xAB);
    try disk.writeSector(4, &write_buf, null);

    var read_buf: [512]u8 = undefined;
    try disk.readSector(4, &read_buf, null);
    try std.testing.expectEqualSlices(u8, &write_buf, &read_buf);

    try disk.sync();

    // After sync, committed sector persists
    @memset(&read_buf, 0);
    try disk.readSector(4, &read_buf, null);
    try std.testing.expectEqualSlices(u8, &write_buf, &read_buf);
}

test "sim_disk crash discards un-fsynced writes" {
    const allocator = std.testing.allocator;
    var disk = SimDisk.init(allocator, 512, 1024);
    defer disk.deinit();

    var buf1: [512]u8 = undefined;
    @memset(&buf1, 0x11);
    try disk.writeSector(1, &buf1, null);
    try disk.sync(); // Durable

    var buf2: [512]u8 = undefined;
    @memset(&buf2, 0x22);
    try disk.writeSector(1, &buf2, null); // Volatile overwrite

    // Simulate crash before sync
    disk.crash();

    var read_buf: [512]u8 = undefined;
    try disk.readSector(1, &read_buf, null);
    // Rolled back to durable 0x11
    try std.testing.expectEqualSlices(u8, &buf1, &read_buf);
}

test "sim_disk torn writes and fault injection" {
    const allocator = std.testing.allocator;
    var disk = SimDisk.init(allocator, 512, 1024);
    defer disk.deinit();

    disk.setFaults(.{ .torn_write_rate = 1.0 });

    var rng = sim_rng_mod.SimRng.init(42);
    var write_buf: [512]u8 = undefined;
    @memset(&write_buf, 0xEF);
    try disk.writeSector(5, &write_buf, &rng);

    var read_buf: [512]u8 = undefined;
    try disk.readSector(5, &read_buf, null);

    // First half was written, second half is zeroes
    for (read_buf[0..256]) |b| {
        try std.testing.expectEqual(@as(u8, 0xEF), b);
    }
    for (read_buf[256..512]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}
