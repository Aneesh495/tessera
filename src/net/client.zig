const std = @import("std");
const protocol = @import("protocol.zig");
const server_mod = @import("server.zig");

pub const ClientResponse = struct {
    status: protocol.ResponseStatus,
    payload: []const u8,
    req_id: u64,
    allocator: std.mem.Allocator,
    raw_buffer: []u8,

    pub fn deinit(self: *ClientResponse) void {
        self.allocator.free(self.raw_buffer);
        self.* = undefined;
    }
};

/// High-performance client handle communicating with Tessera database server.
pub const Client = struct {
    allocator: std.mem.Allocator,
    next_req_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .next_req_id = 1,
        };
    }

    /// Dispatch a PING message and wait for PONG.
    pub fn ping(self: *Client, server: *server_mod.Server) !bool {
        const req_id = self.next_req_id;
        self.next_req_id += 1;

        const req_buf = try protocol.Packet.serialize(self.allocator, .ping, .ok, req_id, "");
        defer self.allocator.free(req_buf);

        const resp_buf = try server.processBuffer(req_buf);
        defer self.allocator.free(resp_buf);

        const pkt = try protocol.Packet.deserialize(resp_buf);
        return pkt.header.opcode == .pong and pkt.header.status == .ok;
    }

    /// Send a TQL query string to server and parse response.
    pub fn query(self: *Client, server: *server_mod.Server, query_text: []const u8) !ClientResponse {
        const req_id = self.next_req_id;
        self.next_req_id += 1;

        const req_buf = try protocol.Packet.serialize(self.allocator, .query, .ok, req_id, query_text);
        defer self.allocator.free(req_buf);

        const resp_buf = try server.processBuffer(req_buf);
        errdefer self.allocator.free(resp_buf);

        const pkt = try protocol.Packet.deserialize(resp_buf);
        return ClientResponse{
            .status = pkt.header.status,
            .payload = pkt.payload,
            .req_id = pkt.header.req_id,
            .allocator = self.allocator,
            .raw_buffer = resp_buf,
        };
    }
};

test "client server query round trip" {
    const allocator = std.testing.allocator;
    const engine_mod = @import("../storage/engine.zig");
    const hnsw = @import("../vector/hnsw.zig");
    const adjacency = @import("../graph/adjacency.zig");
    const mvcc = @import("../txn/mvcc.zig");
    const executor_mod = @import("../query/executor.zig");

    const engine = try engine_mod.Engine.init(allocator, .{});
    defer engine.deinit();
    const vidx = try hnsw.HnswIndex.init(allocator, 2, .l2);
    defer vidx.deinit();
    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();
    var txns = mvcc.TransactionManager.init(allocator);
    defer txns.deinit();

    var exec = executor_mod.Executor.init(allocator, engine, vidx, &graph, &txns);
    var srv = server_mod.Server.init(allocator, &exec);
    var client = Client.init(allocator);

    // Ping check
    const is_alive = try client.ping(&srv);
    try std.testing.expect(is_alive);

    // PUT query
    var res1 = try client.query(&srv, "PUT alpha:100 \"prime_value\"");
    defer res1.deinit();
    try std.testing.expectEqual(protocol.ResponseStatus.ok, res1.status);
    try std.testing.expectEqualStrings("OK", res1.payload);

    // GET query
    var res2 = try client.query(&srv, "GET alpha:100");
    defer res2.deinit();
    try std.testing.expectEqual(protocol.ResponseStatus.ok, res2.status);
    try std.testing.expectEqualStrings("prime_value", res2.payload);
}
