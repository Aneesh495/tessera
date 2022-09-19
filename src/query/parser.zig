const std = @import("std");
const types = @import("../common/types.zig");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const TokenTag = lexer_mod.TokenTag;
const Token = lexer_mod.Token;

/// Recursive descent parser for the Tessera Query Language (TQL).
pub const Parser = struct {
    lexer: lexer_mod.Lexer,
    current_token: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var l = lexer_mod.Lexer.init(source);
        const first = l.next();
        return .{
            .lexer = l,
            .current_token = first,
            .allocator = allocator,
        };
    }

    fn consume(self: *Parser, expected: TokenTag) !Token {
        if (self.current_token.tag != expected) {
            return error.SyntaxError;
        }
        const tok = self.current_token;
        self.current_token = self.lexer.next();
        return tok;
    }

    fn advance(self: *Parser) Token {
        const tok = self.current_token;
        self.current_token = self.lexer.next();
        return tok;
    }

    fn parseVectorElements(self: *Parser) !std.ArrayList(f32) {
        _ = try self.consume(.l_bracket);
        var elements = std.ArrayList(f32).empty;
        errdefer elements.deinit(self.allocator);

        while (self.current_token.tag != .r_bracket and self.current_token.tag != .eof) {
            const num_tok = try self.consume(.number);
            const val = std.fmt.parseFloat(f32, num_tok.slice) catch return error.SyntaxError;
            try elements.append(self.allocator, val);

            if (self.current_token.tag == .comma) {
                _ = self.advance();
            } else {
                break;
            }
        }

        _ = try self.consume(.r_bracket);
        return elements;
    }

    /// Parse next statement from the query string.
    pub fn parseStatement(self: *Parser) !ast.Statement {
        switch (self.current_token.tag) {
            .kw_get => {
                _ = self.advance();
                const key_tok = self.advance();
                if (key_tok.tag != .identifier and key_tok.tag != .string_literal) return error.SyntaxError;
                return ast.Statement{ .get = .{ .key = key_tok.slice } };
            },
            .kw_put => {
                _ = self.advance();
                const key_tok = self.advance();
                if (key_tok.tag != .identifier and key_tok.tag != .string_literal) return error.SyntaxError;
                const val_tok = self.advance();
                if (val_tok.tag != .identifier and val_tok.tag != .string_literal and val_tok.tag != .number) return error.SyntaxError;
                return ast.Statement{ .put = .{ .key = key_tok.slice, .value = val_tok.slice } };
            },
            .kw_delete => {
                _ = self.advance();
                const key_tok = self.advance();
                if (key_tok.tag != .identifier and key_tok.tag != .string_literal) return error.SyntaxError;
                return ast.Statement{ .delete = .{ .key = key_tok.slice } };
            },
            .kw_scan => {
                _ = self.advance();
                const start_tok = self.advance();
                const end_tok = self.advance();
                var limit: usize = 100;
                if (self.current_token.tag == .kw_limit) {
                    _ = self.advance();
                    const lim_tok = try self.consume(.number);
                    limit = std.fmt.parseInt(usize, lim_tok.slice, 10) catch return error.SyntaxError;
                }
                return ast.Statement{ .scan = .{
                    .start_key = start_tok.slice,
                    .end_key = end_tok.slice,
                    .limit = limit,
                } };
            },
            .kw_vec_insert => {
                _ = self.advance();
                const id_tok = try self.consume(.number);
                const id_num = std.fmt.parseInt(u64, id_tok.slice, 10) catch return error.SyntaxError;
                const elems = try self.parseVectorElements();
                return ast.Statement{ .vec_insert = .{
                    .id = types.VectorId.init(id_num),
                    .elements = elems,
                } };
            },
            .kw_vec_search => {
                _ = self.advance();
                const query_vec = try self.parseVectorElements();
                var top_k: usize = 10;
                var ef_search: usize = 32;

                if (self.current_token.tag == .kw_top) {
                    _ = self.advance();
                    const top_tok = try self.consume(.number);
                    top_k = std.fmt.parseInt(usize, top_tok.slice, 10) catch return error.SyntaxError;
                }
                if (self.current_token.tag == .kw_ef) {
                    _ = self.advance();
                    const ef_tok = try self.consume(.number);
                    ef_search = std.fmt.parseInt(usize, ef_tok.slice, 10) catch return error.SyntaxError;
                }

                return ast.Statement{ .vec_search = .{
                    .query = query_vec,
                    .top_k = top_k,
                    .ef_search = ef_search,
                } };
            },
            .kw_graph_add_node => {
                _ = self.advance();
                const id_tok = try self.consume(.number);
                const id_num = std.fmt.parseInt(u64, id_tok.slice, 10) catch return error.SyntaxError;
                var prop: []const u8 = "";
                if (self.current_token.tag == .string_literal or self.current_token.tag == .identifier) {
                    prop = self.advance().slice;
                }
                return ast.Statement{ .graph_add_node = .{
                    .id = types.NodeId.init(id_num),
                    .property = prop,
                } };
            },
            .kw_graph_add_edge => {
                _ = self.advance();
                const src_tok = try self.consume(.number);
                const dst_tok = try self.consume(.number);
                const src_id = std.fmt.parseInt(u64, src_tok.slice, 10) catch return error.SyntaxError;
                const dst_id = std.fmt.parseInt(u64, dst_tok.slice, 10) catch return error.SyntaxError;
                var weight: f32 = 1.0;
                if (self.current_token.tag == .number) {
                    const w_tok = self.advance();
                    weight = std.fmt.parseFloat(f32, w_tok.slice) catch return error.SyntaxError;
                }
                return ast.Statement{ .graph_add_edge = .{
                    .source = types.NodeId.init(src_id),
                    .target = types.NodeId.init(dst_id),
                    .weight = weight,
                } };
            },
            .kw_graph_shortest_path => {
                _ = self.advance();
                const src_tok = try self.consume(.number);
                const dst_tok = try self.consume(.number);
                const src_id = std.fmt.parseInt(u64, src_tok.slice, 10) catch return error.SyntaxError;
                const dst_id = std.fmt.parseInt(u64, dst_tok.slice, 10) catch return error.SyntaxError;
                return ast.Statement{ .graph_shortest_path = .{
                    .source = types.NodeId.init(src_id),
                    .target = types.NodeId.init(dst_id),
                } };
            },
            .kw_graph_neighbors => {
                _ = self.advance();
                const id_tok = try self.consume(.number);
                const id_num = std.fmt.parseInt(u64, id_tok.slice, 10) catch return error.SyntaxError;
                var hops: usize = 1;
                if (self.current_token.tag == .kw_hops) {
                    _ = self.advance();
                    const hops_tok = try self.consume(.number);
                    hops = std.fmt.parseInt(usize, hops_tok.slice, 10) catch return error.SyntaxError;
                }
                return ast.Statement{ .graph_neighbors = .{
                    .id = types.NodeId.init(id_num),
                    .hops = hops,
                } };
            },
            .kw_hybrid_search => {
                _ = self.advance();
                const seed_tok = try self.consume(.number);
                const hops_tok = try self.consume(.number);
                const seed_id = std.fmt.parseInt(u64, seed_tok.slice, 10) catch return error.SyntaxError;
                const hops_cnt = std.fmt.parseInt(usize, hops_tok.slice, 10) catch return error.SyntaxError;

                const query_vec = try self.parseVectorElements();
                var top_k: usize = 5;
                var alpha: f32 = 0.7;

                if (self.current_token.tag == .kw_top) {
                    _ = self.advance();
                    const top_tok = try self.consume(.number);
                    top_k = std.fmt.parseInt(usize, top_tok.slice, 10) catch return error.SyntaxError;
                }
                if (self.current_token.tag == .kw_alpha) {
                    _ = self.advance();
                    const a_tok = try self.consume(.number);
                    alpha = std.fmt.parseFloat(f32, a_tok.slice) catch return error.SyntaxError;
                }

                return ast.Statement{ .hybrid_search = .{
                    .seed = types.NodeId.init(seed_id),
                    .hops = hops_cnt,
                    .query = query_vec,
                    .top_k = top_k,
                    .alpha = alpha,
                } };
            },
            .kw_begin => {
                _ = self.advance();
                return ast.Statement{ .begin = {} };
            },
            .kw_commit => {
                _ = self.advance();
                return ast.Statement{ .commit = {} };
            },
            .kw_rollback => {
                _ = self.advance();
                return ast.Statement{ .rollback = {} };
            },
            else => return error.SyntaxError,
        }
    }
};

test "tql parser parses multi-model statements" {
    const allocator = std.testing.allocator;

    // Test GET statement
    var p1 = Parser.init(allocator, "GET account:999");
    var s1 = try p1.parseStatement();
    defer s1.deinit(allocator);
    try std.testing.expectEqualStrings("account:999", s1.get.key);

    // Test PUT statement
    var p2 = Parser.init(allocator, "PUT user:1 \"Alice\"");
    var s2 = try p2.parseStatement();
    defer s2.deinit(allocator);
    try std.testing.expectEqualStrings("user:1", s2.put.key);
    try std.testing.expectEqualStrings("Alice", s2.put.value);

    // Test VEC_SEARCH statement
    var p3 = Parser.init(allocator, "VEC_SEARCH [0.1, 0.2, 0.3] TOP 5 EF 16");
    var s3 = try p3.parseStatement();
    defer s3.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), s3.vec_search.query.items.len);
    try std.testing.expectEqual(@as(usize, 5), s3.vec_search.top_k);
    try std.testing.expectEqual(@as(usize, 16), s3.vec_search.ef_search);

    // Test GRAPH_ADD_EDGE statement
    var p4 = Parser.init(allocator, "GRAPH_ADD_EDGE 10 20 2.5");
    var s4 = try p4.parseStatement();
    defer s4.deinit(allocator);
    try std.testing.expectEqual(types.NodeId.init(10), s4.graph_add_edge.source);
    try std.testing.expectEqual(types.NodeId.init(20), s4.graph_add_edge.target);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), s4.graph_add_edge.weight, 1e-5);
}
