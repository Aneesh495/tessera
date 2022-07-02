const std = @import("std");
const types = @import("../common/types.zig");
const hnsw = @import("hnsw.zig");
const distance = @import("distance.zig");

/// Priority queue managing candidate vectors during graph traversal.
pub const CandidateQueue = struct {
    items: std.ArrayList(hnsw.Candidate),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CandidateQueue {
        return .{
            .items = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CandidateQueue) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *CandidateQueue, item: hnsw.Candidate) !void {
        try self.items.append(self.allocator, item);
        std.mem.sort(hnsw.Candidate, self.items.items, {}, hnsw.Candidate.orderAsc);
    }

    pub fn popClosest(self: *CandidateQueue) ?hnsw.Candidate {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    pub fn peekFarthest(self: *const CandidateQueue) ?hnsw.Candidate {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1];
    }

    pub fn len(self: *const CandidateQueue) usize {
        return self.items.items.len;
    }
};

/// Brute-force exact K-nearest neighbor search used for baseline validation and 100% recall checks.
pub fn bruteForceKnn(
    allocator: std.mem.Allocator,
    query: []const f32,
    vectors: []const struct { id: types.VectorId, data: []const f32 },
    metric: distance.Metric,
    k: usize,
) !std.ArrayList(hnsw.Candidate) {
    var candidates = std.ArrayList(hnsw.Candidate).empty;
    errdefer candidates.deinit(allocator);

    for (vectors) |item| {
        const d = distance.calculateDistance(metric, query, item.data);
        try candidates.append(allocator, .{ .id = item.id, .dist = d });
    }

    std.mem.sort(hnsw.Candidate, candidates.items, {}, hnsw.Candidate.orderAsc);

    while (candidates.items.len > k) {
        _ = candidates.pop();
    }

    return candidates;
}

/// Compute Recall@K metric comparing approximate results to exact ground truth.
pub fn calculateRecallAtK(approx: []const hnsw.Candidate, ground_truth: []const hnsw.Candidate) f64 {
    if (ground_truth.len == 0 or approx.len == 0) return 0.0;
    var matches: usize = 0;

    for (approx) |a| {
        for (ground_truth) |gt| {
            if (a.id == gt.id) {
                matches += 1;
                break;
            }
        }
    }

    return @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(ground_truth.len));
}

test "ann search priority queue and recall evaluation" {
    const allocator = std.testing.allocator;
    var q = CandidateQueue.init(allocator);
    defer q.deinit();

    try q.push(.{ .id = types.VectorId.init(1), .dist = 5.0 });
    try q.push(.{ .id = types.VectorId.init(2), .dist = 1.0 });
    try q.push(.{ .id = types.VectorId.init(3), .dist = 10.0 });

    const c1 = q.popClosest().?;
    try std.testing.expectEqual(types.VectorId.init(2), c1.id);
    try std.testing.expectEqual(@as(f32, 1.0), c1.dist);

    const f1 = q.peekFarthest().?;
    try std.testing.expectEqual(types.VectorId.init(3), f1.id);

    // Recall calculation verification
    const gt = [_]hnsw.Candidate{
        .{ .id = types.VectorId.init(10), .dist = 1.0 },
        .{ .id = types.VectorId.init(20), .dist = 2.0 },
    };
    const approx = [_]hnsw.Candidate{
        .{ .id = types.VectorId.init(10), .dist = 1.0 },
        .{ .id = types.VectorId.init(30), .dist = 2.5 },
    };
    const recall = calculateRecallAtK(&approx, &gt);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), recall, 1e-6);
}
