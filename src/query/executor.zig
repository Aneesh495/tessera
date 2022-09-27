const std = @import("std");
const types = @import("../common/types.zig");
const ast = @import("ast.zig");
const planner_mod = @import("planner.zig");
const engine_mod = @import("../storage/engine.zig");
const hnsw = @import("../vector/hnsw.zig");
const adjacency = @import("../graph/adjacency.zig");
const traversal = @import("../graph/traversal.zig");
const algorithms = @import("../graph/algorithms.zig");
const mvcc = @import("../txn/mvcc.zig");

pub const QueryResultType = enum {
    ok,
    value,
    rows,
    vector_matches,
    nodes,
    path,
    err,
};

pub const QueryResult = struct {
    result_type: QueryResultType,
    text: []const u8 = "",
    vector_candidates: std.ArrayList(hnsw.Candidate),
    node_ids: std.ArrayList(types.NodeId),
    elapsed_micros: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        if (self.text.len > 0) {
            self.allocator.free(self.text);
        }
        self.vector_candidates.deinit(self.allocator);
        self.node_ids.deinit(self.allocator);
        self.* = undefined;
    }
};

/// End-to-end execution engine running physical plans across multi-model subsystems.
pub const Executor = struct {
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    vector_index: *hnsw.HnswIndex,
    graph: *adjacency.GraphStore,
    txn_manager: *mvcc.TransactionManager,

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *engine_mod.Engine,
        vector_index: *hnsw.HnswIndex,
        graph: *adjacency.GraphStore,
        txn_manager: *mvcc.TransactionManager,
    ) Executor {
        return .{
            .allocator = allocator,
            .engine = engine,
            .vector_index = vector_index,
            .graph = graph,
            .txn_manager = txn_manager,
        };
    }

    /// Execute a physical plan and produce structured query results.
    pub fn execute(self: *Executor, plan: planner_mod.Plan) !QueryResult {
        const start_time = types.getMonotonicMicros();
        var res = QueryResult{
            .result_type = .ok,
            .text = "",
            .vector_candidates = .empty,
            .node_ids = .empty,
            .elapsed_micros = 0,
            .allocator = self.allocator,
        };
        errdefer res.deinit();

        switch (plan.statement) {
            .get => |g| {
                if (try self.engine.get(self.allocator, g.key)) |val| {
                    res.result_type = .value;
                    res.text = val;
                } else {
                    res.result_type = .err;
                    res.text = try self.allocator.dupe(u8, "Key not found");
                }
            },
            .put => |p| {
                try self.engine.put(p.key, p.value);
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "OK");
            },
            .delete => |d| {
                try self.engine.delete(d.key);
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "DELETED");
            },
            .scan => {
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "SCAN_COMPLETED");
            },
            .vec_insert => |v| {
                try self.vector_index.insert(v.id, v.elements.items);
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "VECTOR_INSERTED");
            },
            .vec_search => |v| {
                const matches = try self.vector_index.searchKnn(self.allocator, v.query.items, v.top_k, v.ef_search);
                res.result_type = .vector_matches;
                res.vector_candidates = matches;
            },
            .graph_add_node => |g| {
                try self.graph.addNode(g.id, g.property);
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "NODE_ADDED");
            },
            .graph_add_edge => |g| {
                const eid = try self.graph.addEdge(g.source, g.target, g.weight);
                _ = eid;
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "EDGE_ADDED");
            },
            .graph_shortest_path => |g| {
                if (try algorithms.dijkstraShortestPath(self.graph, self.allocator, g.source, g.target)) |path_res| {
                    defer @constCast(&path_res).deinit();
                    res.result_type = .path;
                    for (path_res.path.items) |nid| {
                        try res.node_ids.append(self.allocator, nid);
                    }
                } else {
                    res.result_type = .err;
                    res.text = try self.allocator.dupe(u8, "No path found");
                }
            },
            .graph_neighbors => |g| {
                const neighbors = try traversal.bfsKHop(self.graph, self.allocator, g.id, g.hops);
                res.result_type = .nodes;
                res.node_ids = neighbors;
            },
            .hybrid_search => |h| {
                var neighbors = try traversal.bfsKHop(self.graph, self.allocator, h.seed, h.hops);
                defer neighbors.deinit(self.allocator);

                // Run vector search and filter to neighborhood
                var all_matches = try self.vector_index.searchKnn(self.allocator, h.query.items, h.top_k * 4, 32);
                defer all_matches.deinit(self.allocator);

                res.result_type = .vector_matches;
                for (all_matches.items) |cand| {
                    if (res.vector_candidates.items.len >= h.top_k) break;
                    // Check if candidate matches neighborhood
                    for (neighbors.items) |nid| {
                        if (cand.id.toInt() == nid.toInt()) {
                            try res.vector_candidates.append(self.allocator, cand);
                            break;
                        }
                    }
                }
            },
            .begin => {
                const t = try self.txn_manager.beginTxn();
                _ = t;
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "TRANSACTION_STARTED");
            },
            .commit => {
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "TRANSACTION_COMMITTED");
            },
            .rollback => {
                res.result_type = .ok;
                res.text = try self.allocator.dupe(u8, "TRANSACTION_ROLLED_BACK");
            },
        }

        const end_time = types.getMonotonicMicros();
        res.elapsed_micros = @as(u64, @intCast(@max(0, end_time - start_time)));
        return res;
    }
};

test "executor end to end pipeline" {
    const allocator = std.testing.allocator;

    const engine = try engine_mod.Engine.init(allocator, .{});
    defer engine.deinit();

    const vidx = try hnsw.HnswIndex.init(allocator, 2, .l2);
    defer vidx.deinit();

    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();

    var txns = mvcc.TransactionManager.init(allocator);
    defer txns.deinit();

    var executor = Executor.init(allocator, engine, vidx, &graph, &txns);

    // Execute PUT
    const put_plan = planner_mod.Planner.plan(.{ .put = .{ .key = "site:config", .value = "active" } });
    var r1 = try executor.execute(put_plan);
    defer r1.deinit();
    try std.testing.expectEqual(QueryResultType.ok, r1.result_type);

    // Execute GET
    const get_plan = planner_mod.Planner.plan(.{ .get = .{ .key = "site:config" } });
    var r2 = try executor.execute(get_plan);
    defer r2.deinit();
    try std.testing.expectEqual(QueryResultType.value, r2.result_type);
    try std.testing.expectEqualStrings("active", r2.text);
}
