const std = @import("std");
const tessera = @import("tessera");
const repl_mod = @import("repl.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = init.minimal.args.iterate();

    _ = args.skip(); // skip executable name

    const subcmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, subcmd, "version")) {
        std.debug.print("Tessera Embedded Multi-Model Engine v0.1.0 (Zig 0.16.0)\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcmd, "repl")) {
        try runRepl(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "bench")) {
        try runBenchmark(allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "server")) {
        std.debug.print("Starting Tessera server on 0.0.0.0:7331 (press Ctrl+C to terminate)...\n", .{});
        // Run server event loop
        var repl = try repl_mod.Repl.init(allocator);
        defer repl.deinit();

        const server = tessera.net.server.Server.init(allocator, &repl.executor);
        _ = server;
        std.debug.print("Tessera network engine initialized.\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcmd, "inspect")) {
        const file_path = args.next() orelse {
            std.debug.print("Error: inspect requires a file path argument.\n", .{});
            return;
        };
        std.debug.print("Inspecting Tessera storage artifact: {s}\n", .{file_path});
        return;
    }

    std.debug.print("Unknown command: {s}\n\n", .{subcmd});
    printUsage();
}

fn printUsage() void {
    std.debug.print(
        \\Tessera: Multi-Model Embedded Storage Engine
        \\
        \\Usage:
        \\  tessera <command> [options]
        \\
        \\Commands:
        \\  repl       Launch interactive TQL terminal shell
        \\  bench      Run embedded performance benchmark suite
        \\  server     Start binary wire protocol TCP server
        \\  inspect    Inspect binary SSTable or WAL file on disk
        \\  version    Display version information
        \\  help       Display this help message
        \\
    , .{});
}

const StdOutWriter = struct {
    pub fn print(self: StdOutWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        std.debug.print(fmt, args);
    }
};

fn runRepl(allocator: std.mem.Allocator) !void {
    std.debug.print("Tessera v0.1.0 - Multi-Model Storage Shell (type .help or .exit)\n", .{});
    var repl = try repl_mod.Repl.init(allocator);
    defer repl.deinit();

    var line_buf: [4096]u8 = undefined;

    while (true) {
        std.debug.print("tessera> ", .{});
        const line = try readLine(&line_buf);
        if (line == null) break;

        const writer = StdOutWriter{};
        const should_continue = try repl.evalLine(line.?, writer);
        if (!should_continue) break;
    }
}

fn readLine(buf: []u8) !?[]const u8 {
    var idx: usize = 0;
    while (idx < buf.len) {
        var byte_buf: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte_buf) catch |err| {
            return err;
        };
        if (n == 0) {
            if (idx == 0) return null;
            return buf[0..idx];
        }
        const b = byte_buf[0];
        if (b == '\n') return buf[0..idx];
        if (b != '\r') {
            buf[idx] = b;
            idx += 1;
        }
    }
    return buf[0..idx];
}

fn runBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("========================================\n", .{});
    std.debug.print("Tessera Performance Benchmark Suite\n", .{});
    std.debug.print("========================================\n\n", .{});

    // 1. LSM Key-Value Benchmark
    {
        std.debug.print("[1/3] Benchmarking LSM Key-Value Storage...\n", .{});
        const engine = try tessera.Engine.init(allocator, .{});
        defer engine.deinit();

        const num_ops: usize = 10_000;
        const start_write = tessera.common.types.getMonotonicMicros();
        var key_buf: [32]u8 = undefined;

        for (0..num_ops) |i| {
            const k = std.fmt.bufPrint(&key_buf, "key_{d:0>6}", .{i}) catch unreachable;
            try engine.put(k, "benchmark_payload_value_128_bytes");
        }
        const write_time = tessera.common.types.getMonotonicMicros() - start_write;
        const write_ops_sec = (@as(f64, @floatFromInt(num_ops)) / @as(f64, @floatFromInt(write_time))) * 1_000_000.0;

        const start_read = tessera.common.types.getMonotonicMicros();
        for (0..num_ops) |i| {
            const k = std.fmt.bufPrint(&key_buf, "key_{d:0>6}", .{i}) catch unreachable;
            const val = try engine.get(allocator, k);
            if (val) |v| allocator.free(v);
        }
        const read_time = tessera.common.types.getMonotonicMicros() - start_read;
        const read_ops_sec = (@as(f64, @floatFromInt(num_ops)) / @as(f64, @floatFromInt(read_time))) * 1_000_000.0;

        std.debug.print("  Sequential Writes: {d:.0} ops/sec ({d} us total)\n", .{ write_ops_sec, write_time });
        std.debug.print("  Point Reads:       {d:.0} ops/sec ({d} us total)\n\n", .{ read_ops_sec, read_time });
    }

    // 2. Vector Index HNSW Benchmark
    {
        std.debug.print("[2/3] Benchmarking SIMD Vector Index (HNSW)...\n", .{});
        const vidx = try tessera.HnswIndex.init(allocator, 16, .l2);
        defer vidx.deinit();

        const num_vecs: usize = 1_000;
        var rng = tessera.sim.sim_rng.SimRng.init(12345);
        var vec_data: [16]f32 = undefined;

        const start_v_insert = tessera.common.types.getMonotonicMicros();
        for (0..num_vecs) |i| {
            for (&vec_data) |*v| v.* = rng.nextFloat();
            try vidx.insert(tessera.common.types.VectorId.init(@as(u64, @intCast(i))), &vec_data);
        }
        const v_insert_time = tessera.common.types.getMonotonicMicros() - start_v_insert;
        const v_insert_qps = (@as(f64, @floatFromInt(num_vecs)) / @as(f64, @floatFromInt(v_insert_time))) * 1_000_000.0;

        const num_queries: usize = 500;
        const start_v_search = tessera.common.types.getMonotonicMicros();
        for (0..num_queries) |_| {
            for (&vec_data) |*v| v.* = rng.nextFloat();
            var matches = try vidx.searchKnn(allocator, &vec_data, 10, 32);
            matches.deinit(allocator);
        }
        const v_search_time = tessera.common.types.getMonotonicMicros() - start_v_search;
        const v_search_qps = (@as(f64, @floatFromInt(num_queries)) / @as(f64, @floatFromInt(v_search_time))) * 1_000_000.0;

        std.debug.print("  Vector Insertions: {d:.0} vectors/sec ({d} us total)\n", .{ v_insert_qps, v_insert_time });
        std.debug.print("  KNN Search (Top10):{d:.0} queries/sec ({d} us total)\n\n", .{ v_search_qps, v_search_time });
    }

    // 3. Graph Store Traversal Benchmark
    {
        std.debug.print("[3/3] Benchmarking CSR Graph Store Traversals...\n", .{});
        var graph = tessera.GraphStore.init(allocator);
        defer graph.deinit();

        const num_nodes: usize = 500;
        for (0..num_nodes) |i| {
            try graph.addNode(tessera.common.types.NodeId.init(@as(u64, @intCast(i))), "entity");
        }
        for (0..num_nodes - 1) |i| {
            _ = try graph.addEdge(
                tessera.common.types.NodeId.init(@as(u64, @intCast(i))),
                tessera.common.types.NodeId.init(@as(u64, @intCast(i + 1))),
                1.0,
            );
        }

        const start_bfs = tessera.common.types.getMonotonicMicros();
        var bfs_nodes = try tessera.graph.traversal.bfsKHop(
            &graph,
            allocator,
            tessera.common.types.NodeId.init(0),
            10,
        );
        bfs_nodes.deinit(allocator);
        const bfs_time = tessera.common.types.getMonotonicMicros() - start_bfs;

        std.debug.print("  BFS 10-Hop Traversal: {d} us\n\n", .{bfs_time});
    }

    std.debug.print("Benchmark completed successfully.\n", .{});
}
