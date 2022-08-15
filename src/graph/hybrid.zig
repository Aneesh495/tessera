const std = @import("std");
const types = @import("../common/types.zig");
const adjacency = @import("adjacency.zig");
const traversal = @import("traversal.zig");
const hnsw = @import("../vector/hnsw.zig");
const distance = @import("../vector/distance.zig");

pub const HybridMatch = struct {
    node_id: types.NodeId,
    vector_id: types.VectorId,
    composite_score: f32,
    vector_dist: f32,
    graph_hop: usize,

    fn orderAsc(_: void, a: HybridMatch, b: HybridMatch) bool {
        return a.composite_score < b.composite_score;
    }
};

/// Joint Graph-Vector Hybrid Retrieval Engine fusing topological proximity and vector similarity.
pub const HybridRetrievalEngine = struct {
    graph: *const adjacency.GraphStore,
    vector_index: *const hnsw.HnswIndex,
    node_to_vector: std.AutoHashMap(types.NodeId, types.VectorId),
    vector_to_node: std.AutoHashMap(types.VectorId, types.NodeId),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        graph: *const adjacency.GraphStore,
        vector_index: *const hnsw.HnswIndex,
    ) HybridRetrievalEngine {
        return .{
            .graph = graph,
            .vector_index = vector_index,
            .node_to_vector = std.AutoHashMap(types.NodeId, types.VectorId).init(allocator),
            .vector_to_node = std.AutoHashMap(types.VectorId, types.NodeId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HybridRetrievalEngine) void {
        self.node_to_vector.deinit();
        self.vector_to_node.deinit();
        self.* = undefined;
    }

    /// Associate a graph node with a vector embedding.
    pub fn linkNodeVector(self: *HybridRetrievalEngine, node: types.NodeId, vec: types.VectorId) !void {
        try self.node_to_vector.put(node, vec);
        try self.vector_to_node.put(vec, node);
    }

    /// Retrieve nearest neighbors within an N-hop topological neighborhood of a starting seed node.
    pub fn searchNeighborhood(
        self: *const HybridRetrievalEngine,
        allocator: std.mem.Allocator,
        seed: types.NodeId,
        max_hops: usize,
        query: []const f32,
        k: usize,
        alpha: f32, // Weight for vector similarity vs graph distance: [0.0, 1.0]
    ) !std.ArrayList(HybridMatch) {
        // 1. Expand K-hop topological neighborhood
        var reachable_nodes = try traversal.bfsKHop(self.graph, allocator, seed, max_hops);
        defer reachable_nodes.deinit(allocator);

        var matches = std.ArrayList(HybridMatch).empty;
        errdefer matches.deinit(allocator);

        // 2. Score candidate vectors associated with reachable nodes
        for (reachable_nodes.items) |nid| {
            if (self.node_to_vector.get(nid)) |vid| {
                if (self.vector_index.nodes.get(vid)) |vnode| {
                    const vec_d = distance.calculateDistance(self.vector_index.metric, query, vnode.vector);
                    // Approximate hop distance
                    const hop: usize = if (nid == seed) 0 else 1;
                    const hop_penalty = @as(f32, @floatFromInt(hop)) * 0.5;

                    // Composite score: lower is better
                    const score = (alpha * vec_d) + ((1.0 - alpha) * hop_penalty);

                    try matches.append(allocator, .{
                        .node_id = nid,
                        .vector_id = vid,
                        .composite_score = score,
                        .vector_dist = vec_d,
                        .graph_hop = hop,
                    });
                }
            }
        }

        std.mem.sort(HybridMatch, matches.items, {}, HybridMatch.orderAsc);

        while (matches.items.len > k) {
            _ = matches.pop();
        }

        return matches;
    }
};

test "hybrid graph vector retrieval" {
    const allocator = std.testing.allocator;
    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();

    const vidx = try hnsw.HnswIndex.init(allocator, 2, .l2);
    defer vidx.deinit();

    var hybrid = HybridRetrievalEngine.init(allocator, &graph, vidx);
    defer hybrid.deinit();

    const n1 = types.NodeId.init(101);
    const n2 = types.NodeId.init(102);
    const n3 = types.NodeId.init(103);

    const vid1 = types.VectorId.init(1);
    const vid2 = types.VectorId.init(2);
    const vid3 = types.VectorId.init(3);

    _ = try graph.addEdge(n1, n2, 1.0);
    // n3 is disconnected from n1

    const v1 = [_]f32{ 0.0, 0.0 };
    const v2 = [_]f32{ 0.5, 0.5 };
    const v3 = [_]f32{ 0.1, 0.1 }; // Closest to query, but disconnected from n1

    try vidx.insert(vid1, &v1);
    try vidx.insert(vid2, &v2);
    try vidx.insert(vid3, &v3);

    try hybrid.linkNodeVector(n1, vid1);
    try hybrid.linkNodeVector(n2, vid2);
    try hybrid.linkNodeVector(n3, vid3);

    const query = [_]f32{ 0.0, 0.0 };
    // Search within 1-hop of n1
    var results = try hybrid.searchNeighborhood(allocator, n1, 1, &query, 5, 0.7);
    defer results.deinit(allocator);

    // Should only contain n1 and n2 (n3 is unreachable from n1 within 1 hop)
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(n1, results.items[0].node_id);
    try std.testing.expectEqual(n2, results.items[1].node_id);
}
