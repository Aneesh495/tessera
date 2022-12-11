# Tessera Architecture & Internal Subsystem Design

Tessera is an embedded, unified multi-model storage and retrieval engine written from scratch in pure Zig 0.16.0 without any third-party dependencies. It combines a Log-Structured Merge (LSM) key-value engine, a SIMD-accelerated Hierarchical Navigable Small World (HNSW) vector index, a dynamic Compressed Sparse Row (CSR) graph engine, Multi-Version Concurrency Control (MVCC) with Snapshot Isolation, and a Deterministic Simulation Testing (DST) framework.

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

## 1. Log-Structured Merge (LSM) Storage Subsystem

### 1.1 Write Path
When a write request (`put` or `delete`) arrives:
1. **Sequence Allocation**: A monotonically increasing sequence number is assigned under a spinlock.
2. **Write-Ahead Log (WAL)**: The mutation is formatted into a binary framed record (`src/storage/wal.zig`) protected by Castagnoli CRC32-C.
3. **Active MemTable**: The key-value record is inserted into an in-memory lock-free SkipList (`src/storage/memtable.zig`) with branching factor 4 and maximum height 16.
4. **MemTable Freezing & Flush**: When the active MemTable reaches `write_buffer_size` (default 4 MB), it transitions to immutable state (`imm_mems`), and background worker threads flush it into a Level 0 SSTable.

```
Write Request -> Allocate Seq -> Append to WAL -> Insert to Active SkipList
                                                         |
                                                  (if size >= 4MB)
                                                         v
                                                 Freeze Immutable SkipList
                                                         |
                                                  (background flush)
                                                         v
                                                 Write L0 SSTable File
```

### 1.2 Leveled SSTable Architecture
SSTables (`src/storage/sstable.zig`) are organized into hierarchical levels ($L_0$ through $L_6$):
- **Level 0**: Contains non-overlapping or overlapping SSTables directly flushed from memory.
- **Levels 1 to 6**: Guarantee strictly non-overlapping key ranges within each level. Capacity grows exponentially with multiplier $T = 10$.
- **Compaction Controller** (`src/storage/compaction.zig`): Evaluates level scoring (size ratio vs target capacity) to select victim tables for multi-way merge-sorting into Level $i+1$.

### 1.3 Block Format and Sharded Cache
- **Data Blocks** (`src/storage/block.zig`): Store prefix-compressed key-value records. Every $K$ records (default 16), a full uncompressed restart point is written, enabling $O(\log N)$ binary searching within blocks.
- **16-Shard Striped Block Cache** (`src/storage/block_cache.zig`): Distributes cached uncompressed blocks across 16 independent LRU shards indexed by 64-bit SipHash keys, eliminating cache contention across concurrent threads.
- **Blocked Bloom Filters** (`src/common/bloom.zig`): 64-byte cache-line aligned Bloom filters with self-describing probe counts and false positive rate below 1%.

---

## 2. SIMD Vector Retrieval Subsystem

### 2.1 Multi-Layer Proximity Graph (HNSW)
The vector index (`src/vector/hnsw.zig`) implements the Hierarchical Navigable Small World topology:
- **Hierarchical Layers**: Vectors are assigned random top layers according to an exponential distribution parameter $m_L = 1 / \ln(M)$. Upper layers contain sparse long-range highway links; layer 0 contains the dense proximity graph.
- **Beam Search Traversal**: Greedy descent from `enter_node` at `max_level` down to layer 1, followed by bounded priority queue beam search at layer 0 using search radius `ef_search`.
- **Heuristic Edge Diversity Pruning**: Enforces relative neighbor graph (RNG) heuristics. Rather than selecting the closest candidates, it selects diverse neighbors that are not closer to an already-selected neighbor than to the base node.

### 2.2 SIMD Vector Acceleration
Distance kernels (`src/vector/distance.zig`) leverage Zig's `@Vector(8, f32)` primitive for auto-vectorized SIMD computation:
- **Euclidean (L2)**: Unrolled 8-wide FMA accumulation with tail reduction.
- **Cosine & Dot Product**: Simultaneous norm tracking and dot-product vectorization.
- **Scalar Quantization (SQ8)** (`src/vector/quantization.zig`): Compresses 32-bit floats into 8-bit unsigned integers with affine scale and offset parameters, reducing memory footprint by 75% while supporting asymmetric distance estimation.

---

## 3. Dynamic Compressed Sparse Row (CSR) Graph Subsystem

### 3.1 Dual-Representation Adjacency Store
Graph data (`src/graph/adjacency.zig`) is stored in a bidirectional structure:
- **Dynamic Forward & Reverse Adjacency Lists**: Backed by hash tables and dynamically resized edge buffers, supporting high-throughput insertions.
- **Static CSR Matrix View**: Built by snapshotting active lists into contiguous 64-bit aligned offsets and target arrays, providing zero-overhead cache locality during analytical traversals.

### 3.2 Graph Traversal & Analytics
- **K-Hop Breadth-First Search** (`src/graph/traversal.zig`): Frontier-based exploration with bitset deduplication.
- **Bidirectional Dijkstra** (`src/graph/algorithms.zig`): Min-heap priority queues expanding simultaneously from source and target nodes with exact path reconstruction.
- **Personalized PageRank (PPR)** (`src/graph/algorithms.zig`): Power-iteration matrix computation with restart probability $\alpha = 0.85$ and convergence tolerance $\epsilon = 10^{-5}$.
- **Joint Multi-Model Hybrid Search** (`src/graph/hybrid.zig`): Connects graph topology with semantic vectors, searching vector neighborhoods constrained to reachable topological components.

---

## 4. Multi-Version Concurrency Control (MVCC)

### 4.1 Snapshot Isolation & Conflict Detection
The MVCC engine (`src/txn/mvcc.zig`) implements true Snapshot Isolation:
- **Read Timestamp**: Transactions observe only records with sequence number $\le \text{read\_ts}$.
- **First-Committer-Wins**: When transaction $T$ commits at timestamp $\text{commit\_ts}$, its write-set is validated against all concurrent transactions that committed in interval $(\text{read\_ts}, \text{commit\_ts}]$. If any overlap occurs, $T$ is aborted with `error.SerializationConflict`.
- **Read-Your-Own-Writes**: Active transactions buffer uncommitted writes in a local private buffer (`src/txn/transaction.zig`), shadowing underlying store values.

### 4.2 Epoch-Based Vacuum Cleaning
Historical multi-version chains and deleted tombstones are swept by the vacuum cleaner (`src/txn/vacuum.zig`):
- Tracks the oldest active transaction timestamp ($\text{min\_active\_ts}$).
- Compacts historical version chains, purging dead versions shadowed by newer visible updates.

---

## 5. Deterministic Simulation Testing (DST)

Tessera includes an in-tree deterministic simulation testing harness inspired by FoundationDB and Jepsen:
- **Discrete Virtual Clock** (`src/sim/sim_clock.zig`): Completely decouples time progression from the host OS clock, allowing millions of simulated events to execute in fractions of a second.
- **Reproducible PRNG** (`src/sim/sim_rng.zig`): Xoshiro256** generator with SplitMix64 initialization and deterministic stream forking.
- **Virtual Fault-Injected Disk** (`src/sim/sim_disk.zig`): Simulates torn writes (partial page flush on crash), bit flips, out-of-space conditions, and simulated power outages.
- **Simulated Cluster & Partition Matrix** (`src/sim/sim_cluster.zig`): Injects symmetric and asymmetric network partitions, message reordering, latency jitter, and packet duplication.
- **Linearizability Checker** (`src/sim/linearizability.zig`): Explores state space using Wing & Gong algorithms to formally verify whether concurrent execution traces linearize to a valid sequential register execution.
