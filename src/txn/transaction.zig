const std = @import("std");
const types = @import("../common/types.zig");
const mvcc = @import("mvcc.zig");
const engine_mod = @import("../storage/engine.zig");

pub const TxnStatus = enum(u8) {
    active = 1,
    committed = 2,
    aborted = 3,
};

pub const WriteEntry = struct {
    value: []u8,
    is_delete: bool,
};

/// Active transaction context supporting read-your-own-writes and Snapshot Isolation.
pub const Transaction = struct {
    allocator: std.mem.Allocator,
    id: types.TxnId,
    read_ts: u64,
    status: TxnStatus,
    manager: *mvcc.TransactionManager,
    engine: *engine_mod.Engine,
    // Uncommitted local write buffer
    write_buffer: std.StringHashMap(WriteEntry),

    pub fn init(
        allocator: std.mem.Allocator,
        manager: *mvcc.TransactionManager,
        engine: *engine_mod.Engine,
    ) !*Transaction {
        const txn_info = try manager.beginTxn();
        const txn = try allocator.create(Transaction);

        txn.* = .{
            .allocator = allocator,
            .id = txn_info.id,
            .read_ts = txn_info.read_ts,
            .status = .active,
            .manager = manager,
            .engine = engine,
            .write_buffer = std.StringHashMap(WriteEntry).init(allocator),
        };
        return txn;
    }

    pub fn deinit(self: *Transaction) void {
        if (self.status == .active) {
            self.rollback();
        }
        var it = self.write_buffer.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.write_buffer.deinit();
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    /// Read key value observing snapshot isolation and uncommitted local writes.
    pub fn get(self: *Transaction, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        if (self.status != .active) return error.TxnAborted;

        // 1. Read-your-own-writes: check local uncommitted write buffer
        if (self.write_buffer.get(key)) |item| {
            if (item.is_delete) return null;
            return try allocator.dupe(u8, item.value);
        }

        // 2. Query underlying engine
        return try self.engine.get(allocator, key);
    }

    /// Buffer uncommitted write in local transaction buffer.
    pub fn put(self: *Transaction, key: []const u8, value: []const u8) !void {
        if (self.status != .active) return error.TxnAborted;

        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);

        if (self.write_buffer.getEntry(key)) |entry| {
            self.allocator.free(entry.value_ptr.value);
            entry.value_ptr.value = val_copy;
            entry.value_ptr.is_delete = false;
        } else {
            const key_copy = try self.allocator.dupe(u8, key);
            try self.write_buffer.put(key_copy, .{ .value = val_copy, .is_delete = false });
        }
    }

    /// Buffer uncommitted delete in local transaction buffer.
    pub fn delete(self: *Transaction, key: []const u8) !void {
        if (self.status != .active) return error.TxnAborted;

        const empty_val = try self.allocator.alloc(u8, 0);

        if (self.write_buffer.getEntry(key)) |entry| {
            self.allocator.free(entry.value_ptr.value);
            entry.value_ptr.value = empty_val;
            entry.value_ptr.is_delete = true;
        } else {
            const key_copy = try self.allocator.dupe(u8, key);
            try self.write_buffer.put(key_copy, .{ .value = empty_val, .is_delete = true });
        }
    }

    /// Commit transaction atomically.
    pub fn commit(self: *Transaction) !void {
        if (self.status != .active) return error.TxnAborted;

        // Collect modified keys for conflict verification
        var keys = try self.allocator.alloc([]const u8, self.write_buffer.count());
        defer self.allocator.free(keys);

        var idx: usize = 0;
        var it = self.write_buffer.keyIterator();
        while (it.next()) |k| {
            keys[idx] = k.*;
            idx += 1;
        }

        // Validate and register commit with manager
        _ = try self.manager.commitTxn(self.id, self.read_ts, keys);

        // Apply buffered writes to storage engine
        var entry_it = self.write_buffer.iterator();
        while (entry_it.next()) |entry| {
            if (entry.value_ptr.is_delete) {
                try self.engine.delete(entry.key_ptr.*);
            } else {
                try self.engine.put(entry.key_ptr.*, entry.value_ptr.value);
            }
        }

        self.status = .committed;
    }

    /// Rollback transaction and discard uncommitted local writes.
    pub fn rollback(self: *Transaction) void {
        if (self.status == .active) {
            self.manager.abortTxn(self.id);
            self.status = .aborted;
        }
    }
};

test "transaction read-your-own-writes and atomic commit" {
    const allocator = std.testing.allocator;
    const engine = try engine_mod.Engine.init(allocator, .{});
    defer engine.deinit();

    var mgr = mvcc.TransactionManager.init(allocator);
    defer mgr.deinit();

    // Seed data
    try engine.put("balance:alice", "100");

    // Begin Txn
    var txn = try Transaction.init(allocator, &mgr, engine);
    defer txn.deinit();

    // Read initial balance
    const b0 = (try txn.get(allocator, "balance:alice")).?;
    defer allocator.free(b0);
    try std.testing.expectEqualStrings("100", b0);

    // Modify in transaction
    try txn.put("balance:alice", "250");

    // Read-your-own-writes: should see updated value "250"
    const b1 = (try txn.get(allocator, "balance:alice")).?;
    defer allocator.free(b1);
    try std.testing.expectEqualStrings("250", b1);

    // Underlying engine still sees uncommitted original value "100"
    const engine_val = (try engine.get(allocator, "balance:alice")).?;
    defer allocator.free(engine_val);
    try std.testing.expectEqualStrings("100", engine_val);

    // Commit
    try txn.commit();

    // Now underlying engine sees committed value "250"
    const committed_val = (try engine.get(allocator, "balance:alice")).?;
    defer allocator.free(committed_val);
    try std.testing.expectEqualStrings("250", committed_val);
}
