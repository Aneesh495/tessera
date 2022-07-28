const std = @import("std");
const types = @import("../common/types.zig");
const adjacency = @import("adjacency.zig");

/// Perform K-hop Breadth-First Search from seed node.
pub fn bfsKHop(
    graph: *const adjacency.GraphStore,
    allocator: std.mem.Allocator,
    start: types.NodeId,
    max_hops: usize,
) !std.ArrayList(types.NodeId) {
    var visited = std.AutoHashMap(types.NodeId, usize).init(allocator);
    defer visited.deinit();

    var queue = std.ArrayList(struct { id: types.NodeId, hop: usize }).empty;
    defer queue.deinit(allocator);

    var result = std.ArrayList(types.NodeId).empty;
    errdefer result.deinit(allocator);

    try visited.put(start, 0);
    try queue.append(allocator, .{ .id = start, .hop = 0 });

    while (queue.items.len > 0) {
        const item = queue.orderedRemove(0);
        try result.append(allocator, item.id);

        if (item.hop < max_hops) {
            if (graph.getOutEdges(item.id)) |edges| {
                for (edges) |edge| {
                    if (!visited.contains(edge.target)) {
                        try visited.put(edge.target, item.hop + 1);
                        try queue.append(allocator, .{ .id = edge.target, .hop = item.hop + 1 });
                    }
                }
            }
        }
    }

    return result;
}

/// Bidirectional BFS searching for shortest hop path between source and target nodes.
pub fn bidirectionalBfs(
    graph: *const adjacency.GraphStore,
    allocator: std.mem.Allocator,
    source: types.NodeId,
    target: types.NodeId,
) !?usize {
    if (source == target) return 0;

    var forward_visited = std.AutoHashMap(types.NodeId, usize).init(allocator);
    defer forward_visited.deinit();
    var backward_visited = std.AutoHashMap(types.NodeId, usize).init(allocator);
    defer backward_visited.deinit();

    var forward_q = std.ArrayList(types.NodeId).empty;
    defer forward_q.deinit(allocator);
    var backward_q = std.ArrayList(types.NodeId).empty;
    defer backward_q.deinit(allocator);

    try forward_visited.put(source, 0);
    try forward_q.append(allocator, source);

    try backward_visited.put(target, 0);
    try backward_q.append(allocator, target);

    while (forward_q.items.len > 0 and backward_q.items.len > 0) {
        // Expand smaller frontier
        if (forward_q.items.len <= backward_q.items.len) {
            const curr = forward_q.orderedRemove(0);
            const dist = forward_visited.get(curr).?;

            if (graph.getOutEdges(curr)) |edges| {
                for (edges) |e| {
                    if (backward_visited.get(e.target)) |back_dist| {
                        return dist + 1 + back_dist;
                    }
                    if (!forward_visited.contains(e.target)) {
                        try forward_visited.put(e.target, dist + 1);
                        try forward_q.append(allocator, e.target);
                    }
                }
            }
        } else {
            const curr = backward_q.orderedRemove(0);
            const dist = backward_visited.get(curr).?;

            if (graph.getInEdges(curr)) |edges| {
                for (edges) |e| {
                    if (forward_visited.get(e.source)) |fwd_dist| {
                        return dist + 1 + fwd_dist;
                    }
                    if (!backward_visited.contains(e.source)) {
                        try backward_visited.put(e.source, dist + 1);
                        try backward_q.append(allocator, e.source);
                    }
                }
            }
        }
    }

    return null; // Not connected
}

test "k-hop bfs traversal" {
    const allocator = std.testing.allocator;
    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();

    const n1 = types.NodeId.init(1);
    const n2 = types.NodeId.init(2);
    const n3 = types.NodeId.init(3);
    const n4 = types.NodeId.init(4);

    _ = try graph.addEdge(n1, n2, 1.0);
    _ = try graph.addEdge(n2, n3, 1.0);
    _ = try graph.addEdge(n3, n4, 1.0);

    // 1-hop from n1 should reach n1 and n2
    var h1 = try bfsKHop(&graph, allocator, n1, 1);
    defer h1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), h1.items.len);

    // 2-hop from n1 should reach n1, n2, n3
    var h2 = try bfsKHop(&graph, allocator, n1, 2);
    defer h2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), h2.items.len);
}

test "bidirectional bfs reachability" {
    const allocator = std.testing.allocator;
    var graph = adjacency.GraphStore.init(allocator);
    defer graph.deinit();

    const n1 = types.NodeId.init(10);
    const n2 = types.NodeId.init(20);
    const n3 = types.NodeId.init(30);

    _ = try graph.addEdge(n1, n2, 1.0);
    _ = try graph.addEdge(n2, n3, 1.0);

    const dist = try bidirectionalBfs(&graph, allocator, n1, n3);
    try std.testing.expect(dist != null);
    try std.testing.expectEqual(@as(usize, 2), dist.?);
}
