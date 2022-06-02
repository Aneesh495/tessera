const std = @import("std");
const types = @import("../common/types.zig");
const stats = @import("../common/stats.zig");
const wal = @import("wal.zig");
const memtable_mod = @import("memtable.zig");
const block_mod = @import("block.zig");
const sstable_mod = @import("sstable.zig");
const block_cache = @import("block_cache.zig");
const manifest = @import("manifest.zig");
const compaction = @import("compaction.zig");

pub const Config = struct {
    memtable_capacity_bytes: usize = 2 * 1024 * 1024, // 2 MB
    block_cache_capacity_bytes: usize = 16 * 1024 * 1024, // 16 MB
    sstable_block_size: usize = 4096,
};

/// Unified LSM-tree Key-Value Storage Engine.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    config: Config,
    active_mem: *memtable_mod.MemTable,
    imm_mems: std.ArrayList(*memtable_mod.MemTable),
    wal_writer: wal.WalWriter,
    cache: *block_cache.BlockCache,
    version_set: *manifest.VersionSet,
    // In-memory table storage indexed by file_number
    tables: std.AutoHashMap(u64, []const u8),
    sequence: u64,
    metrics: stats.EngineMetrics,
    mutex: types.SpinLock,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Engine {
        const eng = try allocator.create(Engine);
        const mem = try allocator.create(memtable_mod.MemTable);
        mem.* = try memtable_mod.MemTable.init(allocator);

        const cache = try block_cache.BlockCache.init(allocator, config.block_cache_capacity_bytes);
        const vs = try manifest.VersionSet.init(allocator);

        eng.* = .{
            .allocator = allocator,
            .config = config,
            .active_mem = mem,
            .imm_mems = .empty,
            .wal_writer = wal.WalWriter.init(allocator),
            .cache = cache,
            .version_set = vs,
            .tables = std.AutoHashMap(u64, []const u8).init(allocator),
            .sequence = 0,
            .metrics = stats.EngineMetrics.init(),
            .mutex = .{},
        };
        return eng;
    }

    pub fn deinit(self: *Engine) void {
        self.active_mem.deinit();
        self.allocator.destroy(self.active_mem);

        for (self.imm_mems.items) |imm| {
            imm.deinit();
            self.allocator.destroy(imm);
        }
        self.imm_mems.deinit(self.allocator);

        self.wal_writer.deinit();
        self.cache.deinit(self.allocator);
        self.version_set.deinit();

        var it = self.tables.valueIterator();
        while (it.next()) |tbl_bytes| {
            self.allocator.free(tbl_bytes.*);
        }
        self.tables.deinit();

        const alloc = self.allocator;
        alloc.destroy(self);
    }

    /// Write key-value pair to WAL and active MemTable.
    pub fn put(self: *Engine, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.sequence += 1;
        const seq = self.sequence;

        // 1. Append to WAL
        _ = try self.wal_writer.append(.{
            .sequence = seq,
            .record_type = .put,
            .key = key,
            .value = value,
        });

        // 2. Insert into active MemTable
        try self.active_mem.put(key, value, seq, .put);

        _ = self.metrics.writes_total.fetchAdd(1, .monotonic);

        // Check if memtable requires flushing
        if (self.active_mem.memory_usage >= self.config.memtable_capacity_bytes) {
            try self.flushActiveMemTableLocked();
        }
    }

    /// Mark key as deleted by appending a tombstone record.
    pub fn delete(self: *Engine, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.sequence += 1;
        const seq = self.sequence;

        _ = try self.wal_writer.append(.{
            .sequence = seq,
            .record_type = .delete,
            .key = key,
            .value = "",
        });

        try self.active_mem.put(key, "", seq, .delete);
        _ = self.metrics.deletes_total.fetchAdd(1, .monotonic);
    }

    /// Point lookup across active memtable, immutable memtables, and leveled SSTables.
    pub fn get(self: *Engine, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const snapshot_seq = self.sequence;
        _ = self.metrics.reads_total.fetchAdd(1, .monotonic);

        // 1. Search Active MemTable
        if (self.active_mem.get(key, snapshot_seq)) |kv| {
            if (kv.record_type == .delete or kv.record_type == .tombstone) return null;
            return try allocator.dupe(u8, kv.value);
        }

        // 2. Search Immutable MemTables (from newest to oldest)
        var i = self.imm_mems.items.len;
        while (i > 0) {
            i -= 1;
            const imm = self.imm_mems.items[i];
            if (imm.get(key, snapshot_seq)) |kv| {
                if (kv.record_type == .delete or kv.record_type == .tombstone) return null;
                return try allocator.dupe(u8, kv.value);
            }
        }

        // 3. Search SSTables across LSM levels
        const current_v = self.version_set.current;
        var lvl: usize = 0;
        while (lvl < manifest.NUM_LEVELS) : (lvl += 1) {
            const files = &current_v.files[lvl];
            for (files.items) |file_meta| {
                // Key range boundary check
                if (std.mem.order(u8, key, file_meta.smallest_key) == .lt or
                    std.mem.order(u8, key, file_meta.largest_key) == .gt)
                {
                    continue;
                }

                if (self.tables.get(file_meta.file_number)) |tbl_data| {
                    const reader = try sstable_mod.SSTableReader.init(tbl_data, file_meta.file_number, self.cache);
                    if (try reader.get(allocator, key)) |val| {
                        return val;
                    }
                }
            }
        }

        return null;
    }

    /// Flush active MemTable to a new Level 0 SSTable file.
    pub fn flush(self: *Engine) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushActiveMemTableLocked();
    }

    fn flushActiveMemTableLocked(self: *Engine) !void {
        if (self.active_mem.count == 0) return;

        // Build SSTable from active memtable iterator
        var builder = try sstable_mod.SSTableBuilder.init(self.allocator, self.config.sstable_block_size, self.active_mem.count);
        defer builder.deinit();

        var it = self.active_mem.iterator();
        var smallest: ?[]const u8 = null;
        var largest: ?[]const u8 = null;

        while (it.valid()) {
            if (smallest == null) smallest = it.key();
            largest = it.key();

            try builder.add(it.key(), it.value());
            it.next();
        }

        const sst_bytes = try builder.finish();
        const file_num = self.version_set.allocFileNumber();

        // Store SSTable bytes in table catalog
        const sst_clone = try self.allocator.dupe(u8, sst_bytes);
        try self.tables.put(file_num, sst_clone);

        // Record addition in VersionEdit
        var edit = manifest.VersionEdit.init(self.allocator);
        defer edit.deinit();

        try edit.addNewFile(0, .{
            .file_number = file_num,
            .file_size = sst_clone.len,
            .smallest_key = @constCast(smallest.?),
            .largest_key = @constCast(largest.?),
            .level = 0,
        });

        try self.version_set.apply(&edit);

        // Reset active MemTable and WAL
        self.active_mem.deinit();
        self.active_mem.* = try memtable_mod.MemTable.init(self.allocator);
        self.wal_writer.clear();
    }

    /// Run leveled compaction if level triggers are active.
    pub fn maybeCompact(self: *Engine) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const opt_task = try compaction.CompactionPicker.pickCompaction(self.allocator, self.version_set.current);
        if (opt_task == null) return false;

        var task = opt_task.?;
        defer task.deinit();

        // Perform merge compaction
        var merger = compaction.MergingIterator.init(self.allocator);
        defer merger.deinit();

        // Collect items from inputs
        for (task.inputs_level.items) |f| {
            if (self.tables.get(f.file_number)) |data| {
                const reader = try sstable_mod.SSTableReader.init(data, f.file_number, null);
                var idx_it = reader.index_reader.iterator(self.allocator);
                defer idx_it.deinit();
                try idx_it.seekToFirst();
                // Load blocks
                while (idx_it.valid()) {
                    var h_buf: [16]u8 = undefined;
                    @memcpy(&h_buf, idx_it.value()[0..16]);
                    const handle = sstable_mod.BlockHandle.decode(h_buf);
                    const b_data = data[handle.offset .. handle.offset + handle.size];
                    const dr = try block_mod.BlockReader.init(b_data);
                    var dit = dr.iterator(self.allocator);
                    defer dit.deinit();
                    try dit.seekToFirst();
                    while (dit.valid()) {
                        try merger.addItem(.{
                            .key = dit.key(),
                            .value = dit.value(),
                            .sequence = 0,
                            .record_type = .put,
                        });
                        try dit.next();
                    }
                    try idx_it.next();
                }
            }
        }

        merger.prepare();

        // Build new SSTable for next level
        var builder = try sstable_mod.SSTableBuilder.init(self.allocator, self.config.sstable_block_size, merger.items.items.len);
        defer builder.deinit();

        var smallest: ?[]const u8 = null;
        var largest: ?[]const u8 = null;

        while (merger.valid()) {
            const item = merger.current();
            if (smallest == null) smallest = item.key;
            largest = item.key;

            try builder.add(item.key, item.value);
            merger.nextUnique();
        }

        if (smallest != null and largest != null) {
            const out_bytes = try builder.finish();
            const out_file_num = self.version_set.allocFileNumber();
            const out_clone = try self.allocator.dupe(u8, out_bytes);
            try self.tables.put(out_file_num, out_clone);

            // Apply VersionEdit: delete old files, add new file
            var edit = manifest.VersionEdit.init(self.allocator);
            defer edit.deinit();

            for (task.inputs_level.items) |f| {
                try edit.addDeletedFile(task.level, f.file_number);
                if (self.tables.fetchRemove(f.file_number)) |kv| {
                    self.allocator.free(kv.value);
                }
            }

            const target_level = task.level + 1;
            try edit.addNewFile(target_level, .{
                .file_number = out_file_num,
                .file_size = out_clone.len,
                .smallest_key = @constCast(smallest.?),
                .largest_key = @constCast(largest.?),
                .level = target_level,
            });

            try self.version_set.apply(&edit);
            _ = self.metrics.compactions_completed.fetchAdd(1, .monotonic);
        }

        return true;
    }
};

test "engine full lifecycle: put, get, flush, and persistence" {
    const allocator = std.testing.allocator;
    const engine = try Engine.init(allocator, .{
        .memtable_capacity_bytes = 1024,
        .sstable_block_size = 512,
    });
    defer engine.deinit();

    // Writes
    try engine.put("order:001", "{\"item\":\"widget\",\"qty\":5}");
    try engine.put("order:002", "{\"item\":\"gadget\",\"qty\":1}");

    // MemTable read
    const v1 = try engine.get(allocator, "order:001");
    defer if (v1) |v| allocator.free(v);
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("{\"item\":\"widget\",\"qty\":5}", v1.?);

    // Flush to Level 0 SSTable
    try engine.flush();

    // Read from Level 0 SSTable
    const v2 = try engine.get(allocator, "order:002");
    defer if (v2) |v| allocator.free(v);
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("{\"item\":\"gadget\",\"qty\":1}", v2.?);

    // Delete
    try engine.delete("order:001");
    const v1_del = try engine.get(allocator, "order:001");
    defer if (v1_del) |v| allocator.free(v);
    try std.testing.expect(v1_del == null);
}
