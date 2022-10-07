const std = @import("std");

/// High-performance deterministic pseudo-random number generator based on xoshiro256**.
/// Provides forkable random streams and uniform distributions for simulation testing.
pub const SimRng = struct {
    s: [4]u64,

    /// Initialize xoshiro256** state from a 64-bit seed using SplitMix64.
    pub fn init(seed: u64) SimRng {
        var sm = seed;
        var s: [4]u64 = undefined;
        for (0..4) |i| {
            s[i] = splitmix64(&sm);
        }
        return .{ .s = s };
    }


    fn splitmix64(x: *u64) u64 {
        x.* +%= 0x9e3779b97f4a7c15;
        var z = x.*;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    /// Generate next 64-bit pseudo-random integer.
    pub fn nextU64(self: *SimRng) u64 {
        const result = std.math.rotl(u64, self.s[1] *% 5, 7) *% 9;
        const t = self.s[1] << 17;

        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];

        self.s[2] ^= t;
        self.s[3] = std.math.rotl(u64, self.s[3], 45);

        return result;
    }

    /// Generate next 32-bit pseudo-random integer.
    pub fn nextU32(self: *SimRng) u32 {
        return @as(u32, @truncate(self.nextU64()));
    }

    /// Return uniform float in range [0.0, 1.0).
    pub fn nextFloat(self: *SimRng) f32 {
        const val = self.nextU32();
        return @as(f32, @floatFromInt(val >> 8)) / 16777216.0;
    }

    /// Return uniform double in range [0.0, 1.0).
    pub fn nextFloat64(self: *SimRng) f64 {
        const val = self.nextU64();
        return @as(f64, @floatFromInt(val >> 11)) / 9007199254740992.0;
    }

    /// Return random integer in range [min, max).
    pub fn nextRange(self: *SimRng, min: usize, max: usize) usize {
        if (min >= max) return min;
        const range = max - min;
        return min + (@as(usize, @intCast(self.nextU64() % @as(u64, @intCast(range)))));
    }

    /// Return random u64 in range [min, max).
    pub fn nextRangeU64(self: *SimRng, min: u64, max: u64) u64 {
        if (min >= max) return min;
        const range = max - min;
        return min + (self.nextU64() % range);
    }

    /// Return true with probability p (where 0.0 <= p <= 1.0).
    pub fn chance(self: *SimRng, probability: f32) bool {
        if (probability <= 0.0) return false;
        if (probability >= 1.0) return true;
        return self.nextFloat() < probability;
    }

    /// Shuffle a slice in-place using Fisher-Yates algorithm.
    pub fn shuffle(self: *SimRng, comptime T: type, slice: []T) void {
        if (slice.len <= 1) return;
        var i: usize = slice.len - 1;
        while (i > 0) : (i -= 1) {
            const j = self.nextRange(0, i + 1);
            const tmp = slice[i];
            slice[i] = slice[j];
            slice[j] = tmp;
        }
    }

    /// Pick a random element from a slice, or null if slice is empty.
    pub fn choice(self: *SimRng, comptime T: type, slice: []const T) ?T {
        if (slice.len == 0) return null;
        const idx = self.nextRange(0, slice.len);
        return slice[idx];
    }

    /// Fork an independent child RNG stream derived deterministically from the current state.
    pub fn fork(self: *SimRng) SimRng {
        const child_seed = self.nextU64();
        return SimRng.init(child_seed);
    }
};

test "sim_rng determinism and reproducibility" {
    var rng1 = SimRng.init(133742);
    var rng2 = SimRng.init(133742);

    for (0..100) |_| {
        try std.testing.expectEqual(rng1.nextU64(), rng2.nextU64());
    }
}

test "sim_rng distributions and shuffle" {
    var rng = SimRng.init(987654321);

    // Range checks
    for (0..100) |_| {
        const r = rng.nextRange(10, 20);
        try std.testing.expect(r >= 10 and r < 20);

        const f = rng.nextFloat();
        try std.testing.expect(f >= 0.0 and f < 1.0);
    }

    // Shuffle check
    var arr = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    rng.shuffle(u32, &arr);

    var sum: u32 = 0;
    for (arr) |val| {
        sum += val;
    }
    try std.testing.expectEqual(@as(u32, 55), sum);
}

test "sim_rng stream forking" {
    var parent = SimRng.init(42);
    var child1 = parent.fork();
    var child2 = parent.fork();

    // Children should have distinct output sequences
    const v1 = child1.nextU64();
    const v2 = child2.nextU64();
    try std.testing.expect(v1 != v2);
}
