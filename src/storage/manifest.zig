const std = @import("std");
const types = @import("../common/types.zig");

pub const NUM_LEVELS: usize = 7;

/// Metadata for a single SSTable file in the LSM hierarchy.
pub const FileMetaData = struct {
    file_number: u64,
    file_size: u64,
    smallest_key: []u8,
    largest_key: []u8,
    level: u32,

    pub fn clone(self: FileMetaData, allocator: std.mem.Allocator) !FileMetaData {
        return .{
            .file_number = self.file_number,
            .file_size = self.file_size,
            .smallest_key = try allocator.dupe(u8, self.smallest_key),
            .largest_key = try allocator.dupe(u8, self.largest_key),
            .level = self.level,
        };
    }

    pub fn deinit(self: *FileMetaData, allocator: std.mem.Allocator) void {
        allocator.free(self.smallest_key);
        allocator.free(self.largest_key);
        self.* = undefined;
    }
};

/// Record of an addition of an SSTable file.
pub const NewFile = struct {
    level: u32,
    meta: FileMetaData,
};

/// Record of a deletion of an SSTable file.
pub const DeletedFile = struct {
    level: u32,
    file_number: u64,
};

/// Delta edit to apply atomically to an LSM Version.
pub const VersionEdit = struct {
    log_number: ?u64 = null,
    next_file_number: ?u64 = null,
    last_sequence: ?u64 = null,
    new_files: std.ArrayList(NewFile),
    deleted_files: std.ArrayList(DeletedFile),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VersionEdit {
        return .{
            .allocator = allocator,
            .new_files = .empty,
            .deleted_files = .empty,
        };
    }

    pub fn deinit(self: *VersionEdit) void {
        for (self.new_files.items) |*nf| {
            nf.meta.deinit(self.allocator);
        }
        self.new_files.deinit(self.allocator);
        self.deleted_files.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addNewFile(self: *VersionEdit, level: u32, meta: FileMetaData) !void {
        const cloned = try meta.clone(self.allocator);
        try self.new_files.append(self.allocator, .{ .level = level, .meta = cloned });
    }

    pub fn addDeletedFile(self: *VersionEdit, level: u32, file_number: u64) !void {
        try self.deleted_files.append(self.allocator, .{ .level = level, .file_number = file_number });
    }
};

/// An immutable snapshot of all files currently residing at each level of the LSM-tree.
pub const Version = struct {
    allocator: std.mem.Allocator,
    files: [NUM_LEVELS]std.ArrayList(FileMetaData),

    pub fn init(allocator: std.mem.Allocator) Version {
        var v = Version{
            .allocator = allocator,
            .files = undefined,
        };
        for (&v.files) |*lvl| {
            lvl.* = .empty;
        }
        return v;
    }

    pub fn deinit(self: *Version) void {
        for (&self.files) |*lvl| {
            for (lvl.items) |*meta| {
                meta.deinit(self.allocator);
            }
            lvl.deinit(self.allocator);
        }
        self.* = undefined;
    }

    pub fn clone(self: *const Version, allocator: std.mem.Allocator) !Version {
        var copy = Version.init(allocator);
        for (self.files, 0..) |lvl, i| {
            for (lvl.items) |meta| {
                const cloned = try meta.clone(allocator);
                try copy.files[i].append(allocator, cloned);
            }
        }
        return copy;
    }

    /// Return count of files at a given LSM level.
    pub fn numFilesAtLevel(self: *const Version, level: usize) usize {
        if (level >= NUM_LEVELS) return 0;
        return self.files[level].items.len;
    }

    /// Total byte size of all files at a given LSM level.
    pub fn levelBytes(self: *const Version, level: usize) u64 {
        if (level >= NUM_LEVELS) return 0;
        var total: u64 = 0;
        for (self.files[level].items) |meta| {
            total += meta.file_size;
        }
        return total;
    }
};

/// Manages Version history, sequence counters, and Manifest updates.
pub const VersionSet = struct {
    allocator: std.mem.Allocator,
    current: *Version,
    next_file_number: u64,
    last_sequence: u64,
    log_number: u64,

    pub fn init(allocator: std.mem.Allocator) !*VersionSet {
        const vs = try allocator.create(VersionSet);
        const v = try allocator.create(Version);
        v.* = Version.init(allocator);

        vs.* = .{
            .allocator = allocator,
            .current = v,
            .next_file_number = 1,
            .last_sequence = 0,
            .log_number = 0,
        };
        return vs;
    }

    pub fn deinit(self: *VersionSet) void {
        self.current.deinit();
        self.allocator.destroy(self.current);
        self.allocator.destroy(self);
    }

    pub fn allocFileNumber(self: *VersionSet) u64 {
        const num = self.next_file_number;
        self.next_file_number += 1;
        return num;
    }

    /// Apply VersionEdit to create a new active Version.
    pub fn apply(self: *VersionSet, edit: *const VersionEdit) !void {
        var new_version = try self.current.clone(self.allocator);

        // Process deletions
        for (edit.deleted_files.items) |del| {
            if (del.level < NUM_LEVELS) {
                var items = &new_version.files[del.level];
                var i: usize = 0;
                while (i < items.items.len) {
                    if (items.items[i].file_number == del.file_number) {
                        var removed = items.swapRemove(i);
                        removed.deinit(self.allocator);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        // Process additions
        for (edit.new_files.items) |nf| {
            if (nf.level < NUM_LEVELS) {
                const cloned = try nf.meta.clone(self.allocator);
                try new_version.files[nf.level].append(self.allocator, cloned);
            }
        }

        if (edit.next_file_number) |nfn| {
            self.next_file_number = @max(self.next_file_number, nfn);
        }
        if (edit.last_sequence) |ls| {
            self.last_sequence = @max(self.last_sequence, ls);
        }
        if (edit.log_number) |ln| {
            self.log_number = ln;
        }

        // Replace current Version
        self.current.deinit();
        self.current.* = new_version;
    }
};

test "version edit application and level tracking" {
    const allocator = std.testing.allocator;
    const vs = try VersionSet.init(allocator);
    defer vs.deinit();

    var edit = VersionEdit.init(allocator);
    defer edit.deinit();

    try edit.addNewFile(0, .{
        .file_number = vs.allocFileNumber(),
        .file_size = 4096,
        .smallest_key = @constCast("aaa"),
        .largest_key = @constCast("ccc"),
        .level = 0,
    });

    try edit.addNewFile(1, .{
        .file_number = vs.allocFileNumber(),
        .file_size = 8192,
        .smallest_key = @constCast("ddd"),
        .largest_key = @constCast("fff"),
        .level = 1,
    });

    try vs.apply(&edit);

    try std.testing.expectEqual(@as(usize, 1), vs.current.numFilesAtLevel(0));
    try std.testing.expectEqual(@as(usize, 1), vs.current.numFilesAtLevel(1));
    try std.testing.expectEqual(@as(u64, 4096), vs.current.levelBytes(0));
    try std.testing.expectEqual(@as(u64, 8192), vs.current.levelBytes(1));

    // Delete file from Level 0
    var edit2 = VersionEdit.init(allocator);
    defer edit2.deinit();
    try edit2.addDeletedFile(0, 1);
    try vs.apply(&edit2);

    try std.testing.expectEqual(@as(usize, 0), vs.current.numFilesAtLevel(0));
    try std.testing.expectEqual(@as(usize, 1), vs.current.numFilesAtLevel(1));
}
