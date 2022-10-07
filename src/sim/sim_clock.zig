const std = @import("std");

/// Timer event scheduled on the simulated virtual clock.
pub const TimerEvent = struct {
    fire_time_micros: u64,
    event_id: u64,
    payload: u64 = 0,
};

/// Discrete virtual clock with deterministic event scheduling and step progression.
/// Enables reproducible time control in deterministic simulation tests.
pub const SimClock = struct {
    current_time_micros: u64 = 0,
    allocator: std.mem.Allocator,
    events: std.ArrayList(TimerEvent),

    pub fn init(allocator: std.mem.Allocator) SimClock {
        return .{
            .current_time_micros = 0,
            .allocator = allocator,
            .events = std.ArrayList(TimerEvent).empty,
        };
    }

    pub fn deinit(self: *SimClock) void {
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// Current virtual clock timestamp in microseconds.
    pub fn now(self: SimClock) u64 {
        return self.current_time_micros;
    }

    /// Advance virtual time unconditionally by delta microseconds.
    pub fn advance(self: *SimClock, delta_micros: u64) void {
        self.current_time_micros += delta_micros;
    }

    /// Schedule an event to trigger at target microsecond timestamp.
    pub fn schedule(self: *SimClock, at_micros: u64, event_id: u64, payload: u64) !void {
        const evt = TimerEvent{
            .fire_time_micros = at_micros,
            .event_id = event_id,
            .payload = payload,
        };

        // Insert in ascending order of fire_time_micros
        var insert_idx: usize = 0;
        while (insert_idx < self.events.items.len) : (insert_idx += 1) {
            if (self.events.items[insert_idx].fire_time_micros > at_micros) {
                break;
            }
        }
        try self.events.insert(self.allocator, insert_idx, evt);
    }

    /// Cancel a scheduled event by event_id. Returns true if found and removed.
    pub fn cancel(self: *SimClock, event_id: u64) bool {
        for (self.events.items, 0..) |evt, idx| {
            if (evt.event_id == event_id) {
                _ = self.events.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Step the clock forward to the next scheduled event time and pop the event.
    pub fn step(self: *SimClock) ?TimerEvent {
        if (self.events.items.len == 0) return null;
        const evt = self.events.orderedRemove(0);
        if (evt.fire_time_micros > self.current_time_micros) {
            self.current_time_micros = evt.fire_time_micros;
        }
        return evt;
    }

    /// Advance time up to target timestamp, popping all events ready by then.
    pub fn stepUntil(self: *SimClock, target_micros: u64, out_events: *std.ArrayList(TimerEvent)) !usize {
        var count: usize = 0;
        while (self.events.items.len > 0 and self.events.items[0].fire_time_micros <= target_micros) {
            const evt = self.events.orderedRemove(0);
            try out_events.append(self.allocator, evt);
            count += 1;
        }
        if (target_micros > self.current_time_micros) {
            self.current_time_micros = target_micros;
        }
        return count;
    }

    /// Check number of pending scheduled events.
    pub fn pendingCount(self: SimClock) usize {
        return self.events.items.len;
    }
};

test "sim_clock basic advancement and scheduling" {
    const allocator = std.testing.allocator;
    var clock = SimClock.init(allocator);
    defer clock.deinit();

    try std.testing.expectEqual(@as(u64, 0), clock.now());
    clock.advance(150);
    try std.testing.expectEqual(@as(u64, 150), clock.now());

    try clock.schedule(500, 1, 42);
    try clock.schedule(300, 2, 99);
    try clock.schedule(1000, 3, 100);

    try std.testing.expectEqual(@as(usize, 3), clock.pendingCount());

    // Step to first event (at 300)
    const e1 = clock.step().?;
    try std.testing.expectEqual(@as(u64, 2), e1.event_id);
    try std.testing.expectEqual(@as(u64, 300), clock.now());

    // Step to second event (at 500)
    const e2 = clock.step().?;
    try std.testing.expectEqual(@as(u64, 1), e2.event_id);
    try std.testing.expectEqual(@as(u64, 500), clock.now());

    // Cancel third event
    try std.testing.expect(clock.cancel(3));
    try std.testing.expectEqual(@as(usize, 0), clock.pendingCount());
    try std.testing.expect(clock.step() == null);
}

test "sim_clock stepUntil batch processing" {
    const allocator = std.testing.allocator;
    var clock = SimClock.init(allocator);
    defer clock.deinit();

    try clock.schedule(100, 10, 0);
    try clock.schedule(200, 20, 0);
    try clock.schedule(300, 30, 0);
    try clock.schedule(500, 40, 0);

    var triggered = std.ArrayList(TimerEvent).empty;
    defer triggered.deinit(allocator);

    const count = try clock.stepUntil(250, &triggered);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 250), clock.now());
    try std.testing.expectEqual(@as(usize, 2), clock.pendingCount());
}
