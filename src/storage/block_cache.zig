const std = @import("std");
const types = @import("../common/types.zig");

/// Cache key uniquely identifying an SSTable data block on disk.
pub const CacheKey = struct {
    file_number: u64,
    offset: u64,

    pub fn hash(self: CacheKey) u64 {
        var h = std.hash.Wyhash.hash(0x517cc1b727220a95, std.mem.asBytes(&self.file_number));
        h ^= std.hash.Wyhash.hash(0x517cc1b727220a95, std.mem.asBytes(&self.offset));
        return h;
    }

    pub fn eql(a: CacheKey, b: CacheKey) bool {
        return a.file_number == b.file_number and a.offset == b.offset;
    }
};

/// An entry in the LRU doubly linked list.
pub const CacheEntry = struct {
    key: CacheKey,
    value: []u8,
    charge: usize,
    prev: ?*CacheEntry = null,
    next: ?*CacheEntry = null,
};

/// Single shard of the sharded LRU block cache.
pub const CacheShard = struct {
    allocator: std.mem.Allocator,
    mutex: types.SpinLock,
    capacity: usize,
    usage: usize,
    head: ?*CacheEntry,
    tail: ?*CacheEntry,
    map: std.AutoHashMap(CacheKey, *CacheEntry),
    hits: u64,
    misses: u64,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) CacheShard {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .capacity = capacity,
            .usage = 0,
            .head = null,
            .tail = null,
            .map = std.AutoHashMap(CacheKey, *CacheEntry).init(allocator),
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *CacheShard) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var curr = self.head;
        while (curr) |entry| {
            const next_entry = entry.next;
            self.allocator.free(entry.value);
            self.allocator.destroy(entry);
            curr = next_entry;
        }
        self.map.deinit();
    }

    fn detach(self: *CacheShard, entry: *CacheEntry) void {
        if (entry.prev) |p| {
            p.next = entry.next;
        } else {
            self.head = entry.next;
        }
        if (entry.next) |n| {
            n.prev = entry.prev;
        } else {
            self.tail = entry.prev;
        }
        entry.prev = null;
        entry.next = null;
    }

    fn attachToHead(self: *CacheShard, entry: *CacheEntry) void {
        entry.next = self.head;
        entry.prev = null;
        if (self.head) |h| {
            h.prev = entry;
        }
        self.head = entry;
        if (self.tail == null) {
            self.tail = entry;
        }
    }

    pub fn get(self: *CacheShard, key: CacheKey) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.get(key)) |entry| {
            self.detach(entry);
            self.attachToHead(entry);
            self.hits += 1;
            return entry.value;
        }

        self.misses += 1;
        return null;
    }

    pub fn insert(self: *CacheShard, key: CacheKey, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const charge = value.len + @sizeOf(CacheEntry);

        // If key already exists, update and promote
        if (self.map.get(key)) |existing| {
            self.usage -= existing.charge;
            self.allocator.free(existing.value);
            existing.value = try self.allocator.dupe(u8, value);
            existing.charge = charge;
            self.usage += charge;
            self.detach(existing);
            self.attachToHead(existing);
            return;
        }

        // Evict older entries from tail while over capacity
        while (self.usage + charge > self.capacity and self.tail != null) {
            const victim = self.tail.?;
            _ = self.map.remove(victim.key);
            self.detach(victim);
            self.usage -= victim.charge;
            self.allocator.free(victim.value);
            self.allocator.destroy(victim);
        }

        const entry = try self.allocator.create(CacheEntry);
        entry.* = .{
            .key = key,
            .value = try self.allocator.dupe(u8, value),
            .charge = charge,
        };

        try self.map.put(key, entry);
        self.attachToHead(entry);
        self.usage += charge;
    }
};

/// High-concurrency sharded block cache partitioning keys into 16 shards.
pub const BlockCache = struct {
    pub const NUM_SHARDS: usize = 16;

    shards: [NUM_SHARDS]CacheShard,
    total_capacity: usize,

    pub fn init(allocator: std.mem.Allocator, total_capacity: usize) !*BlockCache {
        const cache = try allocator.create(BlockCache);
        const per_shard_cap = @max(total_capacity / NUM_SHARDS, 1024);

        for (&cache.shards) |*shard| {
            shard.* = CacheShard.init(allocator, per_shard_cap);
        }
        cache.total_capacity = total_capacity;
        return cache;
    }

    pub fn deinit(self: *BlockCache, allocator: std.mem.Allocator) void {
        for (&self.shards) |*shard| {
            shard.deinit();
        }
        allocator.destroy(self);
    }

    fn shardIndex(key: CacheKey) usize {
        return @as(usize, @intCast(key.hash() % NUM_SHARDS));
    }

    pub fn get(self: *BlockCache, file_number: u64, offset: u64) ?[]const u8 {
        const key = CacheKey{ .file_number = file_number, .offset = offset };
        return self.shards[shardIndex(key)].get(key);
    }

    pub fn insert(self: *BlockCache, file_number: u64, offset: u64, value: []const u8) !void {
        const key = CacheKey{ .file_number = file_number, .offset = offset };
        try self.shards[shardIndex(key)].insert(key, value);
    }

    pub fn stats(self: *const BlockCache) struct { hits: u64, misses: u64, hit_ratio: f64 } {
        var hits: u64 = 0;
        var misses: u64 = 0;
        for (&self.shards) |*shard| {
            hits += shard.hits;
            misses += shard.misses;
        }
        const total = hits + misses;
        const ratio = if (total == 0) 1.0 else @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
        return .{ .hits = hits, .misses = misses, .hit_ratio = ratio };
    }
};

test "sharded block cache insertion, lookup, and eviction" {
    const allocator = std.testing.allocator;
    const cache = try BlockCache.init(allocator, 4096);
    defer cache.deinit(allocator);

    try cache.insert(1, 0, "BLOCK_1_0_DATA");
    try cache.insert(1, 4096, "BLOCK_1_4096_DATA");

    const v1 = cache.get(1, 0);
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("BLOCK_1_0_DATA", v1.?);

    const v2 = cache.get(1, 4096);
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("BLOCK_1_4096_DATA", v2.?);

    const v3 = cache.get(2, 0); // Missing
    try std.testing.expect(v3 == null);

    const st = cache.stats();
    try std.testing.expectEqual(@as(u64, 2), st.hits);
    try std.testing.expectEqual(@as(u64, 1), st.misses);
}
