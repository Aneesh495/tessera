const std = @import("std");
const types = @import("../common/types.zig");

pub const IsolationLevel = enum(u8) {
    read_committed = 1,
    snapshot_isolation = 2,
    serializable = 3,
};

/// Entry in the MVCC version chain for a key.
pub const VersionRecord = struct {
    commit_ts: u64,
    value: []const u8,
    is_tombstone: bool,
    prev: ?*VersionRecord = null,
};

/// Global MVCC Transaction Manager coordinating timestamps, conflicts, and version chains.
pub const TransactionManager = struct {
    allocator: std.mem.Allocator,
    next_txn_id: std.atomic.Value(u64),
    global_commit_ts: std.atomic.Value(u64),
    // Map of active transactions: TxnId -> read_ts
    active_txns: std.AutoHashMap(types.TxnId, u64),
    // Commit history for write-conflict detection: user_key -> last_commit_ts
    last_commits: std.StringHashMap(u64),
    mutex: types.SpinLock,

    pub fn init(allocator: std.mem.Allocator) TransactionManager {
        return .{
            .allocator = allocator,
            .next_txn_id = std.atomic.Value(u64).init(1),
            .global_commit_ts = std.atomic.Value(u64).init(1),
            .active_txns = std.AutoHashMap(types.TxnId, u64).init(allocator),
            .last_commits = std.StringHashMap(u64).init(allocator),
            .mutex = types.SpinLock.init(),
        };
    }

    pub fn deinit(self: *TransactionManager) void {
        self.active_txns.deinit();

        var it = self.last_commits.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.last_commits.deinit();
    }

    /// Begin a new transaction and assign a read snapshot timestamp.
    pub fn beginTxn(self: *TransactionManager) !struct { id: types.TxnId, read_ts: u64 } {
        self.mutex.lock();
        defer self.mutex.unlock();

        const txn_id = types.TxnId.init(self.next_txn_id.fetchAdd(1, .monotonic));
        const read_ts = self.global_commit_ts.load(.monotonic);

        try self.active_txns.put(txn_id, read_ts);
        return .{ .id = txn_id, .read_ts = read_ts };
    }

    /// Check for write-write conflicts: verify no key was modified after read_ts.
    pub fn validateConflicts(self: *TransactionManager, read_ts: u64, write_keys: []const []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (write_keys) |k| {
            if (self.last_commits.get(k)) |committed_ts| {
                if (committed_ts > read_ts) {
                    // Concurrent transaction committed changes to this key after our read timestamp!
                    return false;
                }
            }
        }
        return true;
    }

    /// Commit transaction: assign commit timestamp, record modified keys, and remove from active list.
    pub fn commitTxn(self: *TransactionManager, txn_id: types.TxnId, read_ts: u64, write_keys: []const []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 1. Validate first-committer-wins rule
        for (write_keys) |k| {
            if (self.last_commits.get(k)) |committed_ts| {
                if (committed_ts > read_ts) {
                    return error.TxnConflict;
                }
            }
        }

        // 2. Allocate monotonic commit timestamp
        const commit_ts = self.global_commit_ts.fetchAdd(1, .monotonic) + 1;

        // 3. Update last commit timestamp for all modified keys
        for (write_keys) |k| {
            if (self.last_commits.get(k)) |_| {
                try self.last_commits.put(k, commit_ts);
            } else {
                const key_copy = try self.allocator.dupe(u8, k);
                try self.last_commits.put(key_copy, commit_ts);
            }
        }

        // 4. Deregister from active transactions
        _ = self.active_txns.remove(txn_id);

        return commit_ts;
    }

    /// Rollback transaction and remove from active list without applying changes.
    pub fn abortTxn(self: *TransactionManager, txn_id: types.TxnId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.active_txns.remove(txn_id);
    }

    /// Return oldest active snapshot timestamp (watermark for vacuuming dead versions).
    pub fn getWatermark(self: *TransactionManager) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var oldest: u64 = self.global_commit_ts.load(.monotonic);
        var it = self.active_txns.valueIterator();
        while (it.next()) |read_ts| {
            if (read_ts.* < oldest) oldest = read_ts.*;
        }
        return oldest;
    }
};

test "mvcc transaction begin, commit, and conflict detection" {
    const allocator = std.testing.allocator;
    var mgr = TransactionManager.init(allocator);
    defer mgr.deinit();

    // Start Txn 1
    const t1 = try mgr.beginTxn();
    try std.testing.expectEqual(@as(u64, 1), t1.read_ts);

    // Start Txn 2 concurrently
    const t2 = try mgr.beginTxn();
    try std.testing.expectEqual(@as(u64, 1), t2.read_ts);

    // Txn 1 modifies "account:101" and commits
    const keys_t1 = [_][]const u8{"account:101"};
    const commit_t1 = try mgr.commitTxn(t1.id, t1.read_ts, &keys_t1);
    try std.testing.expect(commit_t1 > t1.read_ts);

    // Txn 2 attempts to commit changes to "account:101"
    const keys_t2 = [_][]const u8{"account:101"};
    // Should fail with TxnConflict because account:101 was modified by Txn 1!
    try std.testing.expectError(error.TxnConflict, mgr.commitTxn(t2.id, t2.read_ts, &keys_t2));

    mgr.abortTxn(t2.id);
}
