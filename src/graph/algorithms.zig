const std = @import("std");
const types = @import("../common/types.zig");
const adjacency = @import("adjacency.zig");

pub const ShortestPathResult = struct {
    distance: f32,
    path: std.ArrayList(types.NodeId),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ShortestPathResult) void {
        self.path.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Dijkstra single-source shortest path algorithm using a min-heap priority queue.
pub fn dijkstraShortestPath(
    graph: *const adjacency.GraphStore,
    allocator: std.mem.Allocator,
    source: types.NodeId,
    target: types.NodeId,
) !?ShortestPathResult {
    const Element = struct {
        id: types.NodeId,
        cost: f32,

        fn orderAsc(_: void, a: @This(), b: @This()) bool {
            return a.cost < b.cost;
        }
    };

    var distances = std.AutoHashMap(types.NodeId, f32).init(allocator);
    defer distances.deinit();

    var predecessors = std.AutoHashMap(types.NodeId, types.NodeId).init(allocator);
    defer predecessors.deinit();

    var pq = std.ArrayList(Element).empty;
    defer pq.deinit(allocator);

    try distances.put(source, 0.0);
    try pq.append(allocator, .{ .id = source, .cost = 0.0 });

    while (pq.items.len > 0) {
        std.mem.sort(Element, pq.items, {}, Element.orderAsc);
        const curr = pq.orderedRemove(0);

        if (curr.id == target) {
            // Reconstruct path backwards from target to source
            var path = std.ArrayList(types.NodeId).empty;
            errdefer path.deinit(allocator);

            var step = target;
            try path.append(allocator, step);
            while (step != source) {
                step = predecessors.get(step).?;
                try path.append(allocator, step);
            }

            // Reverse path to source -> target
            var i: usize = 0;
            const mid = path.items.len / 2;
            while (i < mid) : (i += 1) {
                const tmp = path.items[i];
                path.items[i] = path.items[path.items.len - 1 - i];
                path.items[path.items.len - 1 - i] = tmp;
            }

            return ShortestPathResult{
                .distance = curr.cost,
                .path = path,
                .allocator = allocator,
            };
        }

        const current_dist = distances.get(curr.id) orelse std.math.inf(f32);
        if (curr.cost > current_dist) continue;

        if (graph.getOutEdges(curr.id)) |edges| {
            for (edges) |edge| {
                const new_cost = curr.cost + edge.weight;
                const existing_cost = distances.get(edge.target) orelse std.math.inf(f32);

                if (new_cost < existing_cost) {
                    try distances.put(edge.target, new_cost);
                    try predecessors.put(edge.target, curr.id);
                    try pq.append(allocator, .{ .id = edge.target, .cost = new_cost });
                }
            }
        }
    }

    return null; // Target unreachable
}

/// Personalized PageRank (PPR) using power iteration with random restarts from seed node.
pub fn personalizedPageRank(
    graph: *const adjacency.GraphStore,
    allocator: std.mem.Allocator,
    seed: types.NodeId,
    damping_factor: f32, // e.g. 0.85
    iterations: usize,
) !std.AutoHashMap(types.NodeId, f32) {
    var ranks = std.AutoHashMap(types.NodeId, f32).init(allocator);
    errdefer ranks.deinit();

    // Collect all nodes
    var nodes = std.ArrayList(types.NodeId).empty;
    defer nodes.deinit(allocator);

    var it = graph.out_edges.keyIterator();
    while (it.next()) |node_id| {
        try nodes.append(allocator, node_id.*);
        try ranks.put(node_id.*, if (node_id.* == seed) 1.0 else 0.0);
    }

    if (nodes.items.len == 0) return ranks;

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        var new_ranks = std.AutoHashMap(types.NodeId, f32).init(allocator);
        defer new_ranks.deinit();

        for (nodes.items) |nid| {
            try new_ranks.put(nid, 0.0);
        }

        // Distribute ranks across outbound edges
        for (nodes.items) |u| {
            const r_u = ranks.get(u).?;
            if (graph.getOutEdges(u)) |edges| {
                if (edges.len > 0) {
                    const share = (r_u * damping_factor) / @as(f32, @floatFromInt(edges.len));
                    for (edges) |e| {
                        const cur = new_ranks.get(e.target) orelse 0.0;
                        try new_ranks.put(e.target, cur + share);
                    }
                } else {
                    // Dangling node: reset to seed
                    const cur = new_ranks.get(seed) orelse 0.0;
                    try new_ranks.put(seed, cur + (r_u * damping_factor));
                }
            }
        }

        // Add random restart teleportation probability to seed
        const teleport = 1.0 - damping_factor;
        const cur_seed = new_ranks.get(seed) orelse 0.0;
        try new_ranks.put(seed, cur_seed + teleport);

        // Update ranks map
        for (nodes.items) |nid| {
            try ranks.put(nid, new_ranks.get(nid).?);
        }
    }

    return ranks;
}

test "dijkstra shortest path computation" {
    const allocator = std.testing.allocator;
    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();

    const n1 = types.NodeId.init(1);
    const n2 = types.NodeId.init(2);
    const n3 = types.NodeId.init(3);
    const n4 = types.NodeId.init(4);

    _ = try graph.addEdge(n1, n2, 1.0);
    _ = try graph.addEdge(n2, n4, 5.0);
    _ = try graph.addEdge(n1, n3, 2.0);
    _ = try graph.addEdge(n3, n4, 1.0); // Route n1 -> n3 -> n4 costs 3.0 (faster than n1 -> n2 -> n4 which costs 6.0)

    var res = (try dijkstraShortestPath(&graph, allocator, n1, n4)).?;
    defer res.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 3.0), res.distance, 1e-5);
    try std.testing.expectEqual(@as(usize, 3), res.path.items.len);
    try std.testing.expectEqual(n1, res.path.items[0]);
    try std.testing.expectEqual(n3, res.path.items[1]);
    try std.testing.expectEqual(n4, res.path.items[2]);
}

test "personalized pagerank convergence" {
    const allocator = std.testing.allocator;
    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();

    const n1 = types.NodeId.init(1);
    const n2 = types.NodeId.init(2);
    const n3 = types.NodeId.init(3);

    _ = try graph.addEdge(n1, n2, 1.0);
    _ = try graph.addEdge(n2, n3, 1.0);
    _ = try graph.addEdge(n3, n1, 1.0);

    var ranks = try personalizedPageRank(&graph, allocator, n1, 0.85, 20);
    defer ranks.deinit();

    // Seed node n1 should have significant rank
    const r1 = ranks.get(n1).?;
    const r2 = ranks.get(n2).?;
    try std.testing.expect(r1 > 0.0);
    try std.testing.expect(r2 > 0.0);
}
