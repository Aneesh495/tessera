const std = @import("std");

/// Wait-free Single-Producer Single-Consumer (SPSC) bounded ring buffer.
/// Head and tail pointers are placed on distinct cache lines to prevent false sharing.
pub fn SpscRingBuffer(comptime T: type, comptime Capacity: usize) type {
    comptime {
        // Enforce power-of-two capacity for fast bitwise masking
        if ((Capacity & (Capacity - 1)) != 0 or Capacity == 0) {
            @compileError("Capacity must be a non-zero power of two");
        }
    }

    return struct {
        const Self = @This();
        const MASK: usize = Capacity - 1;

        // Producer cache line
        producer_head: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        cached_tail: usize = 0,

        // Consumer cache line
        consumer_tail: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        cached_head: usize = 0,

        // Storage buffer
        buffer: [Capacity]T align(64) = undefined,

        pub fn init() Self {
            return .{};
        }

        /// Attempt to push an item without blocking. Returns error.Full if ring is full.
        pub fn push(self: *Self, item: T) !void {
            const head = self.producer_head.load(.monotonic);
            // Check against cached tail before loading atomic tail
            if (head -% self.cached_tail >= Capacity) {
                self.cached_tail = self.consumer_tail.load(.acquire);
                if (head -% self.cached_tail >= Capacity) {
                    return error.Full;
                }
            }

            self.buffer[head & MASK] = item;
            self.producer_head.store(head +% 1, .release);
        }

        /// Attempt to pop an item without blocking. Returns error.Empty if ring is empty.
        pub fn pop(self: *Self) !T {
            const tail = self.consumer_tail.load(.monotonic);
            // Check against cached head before loading atomic head
            if (tail == self.cached_head) {
                self.cached_head = self.producer_head.load(.acquire);
                if (tail == self.cached_head) {
                    return error.Empty;
                }
            }

            const item = self.buffer[tail & MASK];
            self.consumer_tail.store(tail +% 1, .release);
            return item;
        }

        /// Return approximate count of pending items.
        pub fn count(self: *const Self) usize {
            const head = self.producer_head.load(.monotonic);
            const tail = self.consumer_tail.load(.monotonic);
            return head -% tail;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.count() >= Capacity;
        }
    };
}

test "spsc ring buffer basic operations" {
    var ring = SpscRingBuffer(u64, 16).init();

    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), ring.count());

    var i: u64 = 0;
    while (i < 16) : (i += 1) {
        try ring.push(i * 10);
    }

    try std.testing.expect(ring.isFull());
    try std.testing.expectError(error.Full, ring.push(999));

    i = 0;
    while (i < 16) : (i += 1) {
        const val = try ring.pop();
        try std.testing.expectEqual(i * 10, val);
    }

    try std.testing.expect(ring.isEmpty());
    try std.testing.expectError(error.Empty, ring.pop());
}

test "spsc ring buffer wraparound across full capacity" {
    var ring = SpscRingBuffer(u32, 8).init();

    var round: u32 = 0;
    while (round < 100) : (round += 1) {
        try ring.push(round);
        const val = try ring.pop();
        try std.testing.expectEqual(round, val);
    }
}
