const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Token = union(enum) {
    eof: void,
    open_paren: void,
    close_paren: void,
    open_bracket: void,
    close_bracket: void,
    open_brace: void,
    close_brace: void,
    set_open: void,
    comma: void,
    quote: void,
    backtick: void,
    deref: void,
    unquote: void,
    unquote_splicing: void,
    string: []const u8,
    number: []const u8,
    symbol: []const u8,
    keyword: []const u8,
    queue_tag: void,
    fn_shorthand: []const u8, // body text of #( ... )

    pub fn deinit(self: Token, allocator: Allocator) void {
        switch (self) {
            .string, .number, .symbol, .keyword, .fn_shorthand => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn clone(self: Token, allocator: Allocator) anyerror!Token {
        return switch (self) {
            .eof => .{ .eof = {} },
            .open_paren => .{ .open_paren = {} },
            .close_paren => .{ .close_paren = {} },
            .open_bracket => .{ .open_bracket = {} },
            .close_bracket => .{ .close_bracket = {} },
            .open_brace => .{ .open_brace = {} },
            .close_brace => .{ .close_brace = {} },
            .set_open => .{ .set_open = {} },
            .comma => .{ .comma = {} },
            .quote => .{ .quote = {} },
            .backtick => .{ .backtick = {} },
            .deref => .{ .deref = {} },
            .unquote => .{ .unquote = {} },
            .unquote_splicing => .{ .unquote_splicing = {} },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .number => |s| .{ .number = try allocator.dupe(u8, s) },
            .symbol => |s| .{ .symbol = try allocator.dupe(u8, s) },
            .keyword => |s| .{ .keyword = try allocator.dupe(u8, s) },
            .queue_tag => .{ .queue_tag = {} },
            .fn_shorthand => |s| .{ .fn_shorthand = try allocator.dupe(u8, s) },
        };
    }
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, input: []const u8) Lexer {
        return .{ .input = input, .pos = 0, .allocator = allocator };
    }

    pub fn nextToken(self: *Lexer) anyerror!Token {
        self.skipWhitespace();
        self.skipComments();

        if (self.pos >= self.input.len) return .{ .eof = {} };

        const ch = self.input[self.pos];

        switch (ch) {
            '(' => { self.pos += 1; return .{ .open_paren = {} }; },
            ')' => { self.pos += 1; return .{ .close_paren = {} }; },
            '[' => { self.pos += 1; return .{ .open_bracket = {} }; },
            ']' => { self.pos += 1; return .{ .close_bracket = {} }; },
            '{' => { self.pos += 1; return .{ .open_brace = {} }; },
            '}' => { self.pos += 1; return .{ .close_brace = {} }; },
            ',' => { self.pos += 1; return .{ .comma = {} }; },
            '\'' => { self.pos += 1; return .{ .quote = {} }; },
            '`' => { self.pos += 1; return .{ .backtick = {} }; },
            '@' => { self.pos += 1; return .{ .deref = {} }; },
            '~' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '@') {
                    self.pos += 1;
                    return .{ .unquote_splicing = {} };
                }
                return .{ .unquote = {} };
            },
            '#' => return self.readDispatch(),
            '"' => return self.readString(),
            else => {
                if (ch == ':' and self.pos + 1 < self.input.len and (std.ascii.isAlphanumeric(self.input[self.pos + 1]) or self.input[self.pos + 1] >= 0x80)) {
                    return self.readKeyword();
                }
                return self.readSymbolOrNumber();
            },
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }

    fn skipComments(self: *Lexer) void {
        while (self.pos < self.input.len and self.input[self.pos] == ';') {
            while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                self.pos += 1;
            }
            self.skipWhitespace();
        }
    }

    fn readString(self: *Lexer) anyerror!Token {
        self.pos += 1; // skip opening quote
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '"') {
                self.pos += 1;
                return .{ .string = try buf.toOwnedSlice(self.allocator) };
            }
            if (ch == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) {
                    return error.UnterminatedString;
                }
                switch (self.input[self.pos]) {
                    'n' => try buf.append(self.allocator, '\n'),
                    't' => try buf.append(self.allocator, '\t'),
                    'r' => try buf.append(self.allocator, '\r'),
                    '\\' => try buf.append(self.allocator, '\\'),
                    '"' => try buf.append(self.allocator, '"'),
                    'u' => {
                        // \uXXXX or \u{XXXXXX} - Unicode escape
                        self.pos += 1;
                        var codepoint: u21 = 0;
                        if (self.pos < self.input.len and self.input[self.pos] == '{') {
                            // \u{XXXXXX} format - read until '}'
                            self.pos += 1; // skip '{'
                            var hex_buf: std.ArrayList(u8) = .empty;
                            defer hex_buf.deinit(self.allocator);
                            while (self.pos < self.input.len and self.input[self.pos] != '}') {
                                if (!std.ascii.isHex(self.input[self.pos])) return error.InvalidUnicodeEscape;
                                try hex_buf.append(self.allocator, self.input[self.pos]);
                                self.pos += 1;
                            }
                            if (self.pos >= self.input.len) return error.InvalidUnicodeEscape;
                            self.pos += 1; // skip '}'
                            codepoint = std.fmt.parseInt(u21, hex_buf.items, 16) catch return error.InvalidUnicodeEscape;
                        } else {
                            // \uXXXX format - exactly 4 hex digits
                            if (self.pos + 4 > self.input.len) return error.InvalidUnicodeEscape;
                            var hex_str: [4]u8 = undefined;
                            var j: usize = 0;
                            while (j < 4) : (j += 1) {
                                if (!std.ascii.isHex(self.input[self.pos])) return error.InvalidUnicodeEscape;
                                hex_str[j] = self.input[self.pos];
                                self.pos += 1;
                            }
                            codepoint = std.fmt.parseInt(u21, &hex_str, 16) catch return error.InvalidUnicodeEscape;
                        }
                        // Encode as UTF-8
                        var utf8_buf: [4]u8 = undefined;
                        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return error.InvalidUnicodeEscape;
                        try buf.appendSlice(self.allocator, utf8_buf[0..utf8_len]);
                        continue; // pos already advanced
                    },
                    else => |c| try buf.append(self.allocator, c),
                }
            } else {
                try buf.append(self.allocator, ch);
            }
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    fn readKeyword(self: *Lexer) anyerror!Token {
        self.pos += 1; // skip ':'
        const start = self.pos;
        while (self.pos < self.input.len and isSymbolChar(self.input[self.pos])) {
            self.pos += 1;
        }
        const result = try self.allocator.dupe(u8, self.input[start..self.pos]);
        return .{ .keyword = result };
    }

    fn readSymbolOrNumber(self: *Lexer) anyerror!Token {
        const start = self.pos;

        // Check if it's a number
        var is_number = true;
        var has_dot = false;
        var i = self.pos;

        if (i < self.input.len and (self.input[i] == '-' or self.input[i] == '+')) {
            i += 1;
        }
        while (i < self.input.len and (std.ascii.isDigit(self.input[i]) or self.input[i] == '.')) {
            if (self.input[i] == '.') {
                if (has_dot) { is_number = false; break; }
                has_dot = true;
            }
            i += 1;
        }

        if (is_number and i > start and i == self.findNumEnd()) {
            const num_str = try self.allocator.dupe(u8, self.input[start..i]);
            self.pos = i;
            return .{ .number = num_str };
        }

        // Read as symbol
        while (self.pos < self.input.len and isSymbolChar(self.input[self.pos])) {
            self.pos += 1;
        }
        const result = try self.allocator.dupe(u8, self.input[start..self.pos]);
        return .{ .symbol = result };
    }

    fn findNumEnd(self: Lexer) usize {
        var i = self.pos;
        while (i < self.input.len and (std.ascii.isDigit(self.input[i]) or self.input[i] == '.')) {
            i += 1;
        }
        return i;
    }

    fn readDispatch(self: *Lexer) anyerror!Token {
        self.pos += 1; // skip '#'
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const ch = self.input[self.pos];
        switch (ch) {
            '{' => { self.pos += 1; return .{ .set_open = {} }; },
            '(' => {
                // #(body) — anonymous function shorthand
                self.pos += 1; // skip '('
                return self.readFnShorthand();
            },
            else => {
                // Check for #queue(...)
                if (std.mem.startsWith(u8, self.input[self.pos..], "queue(")) {
                    self.pos += 6; // skip "queue("
                    return .{ .queue_tag = {} };
                }
                // Otherwise treat # as part of a symbol
                const start = self.pos - 1; // include the '#'
                while (self.pos < self.input.len and isSymbolChar(self.input[self.pos])) {
                    self.pos += 1;
                }
                const result = try self.allocator.dupe(u8, self.input[start..self.pos]);
                return .{ .symbol = result };
            },
        }
    }

    /// Read #(body) anonymous function shorthand.
    /// Returns the body text (between the parens) as a fn_shorthand token.
    fn readFnShorthand(self: *Lexer) anyerror!Token {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        var depth: usize = 1;
        var in_string = false;
        var escape_next = false;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];

            if (escape_next) {
                try buf.append(self.allocator, ch);
                self.pos += 1;
                escape_next = false;
                continue;
            }

            if (ch == '\\' and in_string) {
                try buf.append(self.allocator, ch);
                self.pos += 1;
                escape_next = true;
                continue;
            }

            if (ch == '"') {
                in_string = !in_string;
                try buf.append(self.allocator, ch);
                self.pos += 1;
                continue;
            }

            if (!in_string) {
                if (ch == '(') {
                    depth += 1;
                } else if (ch == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos += 1; // skip closing ')'
                        return .{ .fn_shorthand = try buf.toOwnedSlice(self.allocator) };
                    }
                }
            }

            try buf.append(self.allocator, ch);
            self.pos += 1;
        }

        return error.UnexpectedEof;
    }
};

fn isSymbolChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or
        ch == '-' or ch == '+' or ch == '*' or ch == '/' or
        ch == '<' or ch == '>' or ch == '=' or ch == '!' or
        ch == '?' or ch == '%' or ch == '&' or ch == '^' or
        ch == '.' or ch == '_' or
        // Accept non-ASCII bytes (UTF-8 continuation and start bytes)
        // This allows Unicode characters in symbol names
        ch >= 0x80;
}
