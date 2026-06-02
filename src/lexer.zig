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
    comma: void,
    quote: void,
    string: []const u8,
    number: []const u8,
    symbol: []const u8,
    keyword: []const u8,

    pub fn deinit(self: Token, allocator: Allocator) void {
        switch (self) {
            .string, .number, .symbol, .keyword => |s| allocator.free(s),
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
            .comma => .{ .comma = {} },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .number => |s| .{ .number = try allocator.dupe(u8, s) },
            .symbol => |s| .{ .symbol = try allocator.dupe(u8, s) },
            .keyword => |s| .{ .keyword = try allocator.dupe(u8, s) },
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
            '"' => return self.readString(),
            else => {
                if (ch == ':' and self.pos + 1 < self.input.len and std.ascii.isAlphanumeric(self.input[self.pos + 1])) {
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
};

fn isSymbolChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or
        ch == '-' or ch == '+' or ch == '*' or ch == '/' or
        ch == '<' or ch == '>' or ch == '=' or ch == '!' or
        ch == '?' or ch == '%' or ch == '&' or ch == '^' or
        ch == '.' or ch == '@';
}
