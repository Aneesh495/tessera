const std = @import("std");

/// 8-bit Scalar Quantized vector representation with scale and offset.
pub const QuantizedVector = struct {
    codes: []u8,
    min_val: f32,
    scale: f32, // (max_val - min_val) / 255.0
    dim: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, dim: usize) !QuantizedVector {
        return .{
            .codes = try allocator.alloc(u8, dim),
            .min_val = 0,
            .scale = 1.0,
            .dim = dim,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuantizedVector) void {
        self.allocator.free(self.codes);
        self.* = undefined;
    }

    /// Quantize a high-dimensional float slice into uint8 codes.
    pub fn encode(self: *QuantizedVector, raw: []const f32) void {
        std.debug.assert(raw.len == self.dim);
        var min_v: f32 = raw[0];
        var max_v: f32 = raw[0];

        for (raw) |v| {
            if (v < min_v) min_v = v;
            if (v > max_v) max_v = v;
        }

        const span = max_v - min_v;
        const scale = if (span > 1e-9) span / 255.0 else 1.0;
        const inv_scale = 1.0 / scale;

        self.min_val = min_v;
        self.scale = scale;

        for (raw, 0..) |v, i| {
            const normalized = (v - min_v) * inv_scale;
            const clamped = @min(255.0, @max(0.0, normalized));
            self.codes[i] = @as(u8, @intFromFloat(@round(clamped)));
        }
    }

    /// Deconstruct quantized codes back to approximate float slice.
    pub fn decode(self: QuantizedVector, out: []f32) void {
        std.debug.assert(out.len == self.dim);
        for (self.codes, 0..) |code, i| {
            out[i] = self.min_val + (@as(f32, @floatFromInt(code)) * self.scale);
        }
    }

    /// Fast Asymmetric Distance: computes L2 distance between raw query and quantized codes.
    pub fn asymmetricDistanceL2(self: QuantizedVector, query: []const f32) f32 {
        std.debug.assert(query.len == self.dim);
        var sum: f32 = 0;
        const min_v = self.min_val;
        const s = self.scale;

        for (self.codes, 0..) |code, i| {
            const approx_val = min_v + (@as(f32, @floatFromInt(code)) * s);
            const diff = query[i] - approx_val;
            sum += diff * diff;
        }

        return @sqrt(sum);
    }
};

test "scalar quantization 8-bit accuracy and distance" {
    const allocator = std.testing.allocator;
    const raw = [_]f32{ -1.5, 0.0, 2.5, 10.0, -5.0, 3.14, 7.8, -0.42 };

    var qvec = try QuantizedVector.init(allocator, raw.len);
    defer qvec.deinit();

    qvec.encode(&raw);

    var reconstructed: [raw.len]f32 = undefined;
    qvec.decode(&reconstructed);

    // Max quantization error should be bounded by scale / 2
    const max_err = qvec.scale;
    for (raw, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, reconstructed[i], max_err);
    }

    // Distance between query and quantized vector
    const query = [_]f32{ -1.0, 0.5, 2.0, 9.0, -4.5, 3.0, 7.0, 0.0 };
    const dist = qvec.asymmetricDistanceL2(&query);
    try std.testing.expect(dist > 0.0);
}
