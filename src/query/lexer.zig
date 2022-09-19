const std = @import("std");

pub const TokenTag = enum {
    // Keywords
    kw_get,
    kw_put,
    kw_delete,
    kw_scan,
    kw_vec_insert,
    kw_vec_search,
    kw_graph_add_node,
    kw_graph_add_edge,
    kw_graph_shortest_path,
    kw_graph_neighbors,
    kw_hybrid_search,
    kw_top,
    kw_limit,
    kw_hops,
    kw_ef,
    kw_alpha,
    kw_begin,
    kw_commit,
    kw_rollback,

    // Literals & Identifiers
    identifier,
    string_literal,
    number,

    // Symbols
    l_bracket,
    r_bracket,
    comma,
    colon,

    eof,
    invalid,
};

pub const Token = struct {
    tag: TokenTag,
    slice: []const u8,
    line: usize,
    col: usize,
};

/// Zero-allocation lexical analyzer for TQL.
pub const Lexer = struct {
    source: []const u8,
    cursor: usize = 0,
    line: usize = 1,
    col: usize = 1,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .cursor = 0,
            .line = 1,
            .col = 1,
        };
    }

    fn peek(self: Lexer) ?u8 {
        if (self.cursor >= self.source.len) return null;
        return self.source[self.cursor];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.cursor >= self.source.len) return null;
        const c = self.source[self.cursor];
        self.cursor += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.peek()) |c| {
            if (std.ascii.isWhitespace(c)) {
                _ = self.advance();
            } else if (c == '#' or (c == '-' and self.cursor + 1 < self.source.len and self.source[self.cursor + 1] == '-')) {
                // Skip comment line
                while (self.peek()) |ch| {
                    _ = self.advance();
                    if (ch == '\n') break;
                }
            } else {
                break;
            }
        }
    }

    /// Read next token from input stream.
    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        const start_line = self.line;
        const start_col = self.col;
        const start_idx = self.cursor;

        const c = self.peek() orelse return Token{
            .tag = .eof,
            .slice = "",
            .line = start_line,
            .col = start_col,
        };

        // Symbols
        if (c == '[') {
            _ = self.advance();
            return Token{ .tag = .l_bracket, .slice = self.source[start_idx..self.cursor], .line = start_line, .col = start_col };
        }
        if (c == ']') {
            _ = self.advance();
            return Token{ .tag = .r_bracket, .slice = self.source[start_idx..self.cursor], .line = start_line, .col = start_col };
        }
        if (c == ',') {
            _ = self.advance();
            return Token{ .tag = .comma, .slice = self.source[start_idx..self.cursor], .line = start_line, .col = start_col };
        }
        if (c == ':') {
            _ = self.advance();
            return Token{ .tag = .colon, .slice = self.source[start_idx..self.cursor], .line = start_line, .col = start_col };
        }

        // Quoted string literal
        if (c == '"' or c == '\'') {
            const quote = self.advance().?;
            const str_start = self.cursor;
            while (self.peek()) |ch| {
                if (ch == '\\') {
                    _ = self.advance();
                    _ = self.advance();
                    continue;
                }
                if (ch == quote) {
                    const str_slice = self.source[str_start..self.cursor];
                    _ = self.advance();
                    return Token{
                        .tag = .string_literal,
                        .slice = str_slice,
                        .line = start_line,
                        .col = start_col,
                    };
                }
                _ = self.advance();
            }
            return Token{ .tag = .invalid, .slice = self.source[start_idx..self.cursor], .line = start_line, .col = start_col };
        }

        // Numbers (positive or negative, int or float)
        if (std.ascii.isDigit(c) or (c == '-' and self.cursor + 1 < self.source.len and std.ascii.isDigit(self.source[self.cursor + 1]))) {
            _ = self.advance();
            while (self.peek()) |ch| {
                if (std.ascii.isDigit(ch) or ch == '.') {
                    _ = self.advance();
                } else {
                    break;
                }
            }
            return Token{
                .tag = .number,
                .slice = self.source[start_idx..self.cursor],
                .line = start_line,
                .col = start_col,
            };
        }

        // Identifiers & Keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.peek()) |ch| {
                if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == ':' or ch == '-' or ch == '.') {
                    _ = self.advance();
                } else {
                    break;
                }
            }
            const ident = self.source[start_idx..self.cursor];

            // Match keywords (case-insensitive)
            if (std.ascii.eqlIgnoreCase(ident, "GET")) return Token{ .tag = .kw_get, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "PUT")) return Token{ .tag = .kw_put, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "DELETE")) return Token{ .tag = .kw_delete, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "SCAN")) return Token{ .tag = .kw_scan, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "VEC_INSERT")) return Token{ .tag = .kw_vec_insert, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "VEC_SEARCH")) return Token{ .tag = .kw_vec_search, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "GRAPH_ADD_NODE")) return Token{ .tag = .kw_graph_add_node, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "GRAPH_ADD_EDGE")) return Token{ .tag = .kw_graph_add_edge, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "GRAPH_SHORTEST_PATH")) return Token{ .tag = .kw_graph_shortest_path, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "GRAPH_NEIGHBORS")) return Token{ .tag = .kw_graph_neighbors, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "HYBRID_SEARCH")) return Token{ .tag = .kw_hybrid_search, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "TOP")) return Token{ .tag = .kw_top, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "LIMIT")) return Token{ .tag = .kw_limit, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "HOPS")) return Token{ .tag = .kw_hops, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "EF")) return Token{ .tag = .kw_ef, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "ALPHA")) return Token{ .tag = .kw_alpha, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "BEGIN")) return Token{ .tag = .kw_begin, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "COMMIT")) return Token{ .tag = .kw_commit, .slice = ident, .line = start_line, .col = start_col };
            if (std.ascii.eqlIgnoreCase(ident, "ROLLBACK")) return Token{ .tag = .kw_rollback, .slice = ident, .line = start_line, .col = start_col };

            return Token{ .tag = .identifier, .slice = ident, .line = start_line, .col = start_col };
        }

        // Unknown character
        _ = self.advance();
        return Token{ .tag = .invalid, .slice = self.source[start_idx..self.cursor], .line = start_line, .col = start_col };
    }
};

test "lexer tokenization of tql statements" {
    const input = "PUT user:1001 \"{\\\"name\\\":\\\"alice\\\"}\"\nVEC_SEARCH [0.1, -0.2, 3.5] TOP 10 EF 64";
    var lexer = Lexer.init(input);

    const t1 = lexer.next();
    try std.testing.expectEqual(TokenTag.kw_put, t1.tag);

    const t2 = lexer.next();
    try std.testing.expectEqual(TokenTag.identifier, t2.tag);
    try std.testing.expectEqualStrings("user:1001", t2.slice);

    const t3 = lexer.next();
    try std.testing.expectEqual(TokenTag.string_literal, t3.tag);

    const t4 = lexer.next();
    try std.testing.expectEqual(TokenTag.kw_vec_search, t4.tag);

    const t5 = lexer.next();
    try std.testing.expectEqual(TokenTag.l_bracket, t5.tag);

    const t6 = lexer.next();
    try std.testing.expectEqual(TokenTag.number, t6.tag);
    try std.testing.expectEqualStrings("0.1", t6.slice);
}
