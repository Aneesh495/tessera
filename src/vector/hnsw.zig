const std = @import("std");
const types = @import("../common/types.zig");
const distance = @import("distance.zig");

pub const DEFAULT_M: usize = 16;
pub const DEFAULT_M0: usize = 32;
pub const DEFAULT_EF_CONSTRUCTION: usize = 64;
pub const DEFAULT_EF_SEARCH: usize = 32;

/// Candidate pair holding vector ID and distance to query.
pub const Candidate = struct {
    id: types.VectorId,
    dist: f32,

    pub fn orderAsc(_: void, a: Candidate, b: Candidate) bool {
        return a.dist < b.dist;
    }

    pub fn orderDesc(_: void, a: Candidate, b: Candidate) bool {
        return a.dist > b.dist;
    }
};

/// Node in the HNSW multi-layer proximity graph.
pub const HnswNode = struct {
    id: types.VectorId,
    level: usize,
    vector: []f32,
    // Neighbor lists for levels 0..level
    neighbors: []std.ArrayList(types.VectorId),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: types.VectorId, vec: []const f32, level: usize) !*HnswNode {
        const node = try allocator.create(HnswNode);
        const cloned_vec = try allocator.dupe(f32, vec);
        const neigh_lists = try allocator.alloc(std.ArrayList(types.VectorId), level + 1);

        for (neigh_lists) |*list| {
            list.* = .empty;
        }

        node.* = .{
            .id = id,
            .level = level,
            .vector = cloned_vec,
            .neighbors = neigh_lists,
            .allocator = allocator,
        };
        return node;
    }

    pub fn deinit(self: *HnswNode) void {
        for (self.neighbors) |*list| {
            list.deinit(self.allocator);
        }
        self.allocator.free(self.neighbors);
        self.allocator.free(self.vector);
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

/// High-performance Hierarchical Navigable Small World (HNSW) vector index.
pub const HnswIndex = struct {
    allocator: std.mem.Allocator,
    dim: usize,
    metric: distance.Metric,
    m: usize,
    m0: usize,
    ef_construction: usize,
    ml: f64,
    nodes: std.AutoHashMap(types.VectorId, *HnswNode),
    enter_node: ?types.VectorId,
    max_level: usize,
    rng_state: u64,
    mutex: types.SpinLock,

    pub fn init(allocator: std.mem.Allocator, dim: usize, metric: distance.Metric) !*HnswIndex {
        const idx = try allocator.create(HnswIndex);
        const m = DEFAULT_M;
        idx.* = .{
            .allocator = allocator,
            .dim = dim,
            .metric = metric,
            .m = m,
            .m0 = DEFAULT_M0,
            .ef_construction = DEFAULT_EF_CONSTRUCTION,
            .ml = 1.0 / @log(@as(f64, @floatFromInt(m))),
            .nodes = std.AutoHashMap(types.VectorId, *HnswNode).init(allocator),
            .enter_node = null,
            .max_level = 0,
            .rng_state = 0x853c49e6748fea9b,
            .mutex = types.SpinLock.init(),
        };
        return idx;
    }

    pub fn deinit(self: *HnswIndex) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            node.*.deinit();
        }
        self.nodes.deinit();
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    pub fn count(self: *HnswIndex) usize {
        return self.nodes.count();
    }

    fn dist(self: *const HnswIndex, a: []const f32, b: []const f32) f32 {
        return distance.calculateDistance(self.metric, a, b);
    }

    fn randomLevel(self: *HnswIndex) usize {
        var x = self.rng_state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng_state = x;

        const uniform = @as(f64, @floatFromInt((x & 0xFFFFFFFF) + 1)) / 4294967296.0;
        const raw_level = -@log(uniform) * self.ml;
        return @as(usize, @intFromFloat(@min(raw_level, 16.0)));
    }

    /// Search a single layer for nearest neighbors using beam search.
    pub fn searchLayer(
        self: *const HnswIndex,
        allocator: std.mem.Allocator,
        query: []const f32,
        entry_points: []const types.VectorId,
        ef: usize,
        level: usize,
    ) !std.ArrayList(Candidate) {
        var visited = std.AutoHashMap(types.VectorId, void).init(allocator);
        defer visited.deinit();

        var candidates = std.ArrayList(Candidate).empty; // Min-heap order (closest first)
        var w_results = std.ArrayList(Candidate).empty; // Max-heap order (farthest first)
        errdefer candidates.deinit(allocator);
        errdefer w_results.deinit(allocator);

        for (entry_points) |ep_id| {
            if (self.nodes.get(ep_id)) |ep_node| {
                const d = self.dist(query, ep_node.vector);
                try visited.put(ep_id, {});
                try candidates.append(allocator, .{ .id = ep_id, .dist = d });
                try w_results.append(allocator, .{ .id = ep_id, .dist = d });
            }
        }

        std.mem.sort(Candidate, candidates.items, {}, Candidate.orderAsc);
        std.mem.sort(Candidate, w_results.items, {}, Candidate.orderAsc);

        while (candidates.items.len > 0) {
            // Pop closest candidate
            const current = candidates.orderedRemove(0);
            const farthest_result = w_results.items[w_results.items.len - 1];

            if (current.dist > farthest_result.dist and w_results.items.len >= ef) {
                break;
            }

            if (self.nodes.get(current.id)) |curr_node| {
                if (level < curr_node.neighbors.len) {
                    for (curr_node.neighbors[level].items) |neighbor_id| {
                        if (!visited.contains(neighbor_id)) {
                            try visited.put(neighbor_id, {});
                            if (self.nodes.get(neighbor_id)) |neigh_node| {
                                const d = self.dist(query, neigh_node.vector);
                                const cur_farthest = w_results.items[w_results.items.len - 1];

                                if (d < cur_farthest.dist or w_results.items.len < ef) {
                                    try candidates.append(allocator, .{ .id = neighbor_id, .dist = d });
                                    std.mem.sort(Candidate, candidates.items, {}, Candidate.orderAsc);

                                    try w_results.append(allocator, .{ .id = neighbor_id, .dist = d });
                                    std.mem.sort(Candidate, w_results.items, {}, Candidate.orderAsc);

                                    if (w_results.items.len > ef) {
                                        _ = w_results.pop();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        candidates.deinit(allocator);
        return w_results;
    }

    /// Heuristic neighbor selection promoting directional diversity.
    fn selectNeighborsHeuristic(
        self: *const HnswIndex,
        allocator: std.mem.Allocator,
        candidates: []const Candidate,
        max_edges: usize,
    ) !std.ArrayList(types.VectorId) {
        var result = std.ArrayList(types.VectorId).empty;
        errdefer result.deinit(allocator);

        for (candidates) |cand| {
            if (result.items.len >= max_edges) break;
            const cand_node = self.nodes.get(cand.id) orelse continue;

            var is_closer_to_existing = false;
            for (result.items) |selected_id| {
                const sel_node = self.nodes.get(selected_id) orelse continue;
                const dist_between = self.dist(cand_node.vector, sel_node.vector);
                if (dist_between < cand.dist) {
                    is_closer_to_existing = true;
                    break;
                }
            }

            if (!is_closer_to_existing) {
                try result.append(allocator, cand.id);
            }
        }

        return result;
    }

    /// Insert a vector into the HNSW graph.
    pub fn insert(self: *HnswIndex, id: types.VectorId, vec: []const f32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(vec.len == self.dim);

        // First node becomes initial entry point
        if (self.enter_node == null) {
            const node = try HnswNode.init(self.allocator, id, vec, 0);
            try self.nodes.put(id, node);
            self.enter_node = id;
            self.max_level = 0;
            return;
        }

        const level = self.randomLevel();
        const new_node = try HnswNode.init(self.allocator, id, vec, level);
        try self.nodes.put(id, new_node);

        var ep = self.enter_node.?;
        var curr_level = self.max_level;

        // Step 1: Greedy routing from top level down to level + 1
        while (curr_level > level) {
            var changed = true;
            while (changed) {
                changed = false;
                const ep_node = self.nodes.get(ep).?;
                var min_dist = self.dist(vec, ep_node.vector);

                if (curr_level < ep_node.neighbors.len) {
                    for (ep_node.neighbors[curr_level].items) |neigh_id| {
                        if (self.nodes.get(neigh_id)) |neigh_node| {
                            const d = self.dist(vec, neigh_node.vector);
                            if (d < min_dist) {
                                min_dist = d;
                                ep = neigh_id;
                                changed = true;
                            }
                        }
                    }
                }
            }
            if (curr_level == 0) break;
            curr_level -= 1;
        }

        // Step 2: Establish bidirectional connections from level down to 0
        var ep_slice = [_]types.VectorId{ep};
        var l = @min(curr_level, level);
        while (true) {
            var layer_candidates = try self.searchLayer(self.allocator, vec, &ep_slice, self.ef_construction, l);
            defer layer_candidates.deinit(self.allocator);

            const max_m = if (l == 0) self.m0 else self.m;
            var chosen_neighbors = try self.selectNeighborsHeuristic(self.allocator, layer_candidates.items, max_m);
            defer chosen_neighbors.deinit(self.allocator);

            // Connect new_node to chosen neighbors
            for (chosen_neighbors.items) |neigh_id| {
                try new_node.neighbors[l].append(self.allocator, neigh_id);

                // Add reverse edge
                if (self.nodes.get(neigh_id)) |neigh_node| {
                    if (l < neigh_node.neighbors.len) {
                        try neigh_node.neighbors[l].append(self.allocator, id);
                        // Prune excess edges if over capacity
                        if (neigh_node.neighbors[l].items.len > max_m) {
                            _ = neigh_node.neighbors[l].pop();
                        }
                    }
                }
            }

            if (layer_candidates.items.len > 0) {
                ep_slice[0] = layer_candidates.items[0].id;
            }

            if (l == 0) break;
            l -= 1;
        }

        if (level > self.max_level) {
            self.max_level = level;
            self.enter_node = id;
        }
    }

    /// Search K Approximate Nearest Neighbors for query vector.
    pub fn searchKnn(
        self: *const HnswIndex,
        allocator: std.mem.Allocator,
        query: []const f32,
        k: usize,
        ef_search: usize,
    ) !std.ArrayList(Candidate) {
        if (self.enter_node == null) return std.ArrayList(Candidate).empty;

        var ep = self.enter_node.?;
        var curr_level = self.max_level;

        // Greedy routing on upper levels
        while (curr_level > 0) {
            var changed = true;
            while (changed) {
                changed = false;
                const ep_node = self.nodes.get(ep).?;
                var min_dist = self.dist(query, ep_node.vector);

                if (curr_level < ep_node.neighbors.len) {
                    for (ep_node.neighbors[curr_level].items) |neigh_id| {
                        if (self.nodes.get(neigh_id)) |neigh_node| {
                            const d = self.dist(query, neigh_node.vector);
                            if (d < min_dist) {
                                min_dist = d;
                                ep = neigh_id;
                                changed = true;
                            }
                        }
                    }
                }
            }
            curr_level -= 1;
        }

        // Beam search on layer 0
        const ef = @max(k, ef_search);
        const ep_slice = [_]types.VectorId{ep};
        var layer0_results = try self.searchLayer(allocator, query, &ep_slice, ef, 0);

        // Trim to top K
        while (layer0_results.items.len > k) {
            _ = layer0_results.pop();
        }

        return layer0_results;
    }
};

test "hnsw indexing and knn recall accuracy" {
    const allocator = std.testing.allocator;
    const index = try HnswIndex.init(allocator, 4, .l2);
    defer index.deinit();

    // Insert 10 synthetic 4D vectors
    const v1 = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    const v2 = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const v3 = [_]f32{ 2.0, 2.0, 2.0, 2.0 };
    const v4 = [_]f32{ 10.0, 10.0, 10.0, 10.0 };

    try index.insert(types.VectorId.init(1), &v1);
    try index.insert(types.VectorId.init(2), &v2);
    try index.insert(types.VectorId.init(3), &v3);
    try index.insert(types.VectorId.init(4), &v4);

    // Query close to v1
    const query = [_]f32{ 0.1, 0.1, 0.0, 0.0 };
    var results = try index.searchKnn(allocator, &query, 2, 16);
    defer results.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    // Closest match should be v1
    try std.testing.expectEqual(types.VectorId.init(1), results.items[0].id);
    // Second closest match should be v2
    try std.testing.expectEqual(types.VectorId.init(2), results.items[1].id);
}
