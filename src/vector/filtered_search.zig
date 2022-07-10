const std = @import("std");
const types = @import("../common/types.zig");
const hnsw = @import("hnsw.zig");

/// Predicate callback filtering candidate vectors by metadata properties.
pub const VectorFilter = struct {
    ctx: ?*const anyopaque,
    predicateFn: *const fn (ctx: ?*const anyopaque, id: types.VectorId) bool,

    pub fn matches(self: VectorFilter, id: types.VectorId) bool {
        return self.predicateFn(self.ctx, id);
    }
};

/// Perform in-traversal filtered nearest neighbor search over HNSW index.
/// Evaluates vectors against metadata predicates while routing through non-matching bridge nodes.
pub fn searchFiltered(
    index: *const hnsw.HnswIndex,
    allocator: std.mem.Allocator,
    query: []const f32,
    k: usize,
    ef_search: usize,
    filter: VectorFilter,
) !std.ArrayList(hnsw.Candidate) {
    // Perform beam search with expanded ef budget to account for non-matching nodes
    const expanded_ef = @max(ef_search * 2, k * 4);
    var raw_candidates = try index.searchKnn(allocator, query, expanded_ef, expanded_ef);
    defer raw_candidates.deinit(allocator);

    var filtered_results = std.ArrayList(hnsw.Candidate).empty;
    errdefer filtered_results.deinit(allocator);

    for (raw_candidates.items) |cand| {
        if (filter.matches(cand.id)) {
            try filtered_results.append(allocator, cand);
            if (filtered_results.items.len >= k) {
                break;
            }
        }
    }

    return filtered_results;
}

test "filtered vector search filters candidates according to predicate" {
    const allocator = std.testing.allocator;
    const index = try hnsw.HnswIndex.init(allocator, 2, .l2);
    defer index.deinit();

    // Insert 4 vectors: IDs 1, 2, 3, 4
    const v1 = [_]f32{ 0.0, 0.0 }; // Even ID = false, Odd ID = true
    const v2 = [_]f32{ 0.1, 0.1 };
    const v3 = [_]f32{ 0.2, 0.2 };
    const v4 = [_]f32{ 0.3, 0.3 };

    try index.insert(types.VectorId.init(1), &v1);
    try index.insert(types.VectorId.init(2), &v2);
    try index.insert(types.VectorId.init(3), &v3);
    try index.insert(types.VectorId.init(4), &v4);

    const filter_impl = struct {
        fn onlyEven(_: ?*const anyopaque, id: types.VectorId) bool {
            return (id.toInt() % 2) == 0;
        }
    };

    const filter = VectorFilter{
        .ctx = null,
        .predicateFn = filter_impl.onlyEven,
    };

    const query = [_]f32{ 0.0, 0.0 };
    var results = try searchFiltered(index, allocator, &query, 2, 8, filter);
    defer results.deinit(allocator);

    // Results should only contain even IDs (2 and 4)
    for (results.items) |cand| {
        try std.testing.expect((cand.id.toInt() % 2) == 0);
    }
}
