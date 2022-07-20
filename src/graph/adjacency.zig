const std = @import("std");
const types = @import("../common/types.zig");

/// Directed edge representation with weight and properties.
pub const Edge = struct {
    id: types.EdgeId,
    source: types.NodeId,
    target: types.NodeId,
    weight: f32,
    property: []const u8 = "",

    pub fn init(id: types.EdgeId, source: types.NodeId, target: types.NodeId, weight: f32) Edge {
        return .{
            .id = id,
            .source = source,
            .target = target,
            .weight = weight,
            .property = "",
        };
    }
};

/// Compressed Sparse Row (CSR) static graph representation for cache-line friendly traversals.
pub const CsrMatrix = struct {
    row_offsets: []u32,
    col_targets: []types.NodeId,
    weights: []f32,
    num_nodes: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CsrMatrix) void {
        self.allocator.free(self.row_offsets);
        self.allocator.free(self.col_targets);
        self.allocator.free(self.weights);
        self.* = undefined;
    }

    /// Return slice of outgoing neighbor nodes for a given node index.
    pub fn getNeighbors(self: CsrMatrix, node_idx: usize) []const types.NodeId {
        if (node_idx >= self.num_nodes) return &.{};
        const start = self.row_offsets[node_idx];
        const end = self.row_offsets[node_idx + 1];
        return self.col_targets[start..end];
    }

    /// Return slice of edge weights for outgoing neighbors.
    pub fn getWeights(self: CsrMatrix, node_idx: usize) []const f32 {
        if (node_idx >= self.num_nodes) return &.{};
        const start = self.row_offsets[node_idx];
        const end = self.row_offsets[node_idx + 1];
        return self.weights[start..end];
    }
};

/// Dynamic in-memory graph store maintaining bidirectional adjacency lists.
pub const GraphStore = struct {
    allocator: std.mem.Allocator,
    // Adjacency maps: NodeId -> list of outgoing edges
    out_edges: std.AutoHashMap(types.NodeId, std.ArrayList(Edge)),
    // Inbound adjacency maps: NodeId -> list of incoming edges
    in_edges: std.AutoHashMap(types.NodeId, std.ArrayList(Edge)),
    // Node property catalog: NodeId -> JSON/string payload
    node_properties: std.AutoHashMap(types.NodeId, []const u8),
    next_edge_id: u64,
    mutex: types.SpinLock,

    pub fn init(allocator: std.mem.Allocator) GraphStore {
        return .{
            .allocator = allocator,
            .out_edges = std.AutoHashMap(types.NodeId, std.ArrayList(Edge)).init(allocator),
            .in_edges = std.AutoHashMap(types.NodeId, std.ArrayList(Edge)).init(allocator),
            .node_properties = std.AutoHashMap(types.NodeId, []const u8).init(allocator),
            .next_edge_id = 1,
            .mutex = types.SpinLock.init(),
        };
    }

    pub fn deinit(self: *GraphStore) void {
        var out_it = self.out_edges.valueIterator();
        while (out_it.next()) |list| {
            for (list.items) |edge| {
                if (edge.property.len > 0) self.allocator.free(edge.property);
            }
            list.deinit(self.allocator);
        }
        self.out_edges.deinit();

        var in_it = self.in_edges.valueIterator();
        while (in_it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.in_edges.deinit();

        var prop_it = self.node_properties.valueIterator();
        while (prop_it.next()) |prop| {
            if (prop.*.len > 0) self.allocator.free(prop.*);
        }
        self.node_properties.deinit();
    }

    /// Register a new node or update node properties.
    pub fn addNode(self: *GraphStore, id: types.NodeId, property: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.out_edges.contains(id)) {
            try self.out_edges.put(id, .empty);
            try self.in_edges.put(id, .empty);
        }

        if (property.len > 0) {
            const prop_copy = try self.allocator.dupe(u8, property);
            if (try self.node_properties.fetchPut(id, prop_copy)) |old| {
                self.allocator.free(old.value);
            }
        }
    }

    /// Add a directed edge between source and target nodes with a weight.
    pub fn addEdge(self: *GraphStore, source: types.NodeId, target: types.NodeId, weight: f32) !types.EdgeId {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Ensure nodes exist
        if (!self.out_edges.contains(source)) {
            try self.out_edges.put(source, .empty);
            try self.in_edges.put(source, .empty);
        }
        if (!self.out_edges.contains(target)) {
            try self.out_edges.put(target, .empty);
            try self.in_edges.put(target, .empty);
        }

        const edge_id = types.EdgeId.init(self.next_edge_id);
        self.next_edge_id += 1;

        const edge = Edge.init(edge_id, source, target, weight);

        var out_list = self.out_edges.getPtr(source).?;
        try out_list.append(self.allocator, edge);

        var in_list = self.in_edges.getPtr(target).?;
        try in_list.append(self.allocator, edge);

        return edge_id;
    }

    /// Get outbound edges from a node.
    pub fn getOutEdges(self: *const GraphStore, id: types.NodeId) ?[]const Edge {
        if (self.out_edges.get(id)) |list| {
            return list.items;
        }
        return null;
    }

    /// Get inbound edges to a node.
    pub fn getInEdges(self: *const GraphStore, id: types.NodeId) ?[]const Edge {
        if (self.in_edges.get(id)) |list| {
            return list.items;
        }
        return null;
    }

    /// Count total nodes in graph.
    pub fn nodeCount(self: *const GraphStore) usize {
        return self.out_edges.count();
    }

    /// Snapshot dynamic adjacency lists into contiguous CSR arrays.
    pub fn buildCsr(self: *const GraphStore, allocator: std.mem.Allocator) !CsrMatrix {
        const n = self.out_edges.count();
        var row_offsets = try allocator.alloc(u32, n + 1);
        errdefer allocator.free(row_offsets);

        var total_edges: usize = 0;
        var out_it = self.out_edges.valueIterator();
        while (out_it.next()) |list| {
            total_edges += list.items.len;
        }

        var col_targets = try allocator.alloc(types.NodeId, total_edges);
        errdefer allocator.free(col_targets);
        var weights = try allocator.alloc(f32, total_edges);
        errdefer allocator.free(weights);

        var offset: u32 = 0;
        var idx: usize = 0;

        var key_it = self.out_edges.keyIterator();
        while (key_it.next()) |node_id| {
            row_offsets[idx] = offset;
            idx += 1;

            const edges = self.out_edges.get(node_id.*).?.items;
            for (edges) |e| {
                col_targets[offset] = e.target;
                weights[offset] = e.weight;
                offset += 1;
            }
        }
        row_offsets[n] = offset;

        return .{
            .row_offsets = row_offsets,
            .col_targets = col_targets,
            .weights = weights,
            .num_nodes = n,
            .allocator = allocator,
        };
    }
};

test "graph store insertion and csr snapshot" {
    const allocator = std.testing.allocator;
    var store = GraphStore.init(allocator);
    defer store.deinit();

    const n1 = types.NodeId.init(1);
    const n2 = types.NodeId.init(2);
    const n3 = types.NodeId.init(3);

    try store.addNode(n1, "{\"label\":\"user\"}");
    try store.addNode(n2, "{\"label\":\"post\"}");
    try store.addNode(n3, "{\"label\":\"comment\"}");

    _ = try store.addEdge(n1, n2, 1.0);
    _ = try store.addEdge(n1, n3, 2.5);
    _ = try store.addEdge(n2, n3, 0.5);

    try std.testing.expectEqual(@as(usize, 3), store.nodeCount());

    const out1 = store.getOutEdges(n1).?;
    try std.testing.expectEqual(@as(usize, 2), out1.len);
    try std.testing.expectEqual(n2, out1[0].target);
    try std.testing.expectEqual(n3, out1[1].target);

    // Build and verify CSR
    var csr = try store.buildCsr(allocator);
    defer csr.deinit();

    try std.testing.expectEqual(@as(usize, 3), csr.num_nodes);
    try std.testing.expectEqual(@as(usize, 3), csr.col_targets.len);
}
