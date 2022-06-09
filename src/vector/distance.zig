const std = @import("std");

pub const Metric = enum(u8) {
    l2 = 1,
    cosine = 2,
    dot_product = 3,
    manhattan = 4,
};

pub const SIMD_WIDTH: usize = 8;
const Vec8f = @Vector(SIMD_WIDTH, f32);

/// Compute Squared Euclidean Distance (L2) using SIMD instructions.
pub fn euclideanDistanceSq(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var sum: f32 = 0;
    var i: usize = 0;

    // Vectorized SIMD loop
    const simd_len = a.len - (a.len % SIMD_WIDTH);
    while (i < simd_len) : (i += SIMD_WIDTH) {
        const va: Vec8f = a[i..][0..SIMD_WIDTH].*;
        const vb: Vec8f = b[i..][0..SIMD_WIDTH].*;
        const diff = va - vb;
        const diff_sq = diff * diff;
        sum += @reduce(.Add, diff_sq);
    }

    // Scalar tail loop
    while (i < a.len) : (i += 1) {
        const d = a[i] - b[i];
        sum += d * d;
    }

    return sum;
}

/// Compute Euclidean Distance (L2).
pub fn euclideanDistance(a: []const f32, b: []const f32) f32 {
    return @sqrt(euclideanDistanceSq(a, b));
}

/// Compute Dot Product between two vectors using SIMD instructions.
pub fn dotProduct(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var sum: f32 = 0;
    var i: usize = 0;

    const simd_len = a.len - (a.len % SIMD_WIDTH);
    while (i < simd_len) : (i += SIMD_WIDTH) {
        const va: Vec8f = a[i..][0..SIMD_WIDTH].*;
        const vb: Vec8f = b[i..][0..SIMD_WIDTH].*;
        const prod = va * vb;
        sum += @reduce(.Add, prod);
    }

    while (i < a.len) : (i += 1) {
        sum += a[i] * b[i];
    }

    return sum;
}

/// Compute vector L2 norm (magnitude).
pub fn norm(a: []const f32) f32 {
    return @sqrt(dotProduct(a, a));
}

/// Compute Cosine Distance (1.0 - Cosine Similarity). Range: [0.0, 2.0].
pub fn cosineDistance(a: []const f32, b: []const f32) f32 {
    const dot = dotProduct(a, b);
    const norm_a = norm(a);
    const norm_b = norm(b);

    const denom = norm_a * norm_b;
    if (denom < 1e-12) return 1.0;

    const similarity = dot / denom;
    // Clamp to [-1.0, 1.0] to guard against floating-point inaccuracy
    const clamped = @min(1.0, @max(-1.0, similarity));
    return 1.0 - clamped;
}

/// Compute Manhattan Distance (L1) using SIMD absolute differences.
pub fn manhattanDistance(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var sum: f32 = 0;
    var i: usize = 0;

    const simd_len = a.len - (a.len % SIMD_WIDTH);
    while (i < simd_len) : (i += SIMD_WIDTH) {
        const va: Vec8f = a[i..][0..SIMD_WIDTH].*;
        const vb: Vec8f = b[i..][0..SIMD_WIDTH].*;
        const diff = va - vb;
        const abs_diff = @abs(diff);
        sum += @reduce(.Add, abs_diff);
    }

    while (i < a.len) : (i += 1) {
        sum += @abs(a[i] - b[i]);
    }

    return sum;
}

/// Generic distance dispatcher by Metric tag.
pub fn calculateDistance(metric: Metric, a: []const f32, b: []const f32) f32 {
    switch (metric) {
        .l2 => return euclideanDistance(a, b),
        .cosine => return cosineDistance(a, b),
        .dot_product => return -dotProduct(a, b), // Inverted for min-heap sorting
        .manhattan => return manhattanDistance(a, b),
    }
}

test "simd euclidean distance" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };

    // Identical vectors: distance should be 0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), euclideanDistance(&a, &b), 1e-5);

    const c = [_]f32{ 4.0, 6.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };
    // Diff is (3^2 + 4^2) = 25 -> sqrt is 5.0
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), euclideanDistance(&a, &c), 1e-5);
}

test "simd cosine distance" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const c = [_]f32{ 2.0, 0.0, 0.0 };

    // Orthogonal: cosine distance is 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cosineDistance(&a, &b), 1e-5);

    // Parallel (collinear): cosine distance is 0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cosineDistance(&a, &c), 1e-5);
}

test "simd manhattan distance" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0 };
    const b = [_]f32{ 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0 };
    // Diff is 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 = 45.0
    try std.testing.expectApproxEqAbs(@as(f32, 45.0), manhattanDistance(&a, &b), 1e-5);
}
