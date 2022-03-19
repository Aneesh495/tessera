const std = @import("std");

/// High-dynamic-range histogram with logarithmic buckets for tracking nanosecond/microsecond latencies.
pub const LatencyHistogram = struct {
    pub const NUM_BUCKETS: usize = 32;

    buckets: [NUM_BUCKETS]std.atomic.Value(u64),
    count: std.atomic.Value(u64),
    sum_micros: std.atomic.Value(u64),
    min_micros: std.atomic.Value(u64),
    max_micros: std.atomic.Value(u64),

    pub fn init() LatencyHistogram {
        var h = LatencyHistogram{
            .buckets = undefined,
            .count = std.atomic.Value(u64).init(0),
            .sum_micros = std.atomic.Value(u64).init(0),
            .min_micros = std.atomic.Value(u64).init(std.math.maxInt(u64)),
            .max_micros = std.atomic.Value(u64).init(0),
        };
        for (&h.buckets) |*b| {
            b.* = std.atomic.Value(u64).init(0);
        }
        return h;
    }

    fn bucketIndex(val: u64) usize {
        if (val == 0) return 0;
        const leading_zeros = @clz(val);
        const idx = 64 - leading_zeros;
        return @min(idx, NUM_BUCKETS - 1);
    }

    pub fn record(self: *LatencyHistogram, micros: u64) void {
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.sum_micros.fetchAdd(micros, .monotonic);

        // Update min
        var cur_min = self.min_micros.load(.monotonic);
        while (micros < cur_min) {
            cur_min = self.min_micros.cmpxchgWeak(cur_min, micros, .monotonic, .monotonic) orelse break;
        }

        // Update max
        var cur_max = self.max_micros.load(.monotonic);
        while (micros > cur_max) {
            cur_max = self.max_micros.cmpxchgWeak(cur_max, micros, .monotonic, .monotonic) orelse break;
        }

        const idx = bucketIndex(micros);
        _ = self.buckets[idx].fetchAdd(1, .monotonic);
    }

    pub fn percentile(self: *const LatencyHistogram, p: f64) u64 {
        const total = self.count.load(.monotonic);
        if (total == 0) return 0;

        const target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total)) * (p / 100.0)));
        var accumulated: u64 = 0;

        for (&self.buckets, 0..) |*b, i| {
            accumulated += b.load(.monotonic);
            if (accumulated >= target) {
                if (i == 0) return 1;
                return @as(u64, 1) << @as(u6, @intCast(i - 1));
            }
        }
        return self.max_micros.load(.monotonic);
    }

    pub fn average(self: *const LatencyHistogram) u64 {
        const total = self.count.load(.monotonic);
        if (total == 0) return 0;
        return self.sum_micros.load(.monotonic) / total;
    }
};

/// Global operational counters for the database engine.
pub const EngineMetrics = struct {
    writes_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reads_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    deletes_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    block_cache_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    block_cache_misses: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    compactions_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    vector_searches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    graph_traversals: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_latency: LatencyHistogram = LatencyHistogram.init(),
    write_latency: LatencyHistogram = LatencyHistogram.init(),

    pub fn init() EngineMetrics {
        return .{};
    }

    pub fn cacheHitRatio(self: *const EngineMetrics) f64 {
        const hits = self.block_cache_hits.load(.monotonic);
        const misses = self.block_cache_misses.load(.monotonic);
        const total = hits + misses;
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
    }
};

test "latency histogram recording and percentiles" {
    var hist = LatencyHistogram.init();

    // Record latencies
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        hist.record(i);
    }

    try std.testing.expectEqual(@as(u64, 100), hist.count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), hist.min_micros.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 100), hist.max_micros.load(.monotonic));

    const p50 = hist.percentile(50.0);
    const p99 = hist.percentile(99.0);

    try std.testing.expect(p50 > 0 and p50 <= 64);
    try std.testing.expect(p99 >= 64);
}
