const std = @import("std");
const ast = @import("ast.zig");

pub const PlanType = enum {
    point_get,
    point_put,
    point_delete,
    range_scan,
    vector_insert,
    vector_search,
    graph_node_insert,
    graph_edge_insert,
    graph_shortest_path,
    graph_neighbors,
    hybrid_search,
    txn_begin,
    txn_commit,
    txn_rollback,
};

/// Physical plan representation with estimated cost and execution strategy.
pub const Plan = struct {
    plan_type: PlanType,
    estimated_cost_micros: u64,
    statement: ast.Statement,

    pub fn init(plan_type: PlanType, estimated_cost: u64, stmt: ast.Statement) Plan {
        return .{
            .plan_type = plan_type,
            .estimated_cost_micros = estimated_cost,
            .statement = stmt,
        };
    }
};

/// Query planner analyzing AST statements and producing optimized execution plans.
pub const Planner = struct {
    pub fn plan(statement: ast.Statement) Plan {
        return switch (statement) {
            .get => Plan.init(.point_get, 5, statement),
            .put => Plan.init(.point_put, 10, statement),
            .delete => Plan.init(.point_delete, 8, statement),
            .scan => |s| Plan.init(.range_scan, @as(u64, @intCast(s.limit * 2)), statement),
            .vec_insert => Plan.init(.vector_insert, 50, statement),
            .vec_search => |v| Plan.init(.vector_search, @as(u64, @intCast(v.ef_search * 5)), statement),
            .graph_add_node => Plan.init(.graph_node_insert, 10, statement),
            .graph_add_edge => Plan.init(.graph_edge_insert, 15, statement),
            .graph_shortest_path => Plan.init(.graph_shortest_path, 100, statement),
            .graph_neighbors => |g| Plan.init(.graph_neighbors, @as(u64, @intCast(g.hops * 25)), statement),
            .hybrid_search => |h| Plan.init(.hybrid_search, @as(u64, @intCast(h.hops * 30 + 100)), statement),
            .begin => Plan.init(.txn_begin, 2, statement),
            .commit => Plan.init(.txn_commit, 20, statement),
            .rollback => Plan.init(.txn_rollback, 5, statement),
        };
    }
};

test "planner cost estimation" {
    const stmt = ast.Statement{ .get = .{ .key = "test_key" } };
    const p = Planner.plan(stmt);
    try std.testing.expectEqual(PlanType.point_get, p.plan_type);
    try std.testing.expect(p.estimated_cost_micros > 0);
}
