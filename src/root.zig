pub const std = @import("std");

// Core Subsystems
pub const common = struct {
    pub const types = @import("common/types.zig");
    pub const buffer = @import("common/buffer.zig");
    pub const crc32 = @import("common/crc32.zig");
    pub const bloom = @import("common/bloom.zig");
    pub const comparator = @import("common/comparator.zig");
    pub const arena = @import("common/arena.zig");
    pub const ring_buffer = @import("common/ring_buffer.zig");
    pub const stats = @import("common/stats.zig");
};

pub const storage = struct {
    pub const wal = @import("storage/wal.zig");
    pub const memtable = @import("storage/memtable.zig");
    pub const block = @import("storage/block.zig");
    pub const block_cache = @import("storage/block_cache.zig");
    pub const sstable = @import("storage/sstable.zig");
    pub const manifest = @import("storage/manifest.zig");
    pub const compaction = @import("storage/compaction.zig");
    pub const engine = @import("storage/engine.zig");
};

pub const vector = struct {
    pub const distance = @import("vector/distance.zig");
    pub const quantization = @import("vector/quantization.zig");
    pub const hnsw = @import("vector/hnsw.zig");
    pub const ann_search = @import("vector/ann_search.zig");
    pub const filtered_search = @import("vector/filtered_search.zig");
};

pub const graph = struct {
    pub const adjacency = @import("graph/adjacency.zig");
    pub const traversal = @import("graph/traversal.zig");
    pub const algorithms = @import("graph/algorithms.zig");
    pub const hybrid = @import("graph/hybrid.zig");
};

pub const txn = struct {
    pub const mvcc = @import("txn/mvcc.zig");
    pub const transaction = @import("txn/transaction.zig");
    pub const vacuum = @import("txn/vacuum.zig");
};

pub const query = struct {
    pub const ast = @import("query/ast.zig");
    pub const lexer = @import("query/lexer.zig");
    pub const parser = @import("query/parser.zig");
    pub const planner = @import("query/planner.zig");
    pub const executor = @import("query/executor.zig");
};

pub const sim = struct {
    pub const sim_clock = @import("sim/sim_clock.zig");
    pub const sim_rng = @import("sim/sim_rng.zig");
    pub const sim_disk = @import("sim/sim_disk.zig");
    pub const sim_cluster = @import("sim/sim_cluster.zig");
    pub const linearizability = @import("sim/linearizability.zig");
};

pub const net = struct {
    pub const protocol = @import("net/protocol.zig");
    pub const server = @import("net/server.zig");
    pub const client = @import("net/client.zig");
};

// Re-exports of primary types
pub const NodeId = common.types.NodeId;
pub const EdgeId = common.types.EdgeId;
pub const TxnId = common.types.TxnId;
pub const Lsn = common.types.Lsn;
pub const VectorId = common.types.VectorId;
pub const Timestamp = common.types.Timestamp;
pub const Status = common.types.Status;

pub const Engine = storage.engine.Engine;
pub const HnswIndex = vector.hnsw.HnswIndex;
pub const GraphStore = graph.adjacency.GraphStore;
pub const TransactionManager = txn.mvcc.TransactionManager;

test {
    std.testing.refAllDecls(@This());
}
