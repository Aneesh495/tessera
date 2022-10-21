const std = @import("std");
const sim_clock_mod = @import("sim_clock.zig");
const sim_rng_mod = @import("sim_rng.zig");

pub const NodeStatus = enum {
    online,
    crashed,
    isolated,
};

pub const SimMessage = struct {
    id: u64,
    from: u32,
    to: u32,
    deliver_at_micros: u64,
    payload: []const u8,
};

pub const NetworkFaults = struct {
    drop_rate: f32 = 0.0,
    duplicate_rate: f32 = 0.0,
    min_latency_micros: u64 = 50,
    max_latency_micros: u64 = 500,
};

/// Simulated multi-node cluster and packet switched network for DST.
/// Injects network partitions, packet drops, reordering, and node crashes.
pub const SimCluster = struct {
    allocator: std.mem.Allocator,
    node_count: u32,
    node_statuses: []NodeStatus,
    in_flight_messages: std.ArrayList(SimMessage),
    mailboxes: []std.ArrayList(SimMessage),
    partitions: std.AutoHashMap(u64, bool), // key: (from << 32) | to -> true if partitioned
    faults: NetworkFaults,
    next_msg_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, node_count: u32) !SimCluster {
        const statuses = try allocator.alloc(NodeStatus, node_count);
        @memset(statuses, .online);

        const mailboxes = try allocator.alloc(std.ArrayList(SimMessage), node_count);
        for (0..node_count) |i| {
            mailboxes[i] = std.ArrayList(SimMessage).empty;
        }

        return .{
            .allocator = allocator,
            .node_count = node_count,
            .node_statuses = statuses,
            .in_flight_messages = std.ArrayList(SimMessage).empty,
            .mailboxes = mailboxes,
            .partitions = std.AutoHashMap(u64, bool).init(allocator),
            .faults = .{},
            .next_msg_id = 1,
        };
    }

    pub fn deinit(self: *SimCluster) void {
        for (self.in_flight_messages.items) |msg| {
            self.allocator.free(msg.payload);
        }
        self.in_flight_messages.deinit(self.allocator);

        for (0..self.node_count) |i| {
            for (self.mailboxes[i].items) |msg| {
                self.allocator.free(msg.payload);
            }
            self.mailboxes[i].deinit(self.allocator);
        }
        self.allocator.free(self.mailboxes);
        self.allocator.free(self.node_statuses);
        self.partitions.deinit();
        self.* = undefined;
    }

    pub fn setFaults(self: *SimCluster, faults: NetworkFaults) void {
        self.faults = faults;
    }

    fn partitionKey(from: u32, to: u32) u64 {
        return (@as(u64, from) << 32) | @as(u64, to);
    }

    /// Cut communication link between group_a and group_b.
    pub fn partition(self: *SimCluster, group_a: []const u32, group_b: []const u32) !void {
        for (group_a) |a| {
            for (group_b) |b| {
                try self.partitions.put(partitionKey(a, b), true);
                try self.partitions.put(partitionKey(b, a), true);
            }
        }
    }

    /// Restore all network partitions to fully connected state.
    pub fn healPartitions(self: *SimCluster) void {
        self.partitions.clearRetainingCapacity();
    }

    pub fn crashNode(self: *SimCluster, node_id: u32) void {
        if (node_id < self.node_count) {
            self.node_statuses[node_id] = .crashed;
            // Purge node mailbox upon crash
            for (self.mailboxes[node_id].items) |msg| {
                self.allocator.free(msg.payload);
            }
            self.mailboxes[node_id].clearRetainingCapacity();
        }
    }

    pub fn recoverNode(self: *SimCluster, node_id: u32) void {
        if (node_id < self.node_count) {
            self.node_statuses[node_id] = .online;
        }
    }

    /// Send a message from node `from` to node `to`.
    pub fn send(
        self: *SimCluster,
        from: u32,
        to: u32,
        payload: []const u8,
        clock: *sim_clock_mod.SimClock,
        rng: ?*sim_rng_mod.SimRng,
    ) !void {
        if (from >= self.node_count or to >= self.node_count) return;
        if (self.node_statuses[from] == .crashed) return;

        // Probabilistic packet drop
        if (rng) |r| {
            if (r.chance(self.faults.drop_rate)) return;
        }

        var latency: u64 = self.faults.min_latency_micros;
        if (rng) |r| {
            if (self.faults.max_latency_micros > self.faults.min_latency_micros) {
                latency = r.nextRangeU64(self.faults.min_latency_micros, self.faults.max_latency_micros);
            }
        }

        const deliver_at = clock.now() + latency;
        const duped_payload = try self.allocator.dupe(u8, payload);

        const msg_id = self.next_msg_id;
        self.next_msg_id += 1;

        const msg = SimMessage{
            .id = msg_id,
            .from = from,
            .to = to,
            .deliver_at_micros = deliver_at,
            .payload = duped_payload,
        };

        try self.in_flight_messages.append(self.allocator, msg);

        // Schedule timer on virtual clock
        try clock.schedule(deliver_at, msg_id, 0);

        // Duplicate delivery injection
        if (rng) |r| {
            if (r.chance(self.faults.duplicate_rate)) {
                const dup_payload = try self.allocator.dupe(u8, payload);
                const dup_msg = SimMessage{
                    .id = self.next_msg_id,
                    .from = from,
                    .to = to,
                    .deliver_at_micros = deliver_at + 10,
                    .payload = dup_payload,
                };
                self.next_msg_id += 1;
                try self.in_flight_messages.append(self.allocator, dup_msg);
                try clock.schedule(deliver_at + 10, dup_msg.id, 0);
            }
        }
    }

    /// Step simulation forward: process and route all in-flight messages ready at current clock time.
    pub fn step(self: *SimCluster, current_time_micros: u64) !usize {
        var delivered: usize = 0;
        var i: usize = 0;

        while (i < self.in_flight_messages.items.len) {
            const msg = self.in_flight_messages.items[i];
            if (msg.deliver_at_micros <= current_time_micros) {
                _ = self.in_flight_messages.orderedRemove(i);

                // Check destination node status
                if (self.node_statuses[msg.to] == .crashed) {
                    self.allocator.free(msg.payload);
                    continue;
                }

                // Check network partition
                const key = partitionKey(msg.from, msg.to);
                if (self.partitions.get(key) orelse false) {
                    // Dropped by partition
                    self.allocator.free(msg.payload);
                    continue;
                }

                // Deliver to target mailbox
                try self.mailboxes[msg.to].append(self.allocator, msg);
                delivered += 1;
            } else {
                i += 1;
            }
        }

        return delivered;
    }

    /// Receive next message from a node's mailbox, popping it.
    pub fn receive(self: *SimCluster, node_id: u32) ?SimMessage {
        if (node_id >= self.node_count) return null;
        if (self.mailboxes[node_id].items.len == 0) return null;
        return self.mailboxes[node_id].orderedRemove(0);
    }
};

test "sim_cluster point-to-point delivery" {
    const allocator = std.testing.allocator;
    var clock = sim_clock_mod.SimClock.init(allocator);
    defer clock.deinit();

    var cluster = try SimCluster.init(allocator, 3);
    defer cluster.deinit();

    try cluster.send(0, 1, "PING", &clock, null);
    try std.testing.expectEqual(@as(usize, 1), cluster.in_flight_messages.items.len);

    // Advance clock past minimum latency
    clock.advance(100);
    const delivered = try cluster.step(clock.now());
    try std.testing.expectEqual(@as(usize, 1), delivered);

    // Check node 1 received message
    const msg = cluster.receive(1).?;
    defer allocator.free(msg.payload);
    try std.testing.expectEqualStrings("PING", msg.payload);
    try std.testing.expectEqual(@as(u32, 0), msg.from);
}

test "sim_cluster network partition and healing" {
    const allocator = std.testing.allocator;
    var clock = sim_clock_mod.SimClock.init(allocator);
    defer clock.deinit();

    var cluster = try SimCluster.init(allocator, 4);
    defer cluster.deinit();

    // Partition {0, 1} from {2, 3}
    const group_a = [_]u32{ 0, 1 };
    const group_b = [_]u32{ 2, 3 };
    try cluster.partition(&group_a, &group_b);

    // Node 0 attempts to send to Node 2 (partitioned)
    try cluster.send(0, 2, "CROSS_MSG", &clock, null);
    clock.advance(100);
    _ = try cluster.step(clock.now());

    // Message should be dropped by partition
    try std.testing.expect(cluster.receive(2) == null);

    // Heal partition and retry
    cluster.healPartitions();
    try cluster.send(0, 2, "HEALED_MSG", &clock, null);
    clock.advance(100);
    _ = try cluster.step(clock.now());

    const received = cluster.receive(2).?;
    defer allocator.free(received.payload);
    try std.testing.expectEqualStrings("HEALED_MSG", received.payload);
}
