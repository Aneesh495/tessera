# Tessera

```
 _____ _____ ____ ____  _____ ____      _    
|_   _| ____/ ___/ ___|| ____|  _ \    / \   
  | | |  _| \___ \___ \|  _| | |_) |  / _ \  
  | | | |___ ___) |__) | |___|  _ <  / ___ \ 
  |_| |_____|____/____/|_____|_| \_\/_/   \_\
```

**Tessera** is a high-performance, embedded multi-model retrieval and storage engine written from scratch in pure Zig 0.16.0 without any third-party dependencies. It unifies high-throughput Log-Structured Merge (LSM) key-value storage, SIMD-accelerated Hierarchical Navigable Small World (HNSW) vector indexing, dynamic Compressed Sparse Row (CSR) graph storage, Multi-Version Concurrency Control (MVCC) with Snapshot Isolation, and Deterministic Simulation Testing (DST) inside a single memory-efficient runtime.

---

## Technical Architecture

```
+=============================================================================+
|                               TESSERA ENGINE                                |
+=============================================================================+
|                                                                             |
|   +-----------------------+              +------------------------------+   |
|   |  TQL Query Interface  |              |    Compact Wire Protocol     |   |
|   |  (Lexer/Parser/Plan)  |              |    (Framing / CRC32C / TCP)  |   |
|   +-----------+-----------+              +--------------+---------------+   |
|               |                                         |                   |
|               +--------------------+--------------------+                   |
|                                    |                                        |
|                     +--------------v--------------+                         |
|                     |     Query Execution Engine   |                         |
|                     +--------------+--------------+                         |
|                                    |                                        |
|      +-----------------------------+-----------------------------+          |
|      |                             |                             |          |
|   +--v------------------+   +------v---------------+   +---------v-------+  |
|   | LSM Storage Engine  |   |  HNSW Vector Index   |   |   Graph Store   |  |
|   |                     |   |                      |   |                 |  |
|   | * MemTable SkipList |   | * Multi-layer Graph  |   | * Dynamic CSR   |  |
|   | * Write-Ahead Log   |   | * SIMD L2/Cosine     |   | * K-Hop BFS     |  |
|   | * 16-Shard Cache    |   | * Heuristic Pruning  |   | * Dijkstra Path |  |
|   | * Leveled SSTables  |   | * SQ8 Quantization   |   | * PageRank      |  |
|   +----------+----------+   +----------+-----------+   +--------+--------+  |
|              |                         |                        |           |
|              +-------------------------+------------------------+           |
|                                        |                                    |
|                       +----------------v---------------+                    |
|                       |  MVCC Concurrency Controller   |                    |
|                       |  (Snapshot Isolation / Vacuum) |                    |
|                       +----------------+---------------+                    |
|                                        |                                    |
|                       +----------------v---------------+                    |
|                       |   DST Simulation & Virtual I/O |                    |
|                       |  (Fault Injected Disk & Net)   |                    |
|                       +--------------------------------+                    |
+=============================================================================+
```

---

## Core Subsystems

### 1. Leveled Log-Structured Merge (LSM) Key-Value Engine
- **Write-Ahead Log (WAL)**: Binary framed append-only log with Castagnoli CRC32-C record validation, supporting crash-recovery replay (`src/storage/wal.zig`).
- **Concurrent SkipList MemTable**: Lock-free probabilistic multi-layer skip list with sequence-ordered versioning and explicit tombstone handling (`src/storage/memtable.zig`).
- **Prefix-Compressed SSTables**: Block format with configurable restart points ($K=16$) enabling $O(\log N)$ binary searching within blocks (`src/storage/block.zig`).
- **16-Shard Striped Block Cache**: Hash-striped LRU block cache eliminating thread contention across concurrent queries (`src/storage/block_cache.zig`).
- **Leveled Compaction Controller**: Multi-level hierarchy ($L_0$ to $L_6$) with exponential capacity sizing and multi-way deduplicating merging iterators (`src/storage/compaction.zig`).
- **Blocked Bloom Filters**: 64-byte cache-line aligned Bloom filters with double hashing ($< 1\%$ false positive rate) (`src/common/bloom.zig`).

### 2. SIMD Vector Proximity Index (HNSW)
- **Hierarchical Proximity Graphs**: Multi-layer navigable small world index with exponential scale parameter $m_L = 1 / \ln(M)$ (`src/vector/hnsw.zig`).
- **Heuristic Edge Diversity Pruning**: Relative Neighbor Graph (RNG) pruning heuristic preventing redundant cluster clustering and expanding network diameter.
- **SIMD Distance Kernels**: Auto-vectorized `@Vector(8, f32)` kernels for Euclidean (L2), Cosine, Dot Product, and Manhattan distances (`src/vector/distance.zig`).
- **8-Bit Scalar Quantization (SQ8)**: Compresses 32-bit floats into 8-bit unsigned integers with affine scale factors, reducing RAM footprint by 75% (`src/vector/quantization.zig`).

### 3. Dynamic Compressed Sparse Row (CSR) Graph Engine
- **Dual Representation**: High-throughput dynamic adjacency store transitioning seamlessly to immutable 64-bit aligned CSR arrays (`src/graph/adjacency.zig`).
- **K-Hop Breadth-First Search**: Optimized bitset-deduplicated topological neighborhood discovery (`src/graph/traversal.zig`).
- **Bidirectional Dijkstra**: Lowest-weight pathfinding with bidirectional priority search and exact route sequence reconstruction (`src/graph/algorithms.zig`).
- **Personalized PageRank (PPR)**: Sparse power-iteration convergence with restart damping $\alpha = 0.85$ (`src/graph/algorithms.zig`).
- **Joint Multi-Model Retrieval**: Joint graph-vector hybrid retrieval fusing graph topological hops with semantic vector distance ranking (`src/graph/hybrid.zig`).

### 4. Multi-Version Concurrency Control (MVCC)
- **Snapshot Isolation**: Transactions read from consistent point-in-time snapshots without locking out writes (`src/txn/mvcc.zig`).
- **First-Committer-Wins**: Write-set validation detecting and aborting serialization conflicts on commit (`src/txn/transaction.zig`).
- **Epoch-Based Vacuum Cleaner**: Sweeps dead tombstones and shadowed versions older than the oldest active transaction timestamp (`src/txn/vacuum.zig`).

### 5. Deterministic Simulation Testing (DST)
- **Virtual Clock & PRNG**: Discrete time scheduling with step advancement (`src/sim/sim_clock.zig`) and reproducible Xoshiro256** pseudorandom streams (`src/sim/sim_rng.zig`).
- **Simulated Fault-Injected Disk**: Injects torn writes (partial page write on sudden power loss), bit flips, and crash rollbacks (`src/sim/sim_disk.zig`).
- **Simulated Network Cluster**: Injects packet loss, latency jitter, duplicate deliveries, and network partitions (`src/sim/sim_cluster.zig`).
- **Linearizability Checker**: Formal Wing & Gong / Porcupine state space search verifying strict sequential linearizability of concurrent operation histories (`src/sim/linearizability.zig`).

### 6. Tessera Query Language (TQL) & Wire Protocol
- **Zero-Allocation Lexer & Recursive Descent Parser**: Parses declarative multi-model statements without heap allocations during tokenization (`src/query/lexer.zig`, `src/query/parser.zig`).
- **Cost-Based Query Planner**: Generates optimized physical plans for KV, vector, graph, and hybrid queries (`src/query/planner.zig`).
- **Binary Wire Protocol**: 24-byte framed headers with CRC32-C verification, operation opcodes, and request correlation IDs (`src/net/protocol.zig`).
- **Multiplexed Server & Client**: Network engine coordinating requests over the binary protocol (`src/net/server.zig`, `src/net/client.zig`).
- **Interactive Terminal REPL**: Full-featured interactive CLI shell with live microsecond execution timing and runtime metrics (`src/cli/repl.zig`).

---

## Performance Benchmarks

Empirical performance measured on Apple Silicon unified memory (Zig 0.16.0):

| Workload | Operations | Elapsed Time | Throughput |
|:---|:---|:---|:---|
| **Sequential Writes** (LSM Engine) | 50,000 KV pairs | 850.39 ms | **58,797 ops/sec** |
| **Point Lookups** (LSM Engine) | 50,000 KV pairs | 2,306.03 ms | **21,682 ops/sec** |
| **Concurrent Transactions** (MVCC) | 5,000 Txn commits | 78.45 ms | **63,735 txn/sec** |
| **2-Hop BFS Traversal** (CSR Graph) | 500 Queries | 47.06 ms | **10,626 queries/sec** |
| **KNN Vector Search** (HNSW, K=10) | 1,000 Queries | 5,202.26 ms | **192 QPS** |
| **Linearizability Verification** (DST) | 100 Concurrent Ops | Validated | **PASSED (Strict Linearizability)** |

---

## Quickstart

### Prerequisites
- [Zig 0.16.0](https://ziglang.org/download/) installed and on `PATH`.

### Building from Source

```bash
# Clone the repository
git clone https://github.com/Aneesh495/tessera.git
cd tessera

# Build library, CLI, and benchmark targets
zig build
```

This installs three binaries into `zig-out/bin/`:
- `tessera`: Primary interactive CLI and server.
- `tessera-bench`: Performance benchmark suite.
- `tessera-inspect`: Offline storage layout inspector and validator.

---

## Running the Interactive Shell (REPL)

Launch the interactive TQL shell:

```bash
./zig-out/bin/tessera repl
```

Execute multi-model queries directly:

```sql
tessera> PUT user:1001 "Alice Smith"
OK [82 us]

tessera> GET user:1001
"Alice Smith" [14 us]

tessera> VEC_INSERT 1 [0.24, -0.18, 0.95, 0.42]
VECTOR_INSERTED [124 us]

tessera> VEC_SEARCH [0.20, -0.15, 0.90, 0.40] TOP 5 EF 64
Vector Matches (1):
  [ID: 1] Distance: 0.0045
[48 us]

tessera> GRAPH_ADD_NODE 100 "alice"
NODE_ADDED [28 us]

tessera> GRAPH_ADD_NODE 200 "bob"
NODE_ADDED [19 us]

tessera> GRAPH_ADD_EDGE 100 200 1.0
EDGE_ADDED [32 us]

tessera> GRAPH_NEIGHBORS 100 HOPS 1
Nodes (1): [200] [18 us]

tessera> .metrics
Engine Metrics:
  Writes:      1
  Reads:       1
  Deletes:     0
  Compactions: 0
  Vector Count:1
  Graph Nodes: 2

tessera> .exit
Exiting Tessera.
```

---

## Running Benchmarks & Tooling

```bash
# Run the built-in multi-model benchmark suite
zig build bench

# Run the offline storage inspector
zig build inspect

# Run the full test suite
zig build test
```

---

## Project Structure

```
tessera/
├── build.zig                   # Unified build graph
├── build.zig.zon               # Package manifest and metadata
├── src/
│   ├── root.zig                # Top-level library module and re-exports
│   ├── common/                 # Core data structures and primitives
│   │   ├── types.zig           # Strong type IDs and atomic SpinLock
│   │   ├── buffer.zig          # 64-byte cache-aligned buffers and pool
│   │   ├── crc32.zig           # Castagnoli CRC32-C calculation
│   │   ├── bloom.zig           # Blocked Bloom filter with probe trailer
│   │   ├── comparator.zig      # Internal key encoder and ordering
│   │   ├── arena.zig           # Bump chunk arena allocator
│   │   ├── ring_buffer.zig     # Wait-free SPSC circular buffer
│   │   └── stats.zig           # Lock-free latency histogram and metrics
│   ├── storage/                # Log-Structured Merge storage engine
│   │   ├── wal.zig             # Write-Ahead Log writer and recovery reader
│   │   ├── memtable.zig        # Concurrent SkipList MemTable
│   │   ├── block.zig           # Prefix-compressed SSTable blocks
│   │   ├── block_cache.zig     # 16-shard striped LRU block cache
│   │   ├── sstable.zig         # Immutable SSTable builder and reader
│   │   ├── manifest.zig        # VersionSet and LSM level hierarchy
│   │   ├── compaction.zig      # Leveled compaction controller and merge iterator
│   │   └── engine.zig          # Unified LSM engine coordinator
│   ├── vector/                 # SIMD vector retrieval engine
│   │   ├── distance.zig        # Vectorized L2, Cosine, Dot, Manhattan kernels
│   │   ├── quantization.zig    # 8-bit Scalar Quantization (SQ8)
│   │   ├── hnsw.zig            # Hierarchical Navigable Small World proximity graph
│   │   ├── ann_search.zig      # Beam search candidate priority queues
│   │   └── filtered_search.zig # In-traversal predicate-filtered search
│   ├── graph/                  # Dynamic CSR graph engine
│   │   ├── adjacency.zig       # Bidirectional lists and static CSR builder
│   │   ├── traversal.zig       # K-hop BFS and reachability search
│   │   ├── algorithms.zig      # Dijkstra shortest paths and PageRank
│   │   └── hybrid.zig          # Joint Graph-Vector multi-model retriever
│   ├── txn/                    # Transaction engine
│   │   ├── mvcc.zig            # MVCC Snapshot Isolation controller
│   │   ├── transaction.zig     # Transaction handle with write buffering
│   │   └── vacuum.zig          # Epoch-based garbage collector
│   ├── query/                  # TQL Query Language
│   │   ├── ast.zig             # Abstract syntax tree definitions
│   │   ├── lexer.zig           # Zero-allocation token lexer
│   │   ├── parser.zig          # Recursive descent statement parser
│   │   ├── planner.zig         # Cost-based physical query planner
│   │   └── executor.zig        # End-to-end multi-model execution engine
│   ├── sim/                    # Deterministic Simulation Testing (DST)
│   │   ├── sim_clock.zig       # Discrete virtual timekeeper
│   │   ├── sim_rng.zig         # Xoshiro256** reproducible PRNG
│   │   ├── sim_disk.zig        # Fault-injected virtual storage device
│   │   ├── sim_cluster.zig     # Simulated network cluster and partition matrix
│   │   └── linearizability.zig # Formal Porcupine-style history verifier
│   ├── net/                    # Wire protocol and networking
│   │   ├── protocol.zig        # Framed binary protocol with CRC32-C
│   │   ├── server.zig          # Network query server
│   │   └── client.zig          # Client connection handle
│   └── cli/                    # Command-line interface
│       ├── repl.zig            # Interactive terminal shell
│       └── main.zig            # CLI entrypoint
├── bench/
│   └── bench.zig               # Comprehensive micro and macro benchmark suite
├── tools/
│   └── inspect.zig             # Offline storage layout inspector
└── docs/
    ├── ARCHITECTURE.md         # Detailed subsystem architecture
    ├── STORAGE_FORMAT.md       # Binary disk layouts for WAL and SSTables
    ├── TQL_SPEC.md             # TQL formal EBNF grammar and semantics
    └── BENCHMARKS.md           # Benchmark methodology and results
```

---

## License

MIT License. Crafted with passion in Zig.
