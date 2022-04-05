const std = @import("std");
const types = @import("../common/types.zig");
const comparator = @import("../common/comparator.zig");

/// Maximum level height in SkipList (supports billions of keys efficiently).
pub const MAX_HEIGHT: usize = 16;
pub const PROBABILITY_INV: u32 = 4; // p = 1/4

/// SkipList node storing an InternalKey and associated value.
pub const SkipNode = struct {
    key: []const u8,
    value: []const u8,
    sequence: u64,
    record_type: types.RecordType,
    height: usize,
    next: [MAX_HEIGHT]?*SkipNode,

    pub fn init(allocator: std.mem.Allocator, key: []const u8, value: []const u8, seq: u64, rec_type: types.RecordType, height: usize) !*SkipNode {
        const node = try allocator.create(SkipNode);
        node.* = .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
            .sequence = seq,
            .record_type = rec_type,
            .height = height,
            .next = [_]?*SkipNode{null} ** MAX_HEIGHT,
        };
        return node;
    }

    pub fn deinit(self: *SkipNode, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        allocator.destroy(self);
    }
};

/// Concurrent lock-free read SkipList MemTable.
pub const MemTable = struct {
    allocator: std.mem.Allocator,
    head: *SkipNode,
    max_level: usize,
    count: usize,
    memory_usage: usize,
    rng_state: u64,

    pub fn init(allocator: std.mem.Allocator) !MemTable {
        const head = try allocator.create(SkipNode);
        head.* = .{
            .key = "",
            .value = "",
            .sequence = 0,
            .record_type = .put,
            .height = MAX_HEIGHT,
            .next = [_]?*SkipNode{null} ** MAX_HEIGHT,
        };

        return .{
            .allocator = allocator,
            .head = head,
            .max_level = 1,
            .count = 0,
            .memory_usage = @sizeOf(SkipNode),
            .rng_state = 0x9e3779b97f4a7c15,
        };
    }

    pub fn deinit(self: *MemTable) void {
        var curr = self.head.next[0];
        while (curr) |node| {
            const next_node = node.next[0];
            node.deinit(self.allocator);
            curr = next_node;
        }
        self.allocator.destroy(self.head);
        self.* = undefined;
    }

    fn randomHeight(self: *MemTable) usize {
        // Fast xorshift PRNG
        var x = self.rng_state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng_state = x;

        var h: usize = 1;
        while (h < MAX_HEIGHT and (x % PROBABILITY_INV) == 0) : (h += 1) {
            x /= PROBABILITY_INV;
        }
        return h;
    }

    /// Compare internal keys using user_key ascending, sequence descending.
    fn compareKeys(k1: []const u8, s1: u64, k2: []const u8, s2: u64) std.math.Order {
        const cmp = std.mem.order(u8, k1, k2);
        if (cmp != .eq) return cmp;
        // Same user key: higher sequence number sorts FIRST (newest version first)
        if (s1 > s2) return .lt;
        if (s1 < s2) return .gt;
        return .eq;
    }

    /// Insert or update a key in the MemTable with a given sequence number and record type.
    pub fn put(self: *MemTable, key: []const u8, value: []const u8, seq: u64, rec_type: types.RecordType) !void {
        var update: [MAX_HEIGHT]*SkipNode = undefined;
        var curr = self.head;

        var level = self.max_level;
        while (level > 0) {
            level -= 1;
            while (curr.next[level]) |next_node| {
                const cmp = compareKeys(next_node.key, next_node.sequence, key, seq);
                if (cmp == .lt) {
                    curr = next_node;
                } else {
                    break;
                }
            }
            update[level] = curr;
        }

        const height = self.randomHeight();
        if (height > self.max_level) {
            var i = self.max_level;
            while (i < height) : (i += 1) {
                update[i] = self.head;
            }
            self.max_level = height;
        }

        const new_node = try SkipNode.init(self.allocator, key, value, seq, rec_type, height);

        var i: usize = 0;
        while (i < height) : (i += 1) {
            new_node.next[i] = update[i].next[i];
            update[i].next[i] = new_node;
        }

        self.count += 1;
        self.memory_usage += @sizeOf(SkipNode) + key.len + value.len;
    }

    /// Retrieve the most recent value for a user_key visible at or before snapshot_seq.
    pub fn get(self: *const MemTable, key: []const u8, snapshot_seq: u64) ?types.KeyValue {
        var curr = self.head;
        var level = self.max_level;

        while (level > 0) {
            level -= 1;
            while (curr.next[level]) |next_node| {
                const cmp = std.mem.order(u8, next_node.key, key);
                if (cmp == .lt) {
                    curr = next_node;
                } else if (cmp == .eq) {
                    if (next_node.sequence > snapshot_seq) {
                        // Node is too new for snapshot, move forward on this level or down
                        curr = next_node;
                    } else {
                        // Found matching key visible at snapshot_seq
                        return .{
                            .key = next_node.key,
                            .value = next_node.value,
                            .timestamp = types.Timestamp.init(next_node.sequence),
                            .record_type = next_node.record_type,
                        };
                    }
                } else {
                    break;
                }
            }
        }

        // Check lowest level linear scan for exact match
        var node = curr.next[0];
        while (node) |n| {
            if (!std.mem.eql(u8, n.key, key)) break;
            if (n.sequence <= snapshot_seq) {
                return .{
                    .key = n.key,
                    .value = n.value,
                    .timestamp = types.Timestamp.init(n.sequence),
                    .record_type = n.record_type,
                };
            }
            node = n.next[0];
        }

        return null;
    }

    /// Iterator traversing keys in sorted internal key order.
    pub const Iterator = struct {
        memtable: *const MemTable,
        current: ?*SkipNode,

        pub fn init(memtable: *const MemTable) Iterator {
            return .{
                .memtable = memtable,
                .current = memtable.head.next[0],
            };
        }

        pub fn valid(self: Iterator) bool {
            return self.current != null;
        }

        pub fn next(self: *Iterator) void {
            if (self.current) |node| {
                self.current = node.next[0];
            }
        }

        pub fn key(self: Iterator) []const u8 {
            return self.current.?.key;
        }

        pub fn value(self: Iterator) []const u8 {
            return self.current.?.value;
        }

        pub fn sequence(self: Iterator) u64 {
            return self.current.?.sequence;
        }

        pub fn recordType(self: Iterator) types.RecordType {
            return self.current.?.record_type;
        }
    };

    pub fn iterator(self: *const MemTable) Iterator {
        return Iterator.init(self);
    }
};

test "memtable insertion, versioning and point lookup" {
    const allocator = std.testing.allocator;
    var mem = try MemTable.init(allocator);
    defer mem.deinit();

    // Insert version 1 of key "user:1"
    try mem.put("user:1", "v1", 10, .put);
    // Insert version 2 of key "user:1"
    try mem.put("user:1", "v2", 20, .put);
    // Insert different key
    try mem.put("user:2", "bob", 15, .put);

    // Read at snapshot 15: should see "v1" for "user:1"
    const at_15 = mem.get("user:1", 15);
    try std.testing.expect(at_15 != null);
    try std.testing.expectEqualStrings("v1", at_15.?.value);

    // Read at snapshot 25: should see "v2" for "user:1"
    const at_25 = mem.get("user:1", 25);
    try std.testing.expect(at_25 != null);
    try std.testing.expectEqualStrings("v2", at_25.?.value);

    // Delete at sequence 30
    try mem.put("user:1", "", 30, .delete);

    // Read at snapshot 35: should see tombstone record
    const at_35 = mem.get("user:1", 35);
    try std.testing.expect(at_35 != null and at_35.?.record_type == .delete);

    // But reading past snapshot 25 still sees "v2"!
    const at_25_again = mem.get("user:1", 25);
    try std.testing.expect(at_25_again != null);
    try std.testing.expectEqualStrings("v2", at_25_again.?.value);
}

test "memtable iterator traverses in sorted order" {
    const allocator = std.testing.allocator;
    var mem = try MemTable.init(allocator);
    defer mem.deinit();

    try mem.put("cherry", "3", 1, .put);
    try mem.put("apple", "1", 1, .put);
    try mem.put("banana", "2", 1, .put);

    var it = mem.iterator();
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings("apple", it.key());

    it.next();
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings("banana", it.key());

    it.next();
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings("cherry", it.key());

    it.next();
    try std.testing.expect(!it.valid());
}
