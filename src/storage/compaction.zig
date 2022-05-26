const std = @import("std");
const types = @import("../common/types.zig");
const manifest = @import("manifest.zig");

pub const L0_COMPACTION_TRIGGER: usize = 4;
pub const BASE_LEVEL_BYTES: u64 = 10 * 1024 * 1024; // 10 MB for L1
pub const LEVEL_MULTIPLIER: u64 = 10;

/// Details of a chosen compaction task between Level N and Level N+1.
pub const CompactionTask = struct {
    level: u32,
    score: f64,
    inputs_level: std.ArrayList(manifest.FileMetaData),
    inputs_next_level: std.ArrayList(manifest.FileMetaData),
    smallest_key: []u8,
    largest_key: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, level: u32, score: f64) CompactionTask {
        return .{
            .level = level,
            .score = score,
            .inputs_level = .empty,
            .inputs_next_level = .empty,
            .smallest_key = "",
            .largest_key = "",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompactionTask) void {
        for (self.inputs_level.items) |*f| {
            f.deinit(self.allocator);
        }
        self.inputs_level.deinit(self.allocator);

        for (self.inputs_next_level.items) |*f| {
            f.deinit(self.allocator);
        }
        self.inputs_next_level.deinit(self.allocator);

        if (self.smallest_key.len > 0) self.allocator.free(self.smallest_key);
        if (self.largest_key.len > 0) self.allocator.free(self.largest_key);
        self.* = undefined;
    }
};

/// Compaction controller scoring levels and selecting candidates for merge.
pub const CompactionPicker = struct {
    pub fn maxBytesForLevel(level: usize) u64 {
        if (level == 0) return 0; // L0 is file-count triggered
        var bytes = BASE_LEVEL_BYTES;
        var i: usize = 1;
        while (i < level) : (i += 1) {
            bytes *= LEVEL_MULTIPLIER;
        }
        return bytes;
    }

    /// Score all levels and select the best compaction candidate.
    pub fn pickCompaction(allocator: std.mem.Allocator, version: *const manifest.Version) !?CompactionTask {
        var best_level: ?usize = null;
        var best_score: f64 = 0.0;

        // Check Level 0 file count trigger
        const l0_files = version.numFilesAtLevel(0);
        const l0_score = @as(f64, @floatFromInt(l0_files)) / @as(f64, @floatFromInt(L0_COMPACTION_TRIGGER));
        if (l0_score > best_score) {
            best_score = l0_score;
            best_level = 0;
        }

        // Check Level 1..6 byte threshold triggers
        var lvl: usize = 1;
        while (lvl < manifest.NUM_LEVELS - 1) : (lvl += 1) {
            const current_bytes = version.levelBytes(lvl);
            const max_bytes = maxBytesForLevel(lvl);
            const score = @as(f64, @floatFromInt(current_bytes)) / @as(f64, @floatFromInt(max_bytes));
            if (score > best_score) {
                best_score = score;
                best_level = lvl;
            }
        }

        // Only compact if score >= 1.0
        if (best_score < 1.0 or best_level == null) {
            return null;
        }

        const chosen_level = @as(u32, @intCast(best_level.?));
        var task = CompactionTask.init(allocator, chosen_level, best_score);

        // Pick input files from chosen level
        const level_files = &version.files[chosen_level];
        if (level_files.items.len > 0) {
            const candidate = try level_files.items[0].clone(allocator);
            try task.inputs_level.append(allocator, candidate);

            task.smallest_key = try allocator.dupe(u8, candidate.smallest_key);
            task.largest_key = try allocator.dupe(u8, candidate.largest_key);

            // Find overlapping files in next level
            const next_level = chosen_level + 1;
            if (next_level < manifest.NUM_LEVELS) {
                const next_files = &version.files[next_level];
                for (next_files.items) |f| {
                    // Check key overlap: f.smallest <= task.largest and f.largest >= task.smallest
                    const overlap = std.mem.order(u8, f.smallest_key, task.largest_key) != .gt and
                        std.mem.order(u8, f.largest_key, task.smallest_key) != .lt;

                    if (overlap) {
                        const overlap_file = try f.clone(allocator);
                        try task.inputs_next_level.append(allocator, overlap_file);
                    }
                }
            }
        }

        return task;
    }
};

/// Multi-way merge iterator deduplicating keys and dropping obsolete versions.
pub const MergingIterator = struct {
    pub const Item = struct {
        key: []const u8,
        value: []const u8,
        sequence: u64,
        record_type: types.RecordType,
    };

    items: std.ArrayList(Item),
    cursor: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MergingIterator {
        return .{
            .items = .empty,
            .cursor = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MergingIterator) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addItem(self: *MergingIterator, item: Item) !void {
        try self.items.append(self.allocator, item);
    }

    fn sortItems(ctx: void, a: Item, b: Item) bool {
        _ = ctx;
        const cmp = std.mem.order(u8, a.key, b.key);
        if (cmp == .lt) return true;
        if (cmp == .gt) return false;
        // Same key: higher sequence number comes first
        return a.sequence > b.sequence;
    }

    /// Sort and deduplicate items, retaining only the latest version per user key.
    pub fn prepare(self: *MergingIterator) void {
        std.mem.sort(Item, self.items.items, {}, sortItems);
        self.cursor = 0;
    }

    pub fn valid(self: *const MergingIterator) bool {
        return self.cursor < self.items.items.len;
    }

    pub fn current(self: *const MergingIterator) Item {
        return self.items.items[self.cursor];
    }

    /// Advance to next unique user key (skipping older versions).
    pub fn nextUnique(self: *MergingIterator) void {
        if (self.cursor >= self.items.items.len) return;
        const current_key = self.items.items[self.cursor].key;
        self.cursor += 1;
        while (self.cursor < self.items.items.len and std.mem.eql(u8, self.items.items[self.cursor].key, current_key)) {
            self.cursor += 1;
        }
    }
};

test "compaction picker detects score triggers" {
    const allocator = std.testing.allocator;
    const vs = try manifest.VersionSet.init(allocator);
    defer vs.deinit();

    // No files: no compaction needed
    const t0 = try CompactionPicker.pickCompaction(allocator, vs.current);
    try std.testing.expect(t0 == null);

    // Add 4 files to Level 0 (trigger threshold)
    var edit = manifest.VersionEdit.init(allocator);
    defer edit.deinit();

    var i: u64 = 1;
    while (i <= 4) : (i += 1) {
        try edit.addNewFile(0, .{
            .file_number = i,
            .file_size = 4096,
            .smallest_key = @constCast("a"),
            .largest_key = @constCast("z"),
            .level = 0,
        });
    }
    try vs.apply(&edit);

    var task = (try CompactionPicker.pickCompaction(allocator, vs.current)).?;
    defer task.deinit();

    try std.testing.expectEqual(@as(u32, 0), task.level);
    try std.testing.expect(task.score >= 1.0);
    try std.testing.expect(task.inputs_level.items.len > 0);
}

test "merging iterator deduplication and sequence ordering" {
    const allocator = std.testing.allocator;
    var merger = MergingIterator.init(allocator);
    defer merger.deinit();

    // Key "k1" version 1 and 2
    try merger.addItem(.{ .key = "k1", .value = "old", .sequence = 10, .record_type = .put });
    try merger.addItem(.{ .key = "k1", .value = "new", .sequence = 20, .record_type = .put });
    // Key "k2" version 1
    try merger.addItem(.{ .key = "k2", .value = "val2", .sequence = 15, .record_type = .put });

    merger.prepare();

    try std.testing.expect(merger.valid());
    const first = merger.current();
    try std.testing.expectEqualStrings("k1", first.key);
    try std.testing.expectEqualStrings("new", first.value);
    try std.testing.expectEqual(@as(u64, 20), first.sequence);

    merger.nextUnique();
    try std.testing.expect(merger.valid());
    const second = merger.current();
    try std.testing.expectEqualStrings("k2", second.key);
    try std.testing.expectEqualStrings("val2", second.value);

    merger.nextUnique();
    try std.testing.expect(!merger.valid());
}
