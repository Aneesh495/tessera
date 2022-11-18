const std = @import("std");
const protocol = @import("protocol.zig");
const parser_mod = @import("../query/parser.zig");
const planner_mod = @import("../query/planner.zig");
const executor_mod = @import("../query/executor.zig");

pub const ServerMetrics = struct {
    total_requests: u64 = 0,
    successful_requests: u64 = 0,
    failed_requests: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
};

/// High-performance network server executing TQL queries over binary wire protocol.
pub const Server = struct {
    allocator: std.mem.Allocator,
    executor: *executor_mod.Executor,
    metrics: ServerMetrics = .{},

    pub fn init(allocator: std.mem.Allocator, executor: *executor_mod.Executor) Server {
        return .{
            .allocator = allocator,
            .executor = executor,
            .metrics = .{},
        };
    }

    /// Process a raw wire message buffer and return serialized response packet.
    pub fn processBuffer(self: *Server, raw_request: []const u8) ![]u8 {
        self.metrics.total_requests += 1;
        self.metrics.bytes_received += raw_request.len;

        const req_pkt = protocol.Packet.deserialize(raw_request) catch |err| {
            self.metrics.failed_requests += 1;
            const err_msg = @errorName(err);
            return try protocol.Packet.serialize(
                self.allocator,
                .err,
                .err_corrupted,
                0,
                err_msg,
            );
        };

        return try self.handlePacket(req_pkt);
    }

    /// Handle a decoded request packet and produce serialized response.
    pub fn handlePacket(self: *Server, req: protocol.Packet) ![]u8 {
        switch (req.header.opcode) {
            .ping => {
                self.metrics.successful_requests += 1;
                return try protocol.Packet.serialize(
                    self.allocator,
                    .pong,
                    .ok,
                    req.header.req_id,
                    "PONG",
                );
            },
            .query => {
                const query_str = req.payload;
                var parser = parser_mod.Parser.init(self.allocator, query_str);
                const stmt = parser.parseStatement() catch |err| {
                    self.metrics.failed_requests += 1;
                    const err_str = @errorName(err);
                    return try protocol.Packet.serialize(
                        self.allocator,
                        .err,
                        .err_syntax,
                        req.header.req_id,
                        err_str,
                    );
                };
                defer @constCast(&stmt).deinit(self.allocator);

                const plan = planner_mod.Planner.plan(stmt);
                var q_res = self.executor.execute(plan) catch |err| {
                    self.metrics.failed_requests += 1;
                    const err_str = @errorName(err);
                    return try protocol.Packet.serialize(
                        self.allocator,
                        .err,
                        .err_execution,
                        req.header.req_id,
                        err_str,
                    );
                };
                defer q_res.deinit();

                self.metrics.successful_requests += 1;
                const resp_text = q_res.text;
                return try protocol.Packet.serialize(
                    self.allocator,
                    .response,
                    .ok,
                    req.header.req_id,
                    resp_text,
                );
            },
            else => {
                self.metrics.failed_requests += 1;
                return try protocol.Packet.serialize(
                    self.allocator,
                    .err,
                    .err_syntax,
                    req.header.req_id,
                    "UNSUPPORTED_OPCODE",
                );
            },
        }
    }
};

test "server handles ping pong" {
    const allocator = std.testing.allocator;
    const engine_mod = @import("../storage/engine.zig");
    const hnsw = @import("../vector/hnsw.zig");
    const adjacency = @import("../graph/adjacency.zig");
    const mvcc = @import("../txn/mvcc.zig");

    const engine = try engine_mod.Engine.init(allocator, .{});
    defer engine.deinit();
    const vidx = try hnsw.HnswIndex.init(allocator, 4, .l2);
    defer vidx.deinit();
    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();
    var txns = mvcc.TransactionManager.init(allocator);
    defer txns.deinit();

    var exec = executor_mod.Executor.init(allocator, engine, vidx, &graph, &txns);
    var server = Server.init(allocator, &exec);

    const ping_req = try protocol.Packet.serialize(allocator, .ping, .ok, 101, "");
    defer allocator.free(ping_req);

    const resp_raw = try server.processBuffer(ping_req);
    defer allocator.free(resp_raw);

    const resp = try protocol.Packet.deserialize(resp_raw);
    try std.testing.expectEqual(protocol.Opcode.pong, resp.header.opcode);
    try std.testing.expectEqual(@as(u64, 101), resp.header.req_id);
    try std.testing.expectEqualStrings("PONG", resp.payload);
}
