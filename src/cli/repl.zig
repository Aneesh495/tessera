const std = @import("std");
const tessera = @import("tessera");

/// Interactive terminal REPL for executing Tessera Query Language (TQL) statements.
pub const Repl = struct {
    allocator: std.mem.Allocator,
    engine: *tessera.Engine,
    vidx: *tessera.HnswIndex,
    graph: *tessera.GraphStore,
    txns: *tessera.TransactionManager,
    executor: tessera.query.executor.Executor,

    pub fn init(allocator: std.mem.Allocator) !Repl {
        const engine = try tessera.Engine.init(allocator, .{});
        errdefer engine.deinit();

        const vidx = try tessera.HnswIndex.init(allocator, 16, .l2);
        errdefer vidx.deinit();

        const graph_ptr = try allocator.create(tessera.GraphStore);
        errdefer allocator.destroy(graph_ptr);
        graph_ptr.* = tessera.GraphStore.init(allocator);

        const txns_ptr = try allocator.create(tessera.TransactionManager);
        errdefer allocator.destroy(txns_ptr);
        txns_ptr.* = tessera.TransactionManager.init(allocator);

        const exec = tessera.query.executor.Executor.init(
            allocator,
            engine,
            vidx,
            graph_ptr,
            txns_ptr,
        );

        return .{
            .allocator = allocator,
            .engine = engine,
            .vidx = vidx,
            .graph = graph_ptr,
            .txns = txns_ptr,
            .executor = exec,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.engine.deinit();
        self.vidx.deinit();
        self.graph.deinit();
        self.allocator.destroy(self.graph);
        self.txns.deinit();
        self.allocator.destroy(self.txns);
        self.* = undefined;
    }

    /// Evaluate a single input line. Returns false if REPL should terminate.
    pub fn evalLine(self: *Repl, line: []const u8, writer: anytype) !bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return true;

        if (std.mem.eql(u8, trimmed, ".exit") or std.mem.eql(u8, trimmed, ".quit")) {
            try writer.print("Exiting Tessera.\n", .{});
            return false;
        }

        if (std.mem.eql(u8, trimmed, ".help")) {
            try writer.print(
                \\Tessera Interactive Shell
                \\  Commands:
                \\    PUT <key> <value>               - Write key-value pair
                \\    GET <key>                       - Retrieve value by key
                \\    DELETE <key>                    - Delete key
                \\    VEC_INSERT <id> [x, y, ...]     - Insert embedding vector
                \\    VEC_SEARCH [x, y, ...] TOP <k>  - Search nearest vectors
                \\    GRAPH_ADD_NODE <id> <prop>      - Add graph vertex
                \\    GRAPH_ADD_EDGE <u> <v> [w]      - Add directed edge
                \\    GRAPH_SHORTEST_PATH <u> <v>     - Dijkstra shortest path
                \\    GRAPH_NEIGHBORS <id> HOPS <k>   - K-hop BFS neighborhood
                \\    HYBRID_SEARCH <seed> [vec] TOP  - Joint topological-vector search
                \\    BEGIN / COMMIT / ROLLBACK       - Snapshot transaction controls
                \\    .metrics                        - Print runtime engine statistics
                \\    .help                           - Show this help message
                \\    .exit                           - Exit shell
                \\
            , .{});
            return true;
        }

        if (std.mem.eql(u8, trimmed, ".metrics")) {
            const writes = self.engine.metrics.writes_total.load(.monotonic);
            const reads = self.engine.metrics.reads_total.load(.monotonic);
            const deletes = self.engine.metrics.deletes_total.load(.monotonic);
            const compactions = self.engine.metrics.compactions_completed.load(.monotonic);

            try writer.print(
                \\Engine Metrics:
                \\  Writes:      {d}
                \\  Reads:       {d}
                \\  Deletes:     {d}
                \\  Compactions: {d}
                \\  Vector Count:{d}
                \\  Graph Nodes: {d}
                \\
            , .{
                writes,
                reads,
                deletes,
                compactions,
                self.vidx.count(),
                self.graph.nodeCount(),
            });
            return true;
        }

        // Parse and execute TQL statement
        var parser = tessera.query.parser.Parser.init(self.allocator, trimmed);
        const stmt = parser.parseStatement() catch |err| {
            try writer.print("Parse error: {s}\n", .{@errorName(err)});
            return true;
        };
        defer @constCast(&stmt).deinit(self.allocator);

        const plan = tessera.query.planner.Planner.plan(stmt);
        var res = self.executor.execute(plan) catch |err| {
            try writer.print("Execution error: {s}\n", .{@errorName(err)});
            return true;
        };
        defer res.deinit();

        switch (res.result_type) {
            .ok => {
                try writer.print("{s} [{d} us]\n", .{ res.text, res.elapsed_micros });
            },
            .value => {
                try writer.print("\"{s}\" [{d} us]\n", .{ res.text, res.elapsed_micros });
            },
            .err => {
                try writer.print("Error: {s} [{d} us]\n", .{ res.text, res.elapsed_micros });
            },
            .vector_matches => {
                try writer.print("Vector Matches ({d}):\n", .{res.vector_candidates.items.len});
                for (res.vector_candidates.items) |cand| {
                    try writer.print("  [ID: {d}] Distance: {d:.4}\n", .{ cand.id.toInt(), cand.dist });
                }
                try writer.print("[{d} us]\n", .{res.elapsed_micros});
            },
            .nodes => {
                try writer.print("Nodes ({d}): [", .{res.node_ids.items.len});
                for (res.node_ids.items, 0..) |nid, idx| {
                    if (idx > 0) try writer.print(", ", .{});
                    try writer.print("{d}", .{nid.toInt()});
                }
                try writer.print("] [{d} us]\n", .{res.elapsed_micros});
            },
            .path => {
                try writer.print("Shortest Path: ", .{});
                for (res.node_ids.items, 0..) |nid, idx| {
                    if (idx > 0) try writer.print(" -> ", .{});
                    try writer.print("{d}", .{nid.toInt()});
                }
                try writer.print(" [{d} us]\n", .{res.elapsed_micros});
            },
            .rows => {
                try writer.print("Rows returned [{d} us]\n", .{res.elapsed_micros});
            },
        }

        return true;
    }
};

test "repl evaluation of basic statements" {
    const allocator = std.testing.allocator;
    var repl = try Repl.init(allocator);
    defer repl.deinit();

    var out_buf = std.ArrayList(u8).empty;
    defer out_buf.deinit(allocator);

    // Test help command
    const continue1 = try repl.evalLine(".help", out_buf.writer(allocator));
    try std.testing.expect(continue1);
    try std.testing.expect(out_buf.items.len > 0);
    out_buf.clearRetainingCapacity();

    // Test PUT
    const continue2 = try repl.evalLine("PUT user:alpha \"active\"", out_buf.writer(allocator));
    try std.testing.expect(continue2);
    out_buf.clearRetainingCapacity();

    // Test GET
    const continue3 = try repl.evalLine("GET user:alpha", out_buf.writer(allocator));
    try std.testing.expect(continue3);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.items, "\"active\"") != null);
    out_buf.clearRetainingCapacity();

    // Test exit command
    const should_exit = try repl.evalLine(".exit", out_buf.writer(allocator));
    try std.testing.expect(!should_exit);
}
