const std = @import("std");

pub const OpType = enum {
    read,
    write,
};

/// An operation executed against the key-value register during concurrent testing.
pub const Operation = struct {
    id: u64,
    client_id: u32,
    op_type: OpType,
    key: []const u8,
    value: []const u8, // For write: written value; for read: observed value
    invoke_time: u64,
    return_time: u64,
};

pub const CheckResult = struct {
    is_linearizable: bool,
    violation_op_id: ?u64 = null,
};

/// Register state model used to verify sequential validity.
pub const RegisterModel = struct {
    state: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RegisterModel {
        return .{
            .state = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RegisterModel) void {
        self.state.deinit();
    }

    pub fn clone(self: *RegisterModel) !RegisterModel {
        var copy = RegisterModel.init(self.allocator);
        var it = self.state.iterator();
        while (it.next()) |entry| {
            try copy.state.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return copy;
    }

    /// Check if step is valid against current state. If valid, applies the step.
    pub fn step(self: *RegisterModel, op: Operation) bool {
        switch (op.op_type) {
            .read => {
                const cur_val = self.state.get(op.key) orelse "";
                return std.mem.eql(u8, cur_val, op.value);
            },
            .write => {
                self.state.put(op.key, op.value) catch return false;
                return true;
            },
        }
    }
};

/// Deterministic history checker verifying linearizability of concurrent executions
/// using the Wing & Gong / Porcupine state-space exploration algorithm.
pub const LinearizabilityChecker = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList(Operation),

    pub fn init(allocator: std.mem.Allocator) LinearizabilityChecker {
        return .{
            .allocator = allocator,
            .history = std.ArrayList(Operation).empty,
        };
    }

    pub fn deinit(self: *LinearizabilityChecker) void {
        for (self.history.items) |op| {
            self.allocator.free(op.key);
            self.allocator.free(op.value);
        }
        self.history.deinit(self.allocator);
        self.* = undefined;
    }

    /// Record completed operation with real-time timestamps.
    pub fn record(
        self: *LinearizabilityChecker,
        id: u64,
        client_id: u32,
        op_type: OpType,
        key: []const u8,
        value: []const u8,
        invoke_time: u64,
        return_time: u64,
    ) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.history.append(self.allocator, .{
            .id = id,
            .client_id = client_id,
            .op_type = op_type,
            .key = k,
            .value = v,
            .invoke_time = invoke_time,
            .return_time = return_time,
        });
    }

    /// Verify whether the entire recorded history is linearizable.
    pub fn verify(self: *LinearizabilityChecker) !CheckResult {
        const n = self.history.items.len;
        if (n == 0) return .{ .is_linearizable = true };

        const matched = try self.allocator.alloc(bool, n);
        defer self.allocator.free(matched);
        @memset(matched, false);

        var model = RegisterModel.init(self.allocator);
        defer model.deinit();

        const success = try self.searchLinearization(&model, matched, 0);
        return .{
            .is_linearizable = success,
            .violation_op_id = if (success) null else self.history.items[n - 1].id,
        };
    }

    fn searchLinearization(
        self: *LinearizabilityChecker,
        model: *RegisterModel,
        matched: []bool,
        linearized_count: usize,
    ) !bool {
        const total = self.history.items.len;
        if (linearized_count == total) return true;

        // Find minimal return time among unmatched operations
        var min_unmatched_return: u64 = std.math.maxInt(u64);
        for (self.history.items, 0..) |op, i| {
            if (!matched[i] and op.return_time < min_unmatched_return) {
                min_unmatched_return = op.return_time;
            }
        }

        // Candidate operations for the next step must have invoke_time <= min_unmatched_return
        for (self.history.items, 0..) |op, i| {
            if (matched[i]) continue;
            if (op.invoke_time > min_unmatched_return) continue;

            // Try applying this operation
            var model_snapshot = try model.clone();
            defer model_snapshot.deinit();

            if (model_snapshot.step(op)) {
                matched[i] = true;
                const path_valid = try self.searchLinearization(&model_snapshot, matched, linearized_count + 1);
                if (path_valid) return true;
                matched[i] = false;
            }
        }

        return false;
    }
};

test "linearizability valid concurrent execution" {
    const allocator = std.testing.allocator;
    var checker = LinearizabilityChecker.init(allocator);
    defer checker.deinit();

    // Client 1: Write "k", "v1" from [10, 50]
    try checker.record(1, 1, .write, "k", "v1", 10, 50);

    // Client 2: Read "k", "v1" from [30, 70] (overlaps with write)
    try checker.record(2, 2, .read, "k", "v1", 30, 70);

    // Client 3: Read "k", "v1" from [80, 100] (strictly after write)
    try checker.record(3, 3, .read, "k", "v1", 80, 100);

    const res = try checker.verify();
    try std.testing.expect(res.is_linearizable);
}

test "linearizability stale read violation detection" {
    const allocator = std.testing.allocator;
    var checker = LinearizabilityChecker.init(allocator);
    defer checker.deinit();

    // Client 1 writes "v1" [10, 20]
    try checker.record(1, 1, .write, "k", "v1", 10, 20);

    // Client 2 writes "v2" [30, 40] (strictly after v1)
    try checker.record(2, 2, .write, "k", "v2", 30, 40);

    // Client 3 reads stale "v1" [50, 60] (strictly after v2 finished!)
    try checker.record(3, 3, .read, "k", "v1", 50, 60);

    const res = try checker.verify();
    // Must flag violation because read occurred strictly after v2 was committed
    try std.testing.expect(!res.is_linearizable);
}
