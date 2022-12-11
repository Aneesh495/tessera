# Tessera Query Language (TQL) Specification

Tessera Query Language (TQL) is a declarative, unified query language designed for seamless multi-model interaction across key-value, vector similarity, and graph topological modalities.

---

## 1. Formal Grammar (EBNF)

```ebnf
Statement           ::= KvStatement
                      | VectorStatement
                      | GraphStatement
                      | HybridStatement
                      | TxnStatement ;

(* Key-Value Statements *)
KvStatement         ::= "PUT" Identifier ( StringLiteral | Identifier )
                      | "GET" Identifier
                      | "DELETE" Identifier
                      | "SCAN" [ "LIMIT" Integer ] ;

(* Vector Statements *)
VectorStatement     ::= "VEC_INSERT" Integer VectorLiteral
                      | "VEC_SEARCH" VectorLiteral [ "TOP" Integer ] [ "EF" Integer ] ;

VectorLiteral       ::= "[" Number ( "," Number )* "]" ;

(* Graph Statements *)
GraphStatement      ::= "GRAPH_ADD_NODE" Integer ( StringLiteral | Identifier )
                      | "GRAPH_ADD_EDGE" Integer Integer [ Number ]
                      | "GRAPH_SHORTEST_PATH" Integer Integer
                      | "GRAPH_NEIGHBORS" Integer [ "HOPS" Integer ] ;

(* Joint Multi-Model Hybrid Search *)
HybridStatement     ::= "HYBRID_SEARCH" Integer VectorLiteral [ "HOPS" Integer ] [ "TOP" Integer ] [ "ALPHA" Number ] ;

(* Transaction Statements *)
TxnStatement        ::= "BEGIN"
                      | "COMMIT"
                      | "ROLLBACK" ;

Identifier          ::= [a-zA-Z_][a-zA-Z0-9_:.-]* ;
StringLiteral       ::= '"' [^"]* '"' | "'" [^']* "'" ;
Number              ::= [+-]? [0-9]+ ( "." [0-9]+ )? ;
Integer             ::= [0-9]+ ;
```

---

## 2. Statement Semantics & Examples

### 2.1 Key-Value Operations
- **`PUT <key> <value>`**: Writes or replaces a key-value record in the active MemTable and WAL.
  ```sql
  PUT user:1001 "Alice Smith"
  PUT config:cache:max_mb 2048
  ```
- **`GET <key>`**: Performs point lookup through MemTable, immutable buffers, and leveled SSTables with Bloom filter acceleration.
  ```sql
  GET user:1001
  ```
- **`DELETE <key>`**: Inserts a sequence-stamped tombstone into the engine, shadowing earlier entries.
  ```sql
  DELETE user:1001
  ```

### 2.2 Vector Similarity Operations
- **`VEC_INSERT <id> [<f32>, ...]`**: Inserts a high-dimensional embedding into the HNSW proximity graph with heuristic diversity edge pruning.
  ```sql
  VEC_INSERT 1 [0.24, -0.18, 0.95, 0.42]
  ```
- **`VEC_SEARCH [<f32>, ...] TOP <k> EF <ef>`**: Executes a SIMD-accelerated beam search returning the $K$ closest vectors by L2 or Cosine distance.
  ```sql
  VEC_SEARCH [0.20, -0.15, 0.90, 0.40] TOP 5 EF 64
  ```

### 2.3 Graph Topological Operations
- **`GRAPH_ADD_NODE <id> <property>`**: Creates a new vertex with associated metadata.
  ```sql
  GRAPH_ADD_NODE 100 "user_node"
  ```
- **`GRAPH_ADD_EDGE <u> <v> [weight]`**: Adds a directed or weighted relationship.
  ```sql
  GRAPH_ADD_EDGE 100 200 1.5
  ```
- **`GRAPH_SHORTEST_PATH <src> <dst>`**: Finds the lowest-weight path via Dijkstra with exact path sequence reconstruction.
  ```sql
  GRAPH_SHORTEST_PATH 100 200
  ```
- **`GRAPH_NEIGHBORS <id> HOPS <k>`**: Discovers all vertices reachable within $K$ hops using breadth-first traversal.
  ```sql
  GRAPH_NEIGHBORS 100 HOPS 2
  ```

### 2.4 Joint Multi-Model Retrieval
- **`HYBRID_SEARCH <seed_node> [<f32>, ...] HOPS <k> TOP <top_k>`**: Fuses topological graph expansion with semantic vector proximity. The query explores vertices reachable within $K$ hops from the seed vertex, ranking the candidates using SIMD vector distance.
  ```sql
  HYBRID_SEARCH 100 [0.12, 0.88, -0.45, 0.22] HOPS 2 TOP 10
  ```

### 2.5 Transaction Controls
- **`BEGIN`**: Initiates a new Snapshot Isolation transaction handle.
- **`COMMIT`**: Atomically commits buffered writes, validating first-committer-wins conflicts.
- **`ROLLBACK`**: Discards uncommitted buffered writes without mutating the store.
