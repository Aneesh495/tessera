# Tessera Binary Storage Format Specification

This document specifies the on-disk binary layouts of all persistent artifacts in Tessera, including the Write-Ahead Log (WAL), Sorted String Tables (SSTables), Data Blocks, Index Blocks, Bloom Filters, and Footers. All multi-byte integers are encoded in Little-Endian byte order.

---

## 1. Write-Ahead Log (WAL) Record Format

The Write-Ahead Log is an append-only stream of framed binary records. Every record begins with a fixed 19-byte header followed by variable-length key and value payloads.

```
+-------------------+-------------------+-------------------+-------------------+
|  Length (4 Bytes) |  CRC32-C (4 Bytes)| Sequence (8 Bytes)| RecordType (1 B)  |
+-------------------+-------------------+-------------------+-------------------+
| Key Length (2 B)  | Key Bytes (var)   | Value Bytes (var)                     |
+-------------------+-------------------+---------------------------------------+
```

### Field Definitions:
- `Length` (`u32`, 4 bytes): Total length of the frame payload (`1 + 2 + key_len + val_len`).
- `CRC32-C` (`u32`, 4 bytes): Castagnoli CRC32-C checksum calculated over `[RecordType | Key Length | Key Bytes | Value Bytes]`.
- `Sequence` (`u64`, 8 bytes): Monotonically increasing LSM sequence number for ordering.
- `RecordType` (`u8`, 1 byte):
  - `0x01`: `Put` (regular key-value write)
  - `0x02`: `Delete` (deletion tombstone)
- `Key Length` (`u16`, 2 bytes): Byte length of key slice ($0 \le \text{len} \le 65535$).
- `Key Bytes` (variable): Raw bytes of key slice.
- `Value Bytes` (variable): Raw bytes of value slice (empty for deletions).

---

## 2. SSTable File Layout

An SSTable is an immutable binary file divided into contiguous functional blocks:

```
+=============================================================================+
| Data Block 0                                                                |
+-----------------------------------------------------------------------------+
| Data Block 1                                                                |
+-----------------------------------------------------------------------------+
| ...                                                                         |
+-----------------------------------------------------------------------------+
| Data Block N - 1                                                            |
+=============================================================================+
| Filter Block (Blocked Bloom Filter Bitset)                                  |
+-----------------------------------------------------------------------------+
| MetaIndex Block (Maps "filter.bloom" -> Filter BlockHandle)                 |
+-----------------------------------------------------------------------------+
| Index Block (Maps Key -> Data BlockHandle)                                  |
+=============================================================================+
| Table Footer (Fixed 48 Bytes, Magic: 0x5445535345524131)                    |
+=============================================================================+
```

### 2.1 Block Handle Format (16 Bytes)
References the byte range of an individual block within the SSTable:
- `Offset` (`u64`, 8 bytes): Absolute starting byte offset within file.
- `Size` (`u64`, 8 bytes): Exact byte length of the block.

### 2.2 Table Footer Format (Fixed 48 Bytes)
Located at the final 48 bytes of every valid SSTable:
- `Metaindex Block Handle` (`[16]u8`, 16 bytes): Handle referencing MetaIndex block.
- `Index Block Handle` (`[16]u8`, 16 bytes): Handle referencing Index block.
- `Padding / Reserved` (`[8]u8`, 8 bytes): Zero-filled reserve bytes.
- `Magic Number` (`u64`, 8 bytes): Fixed constant `0x5445535345524131` (ASCII `"TESSERA1"`).

---

## 3. Data Block Format (Prefix-Compressed)

Data blocks store key-value entries sorted lexicographically. Entries share common key prefixes to minimize disk and cache footprint.

```
+-----------------------------------------------------------------------------+
| Entry 0 (Shared: 0, Non-Shared: K0, ValLen: V0, KeyBytes, ValueBytes)       |
+-----------------------------------------------------------------------------+
| Entry 1 (Shared: S1, Non-Shared: N1, ValLen: V1, KeyBytes, ValueBytes)      |
+-----------------------------------------------------------------------------+
| ...                                                                         |
+-----------------------------------------------------------------------------+
| Restart Point Array (Restart 0, Restart 1, ... Restart M - 1) [u32 * M]     |
+-----------------------------------------------------------------------------+
| Restart Point Count (`u32`, 4 bytes)                                        |
+-----------------------------------------------------------------------------+
```

### 3.1 Entry Layout:
- `Shared Length` (`u32`, 4 bytes): Number of bytes shared with the preceding key.
- `Non-Shared Length` (`u32`, 4 bytes): Number of unshared suffix bytes in this key.
- `Value Length` (`u32`, 4 bytes): Byte length of the value.
- `Key Delta` (`[non_shared]u8`): Unshared suffix bytes of key.
- `Value` (`[value_len]u8`): Uncompressed value bytes.

### 3.2 Restart Point Array:
Every $K$ entries (default $K = 16$), an entry is encoded with `Shared Length = 0` (a full uncompressed key). The relative byte offset of this entry is recorded in the restart array at the end of the block.
- Enables binary search directly within the block without scanning from entry 0.
- Restart array is read backwards from block trailer using `Restart Point Count`.

---

## 4. Blocked Bloom Filter Format

Tessera utilizes cache-line aligned blocked Bloom filters:
- Filter block length is rounded up to a multiple of 64 bytes (cache line).
- `Trailer Byte` (final byte): Self-describing probe count $k$ ($1 \le k \le 16$).
- Hash function: Double hashing based on 64-bit Wyhash and SipHash combinations:
  $$h_i(x) = (h_1(x) + i \cdot h_2(x)) \pmod m$$
- Evaluates bits with zero false negatives and $< 1\%$ false positive rate at 10 bits per key.
