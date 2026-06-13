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
    regex: []const u8, // Regex literal: #"..."
    number: []const u8,
    character: u21, // A single Unicode code point
    symbol: []const u8,
    keyword: []const u8,
    queue_tag: void,
    fn_shorthand: []const u8, // body text of #( ... )

    pub fn deinit(self: Token, allocator: Allocator) void {
        switch (self) {
            .string, .regex, .number, .symbol, .keyword, .fn_shorthand => |s| allocator.free(s),
            .character => {},
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
            .regex => |s| .{ .regex = try allocator.dupe(u8, s) },
            .number => |s| .{ .number = try allocator.dupe(u8, s) },
            .character => |c| .{ .character = c },
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
    token_start: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, input: []const u8) Lexer {
        return .{ .input = input, .pos = 0, .token_start = 0, .allocator = allocator };
    }

    /// Return the 1-based line number at token_start.
    pub fn currentLine(self: *const Lexer) usize {
        var line: usize = 1;
        var i: usize = 0;
        while (i < self.token_start) : (i += 1) {
            if (self.input[i] == '\n') line += 1;
        }
        return line;
    }

    pub fn nextToken(self: *Lexer) anyerror!Token {
        self.skipWhitespace();
        self.skipComments();
        self.token_start = self.pos;

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
            '\\' => return self.readChar(),
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

    /// Read a character literal: \a, \newline, \space, \tab, \return, \formfeed, \uXXXX, \oNNN
    fn readChar(self: *Lexer) anyerror!Token {
        self.pos += 1; // skip '\\'
        if (self.pos >= self.input.len) return error.EofWhileReadingChar;

        // Check for named escapes
        if (std.mem.startsWith(u8, self.input[self.pos..], "newline")) {
            self.pos += 7;
            return .{ .character = 10 };
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "tab")) {
            self.pos += 3;
            return .{ .character = 9 };
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "return")) {
            self.pos += 6;
            return .{ .character = 13 };
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "space")) {
            self.pos += 5;
            return .{ .character = 32 };
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "formfeed")) {
            self.pos += 8;
            return .{ .character = 12 };
        }

        // Check for unicode escape: \uXXXX
        if (self.input[self.pos] == 'u') {
            self.pos += 1; // skip 'u'
            if (self.pos + 4 > self.input.len) return error.InvalidUnicodeChar;
            var hex_str: [4]u8 = undefined;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                if (!std.ascii.isHex(self.input[self.pos])) return error.InvalidUnicodeChar;
                hex_str[i] = self.input[self.pos];
                self.pos += 1;
            }
            const codepoint = std.fmt.parseInt(u21, &hex_str, 16) catch return error.InvalidUnicodeChar;
            // Surrogate check: \uD800-\uDFFF are invalid
            if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return error.InvalidUnicodeChar;
            return .{ .character = codepoint };
        }

        // Check for octal escape: \oNNN (only if followed by octal digits)
        if (self.input[self.pos] == 'o' and
            self.pos + 1 < self.input.len and
            self.input[self.pos + 1] >= '0' and self.input[self.pos + 1] <= '7')
        {
            self.pos += 1; // skip 'o'
            // Read 1-3 octal digits
            var octal_val: u21 = 0;
            var digit_count: usize = 0;
            while (self.pos < self.input.len and digit_count < 3 and self.input[self.pos] >= '0' and self.input[self.pos] <= '7') {
                octal_val = octal_val * 8 + (self.input[self.pos] - '0');
                self.pos += 1;
                digit_count += 1;
            }
            if (octal_val > 0o377) return error.OctalOutOfRange;
            return .{ .character = octal_val };
        }

        // Single character literal: \a (or a multi-byte UTF-8 character)
        const first_byte = self.input[self.pos];
        if (first_byte < 0x80) {
            // ASCII character
            self.pos += 1;
            return .{ .character = first_byte };
        }
        // Multi-byte UTF-8 character: read the full sequence and decode
        const seq_len = std.unicode.utf8ByteSequenceLength(first_byte) catch {
            // Invalid UTF-8 start byte - treat as single byte
            self.pos += 1;
            return .{ .character = first_byte };
        };
        if (self.pos + seq_len > self.input.len) return error.EofWhileReadingChar;
        const cp = std.unicode.utf8Decode(self.input[self.pos .. self.pos + seq_len]) catch {
            // Invalid UTF-8 sequence - read just the first byte
            self.pos += 1;
            return .{ .character = first_byte };
        };
        self.pos += seq_len;
        return .{ .character = cp };
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
        var has_digit = false;
        var i = self.pos;

        if (i < self.input.len and (self.input[i] == '-' or self.input[i] == '+')) {
            i += 1;
        }
        while (i < self.input.len and (std.ascii.isDigit(self.input[i]) or self.input[i] == '.')) {
            if (self.input[i] == '.') {
                if (has_dot) { is_number = false; break; }
                has_dot = true;
            } else {
                has_digit = true;
            }
            i += 1;
        }
        // Check for BigInt suffix 'N' or BigDecimal suffix 'M'
        if (is_number and i < self.input.len and (self.input[i] == 'N' or self.input[i] == 'M')) {
            i += 1;
        }

        if (is_number and has_digit and i > start and i == self.findNumEnd()) {
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
        // Handle optional sign prefix
        if (i < self.input.len and (self.input[i] == '-' or self.input[i] == '+')) {
            i += 1;
        }
        while (i < self.input.len and (std.ascii.isDigit(self.input[i]) or self.input[i] == '.')) {
            i += 1;
        }
        // Include BigInt/BigDecimal suffix
        if (i < self.input.len and (self.input[i] == 'N' or self.input[i] == 'M')) {
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
            '"' => {
                // #"..." — regex literal
                // Read like a string but return as regex token
                self.pos += 1; // skip opening quote
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(self.allocator);

                while (self.pos < self.input.len) {
                    const c = self.input[self.pos];
                    if (c == '"') {
                        self.pos += 1;
                        return .{ .regex = try buf.toOwnedSlice(self.allocator) };
                    }
                    if (c == '\\') {
                        self.pos += 1;
                        if (self.pos >= self.input.len) {
                            return error.UnterminatedRegex;
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
                                var utf8_buf: [4]u8 = undefined;
                                const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return error.InvalidUnicodeEscape;
                                try buf.appendSlice(self.allocator, utf8_buf[0..utf8_len]);
                                continue;
                            },
                            else => |ec| try buf.append(self.allocator, ec),
                        }
                    } else {
                        try buf.append(self.allocator, c);
                    }
                    self.pos += 1;
                }
                return error.UnterminatedRegex;
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
