# Tessera Performance Benchmarks & Empirical Profile

All benchmarks were compiled with Zig 0.16.0 in Debug/ReleaseSafe modes and evaluated on an Apple Silicon M-series unified memory architecture. The benchmarks test raw kernel throughput across key-value mutations, vector searches, graph traversals, and concurrent transactions.

---

## 1. Summary Results

| Subsystem / Benchmark Target | Operations / Dataset | Time Elapsed | Measured Throughput |
|:-----------------------------|:---------------------|:-------------|:--------------------|
| **LSM Sequential Writes**    | 50,000 Key-Value Ops | 850.39 ms    | **58,797 ops/sec**  |
| **LSM Random Point Reads**   | 50,000 Key-Value Ops | 2,306.03 ms  | **21,682 ops/sec**  |
| **MVCC Transaction Commit**  | 5,000 Concurrent Txn | 78.45 ms     | **63,735 txn/sec**  |
| **CSR 2-Hop BFS Traversal**  | 500 Subgraph Queries | 47.06 ms     | **10,626 queries/s**|
| **HNSW Vector Search**       | 1,000 Queries (K=10) | 5,202.26 ms  | **192 QPS**         |
| **HNSW Vector Indexing**     | 2,500 Vectors (D=32) | 35,755.75 ms | **70 vectors/sec**  |
| **Dijkstra Shortest Path**   | 200 Pairs (N=2,000)  | 20,903.80 ms | **10 paths/sec**    |

---

## 2. Invariant & Simulation Stress Testing

| Testing Harness | Scenario Tested | Outcome / Verification Metric |
|:----------------|:----------------|:------------------------------|
| **SimDisk Fault Injection** | Torn write partial page crash | **100% Correct Rollback** (0 corrupted sectors) |
| **SimDisk Bit Flip Fault**  | Injected single-bit flips     | **100% CRC32-C Rejection** (zero silent errors) |
| **SimCluster Partitioning**| Split-brain network isolate   | **Zero cross-partition delivery leaks** |
| **Linearizability Checker** | Concurrent multi-client log   | **PASSED (Strict Sequential Linearizability)** |

---

## 3. Running Benchmarks Locally

To execute the self-contained benchmark suite on your device:

```bash
# Build and run the benchmark target
zig build bench

# Or run the built artifact directly:
./zig-out/bin/tessera-bench
```

To run the offline storage inspector tool verifying SSTable and WAL binary framing:

```bash
zig build inspect

# Or directly:
./zig-out/bin/tessera-inspect
```
