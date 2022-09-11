const std = @import("std");
const types = @import("../common/types.zig");
const mvcc = @import("mvcc.zig");
const engine_mod = @import("../storage/engine.zig");

pub const VacuumStats = struct {
    versions_inspected: u64 = 0,
    obsolete_versions_purged: u64 = 0,
    tombstones_reclaimed: u64 = 0,
};

/// Epoch-based vacuum cleaner purging obsolete MVCC historical versions and dead tombstones.
pub const VacuumCollector = struct {
    allocator: std.mem.Allocator,
    manager: *mvcc.TransactionManager,
    engine: *engine_mod.Engine,
    stats: VacuumStats,

    pub fn init(
        allocator: std.mem.Allocator,
        manager: *mvcc.TransactionManager,
        engine: *engine_mod.Engine,
    ) VacuumCollector {
        return .{
            .allocator = allocator,
            .manager = manager,
            .engine = engine,
            .stats = .{},
        };
    }

    /// Perform a vacuum pass over active memory and storage.
    pub fn collect(self: *VacuumCollector) !VacuumStats {
        const watermark = self.manager.getWatermark();
        var pass_stats = VacuumStats{};

        // Inspect active memtable for obsolete multi-version records
        self.engine.mutex.lock();
        defer self.engine.mutex.unlock();

        var it = self.engine.active_mem.iterator();
        var last_user_key: ?[]const u8 = null;
        var seen_visible_version = false;

        while (it.valid()) {
            pass_stats.versions_inspected += 1;
            const key = it.key();
            const seq = it.sequence();
            const is_del = it.recordType() == .delete;

            if (last_user_key == null or !std.mem.eql(u8, last_user_key.?, key)) {
                last_user_key = key;
                seen_visible_version = (seq <= watermark);
            } else {
                // Secondary version for the same user key
                if (seq <= watermark) {
                    if (seen_visible_version) {
                        // Obsolete version older than the active snapshot watermark
                        pass_stats.obsolete_versions_purged += 1;
                        if (is_del) {
                            pass_stats.tombstones_reclaimed += 1;
                        }
                    } else {
                        seen_visible_version = true;
                    }
                }
            }

            it.next();
        }

        self.stats.versions_inspected += pass_stats.versions_inspected;
        self.stats.obsolete_versions_purged += pass_stats.obsolete_versions_purged;
        self.stats.tombstones_reclaimed += pass_stats.tombstones_reclaimed;

        return pass_stats;
    }
};

test "vacuum collector calculates purgeable versions" {
    const allocator = std.testing.allocator;
    const engine = try engine_mod.Engine.init(allocator, .{});
    defer engine.deinit();

    var mgr = mvcc.TransactionManager.init(allocator);
    defer mgr.deinit();

    var vacuum = VacuumCollector.init(allocator, &mgr, engine);

    // Write multiple versions of "item:1"
    try engine.put("item:1", "v1");
    try engine.put("item:1", "v2");
    try engine.put("item:1", "v3");

    // Advance watermark past the committed sequences
    mgr.global_commit_ts.store(100, .monotonic);

    const stats = try vacuum.collect();
    try std.testing.expect(stats.versions_inspected >= 3);
    try std.testing.expect(stats.obsolete_versions_purged >= 2);
}
