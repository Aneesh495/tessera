const std = @import("std");
const types = @import("../common/types.zig");

pub const StatementType = enum {
    get,
    put,
    delete,
    scan,
    vec_insert,
    vec_search,
    graph_add_node,
    graph_add_edge,
    graph_shortest_path,
    graph_neighbors,
    hybrid_search,
    begin,
    commit,
    rollback,
};

pub const GetStatement = struct {
    key: []const u8,
};

pub const PutStatement = struct {
    key: []const u8,
    value: []const u8,
};

pub const DeleteStatement = struct {
    key: []const u8,
};

pub const ScanStatement = struct {
    start_key: []const u8,
    end_key: []const u8,
    limit: usize = 100,
};

pub const VecInsertStatement = struct {
    id: types.VectorId,
    elements: std.ArrayList(f32),
};

pub const VecSearchStatement = struct {
    query: std.ArrayList(f32),
    top_k: usize = 10,
    ef_search: usize = 32,
};

pub const GraphAddNodeStatement = struct {
    id: types.NodeId,
    property: []const u8,
};

pub const GraphAddEdgeStatement = struct {
    source: types.NodeId,
    target: types.NodeId,
    weight: f32 = 1.0,
};

pub const GraphShortestPathStatement = struct {
    source: types.NodeId,
    target: types.NodeId,
};

pub const GraphNeighborsStatement = struct {
    id: types.NodeId,
    hops: usize = 1,
};

pub const HybridSearchStatement = struct {
    seed: types.NodeId,
    hops: usize = 2,
    query: std.ArrayList(f32),
    top_k: usize = 5,
    alpha: f32 = 0.7,
};

/// Tagged union representing any parsed TQL statement.
pub const Statement = union(StatementType) {
    get: GetStatement,
    put: PutStatement,
    delete: DeleteStatement,
    scan: ScanStatement,
    vec_insert: VecInsertStatement,
    vec_search: VecSearchStatement,
    graph_add_node: GraphAddNodeStatement,
    graph_add_edge: GraphAddEdgeStatement,
    graph_shortest_path: GraphShortestPathStatement,
    graph_neighbors: GraphNeighborsStatement,
    hybrid_search: HybridSearchStatement,
    begin: void,
    commit: void,
    rollback: void,

    pub fn deinit(self: *Statement, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .vec_insert => |*v| v.elements.deinit(allocator),
            .vec_search => |*v| v.query.deinit(allocator),
            .hybrid_search => |*h| h.query.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

test "ast statement construction" {
    const allocator = std.testing.allocator;

    var insert = VecInsertStatement{
        .id = types.VectorId.init(42),
        .elements = .empty,
    };
    try insert.elements.append(allocator, 1.0);
    try insert.elements.append(allocator, 2.5);

    var stmt = Statement{ .vec_insert = insert };
    defer stmt.deinit(allocator);

    try std.testing.expectEqual(StatementType.vec_insert, std.meta.activeTag(stmt));
    try std.testing.expectEqual(@as(usize, 2), stmt.vec_insert.elements.items.len);
}
