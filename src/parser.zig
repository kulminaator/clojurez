const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("lexer.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    UnmatchedParenthesis,
    UnmatchedBracket,
};

pub const Parser = struct {
    lexer: Lexer,
    current: Token = .{ .eof = {} },
    allocator: Allocator,

    pub fn init(allocator: Allocator, input: []const u8) anyerror!Parser {
        var lexer = Lexer.init(allocator, input);
        const first_token = try lexer.nextToken();
        const parser: Parser = .{
            .lexer = lexer,
            .current = first_token,
            .allocator = allocator,
        };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.current.deinit(self.allocator);
    }

    pub fn parse(self: *Parser) anyerror!Value {
        return self.readForm();
    }

    pub fn parseAll(self: *Parser) anyerror!list.List {
        var results = list.empty();
        errdefer results.deinit(self.allocator);

        while (true) {
            switch (self.current) {
                .eof => break,
                .close_paren, .close_bracket => break,
                else => {},
            }
            const form = try self.parse();
            try results.append(self.allocator, form);
        }

        return results;
    }

    fn advance(self: *Parser) anyerror!void {
        self.current.deinit(self.allocator);
        self.current = try self.lexer.nextToken();
    }

    fn readForm(self: *Parser) anyerror!Value {
        return switch (self.current) {
            .eof => return error.UnexpectedEof,
            .close_paren => return error.UnmatchedParenthesis,
            .close_bracket => return error.UnmatchedBracket,
            .open_paren => return self.readList(),
            .open_bracket => return self.readVector(),
            .open_brace => return self.readMap(),
            .set_open => return self.readSet(),
            .queue_tag => return self.readQueue(),
            .quote => {
                // 'x is shorthand for (quote x)
                self.current.deinit(self.allocator);
                try self.advance();
                const form = try self.readForm();
                var quoted: list.List = .empty;
                errdefer quoted.deinit(self.allocator);
                try quoted.append(self.allocator, try self.symValue("quote"));
                try quoted.append(self.allocator, form);
                return Value.listValue(quoted);
            },
            .string => |s| {
                const val = try Value.stringValue(self.allocator, s);
                self.current.deinit(self.allocator);
                try self.advance();
                return val;
            },
            .number => |s| {
                const val = try self.parseNumber(s);
                self.current.deinit(self.allocator);
                try self.advance();
                return val;
            },
            .symbol => |s| {
                const val = try self.parseSymbol(s);
                self.current.deinit(self.allocator);
                try self.advance();
                return val;
            },
            .keyword => |s| {
                const val = try Value.keywordValue(self.allocator, s);
                self.current.deinit(self.allocator);
                try self.advance();
                return val;
            },
            else => {
                self.current.deinit(self.allocator);
                try self.advance();
                return try self.readForm();
            },
        };
    }

    fn readList(self: *Parser) anyerror!Value {
        try self.advance(); // consume '('
        var items = list.empty();
        errdefer items.deinit(self.allocator);

        while (true) {
            switch (self.current) {
                .close_paren => {
                    try self.advance();
                    return Value.listValue(items);
                },
                .eof => return error.UnexpectedEof,
                else => {},
            }
            const form = try self.readForm();
            try items.append(self.allocator, form);
        }
    }

    fn readVector(self: *Parser) anyerror!Value {
        try self.advance(); // consume '['
        var items = vec.empty();
        errdefer items.deinit(self.allocator);

        while (true) {
            switch (self.current) {
                .close_bracket => {
                    try self.advance();
                    return Value.vectorValue(items);
                },
                .eof => return error.UnexpectedEof,
                .comma => {
                    try self.advance();
                    continue;
                },
                else => {},
            }
            const form = try self.readForm();
            try items.append(self.allocator, form);
        }
    }

    fn readMap(self: *Parser) anyerror!Value {
        try self.advance(); // consume '{'
        var entries: Value.Map = .empty;
        errdefer {
            for (entries.items) |*entry| {
                entry.key.deinit(self.allocator);
                entry.value.deinit(self.allocator);
            }
            self.allocator.free(entries.items);
        }

        while (true) {
            switch (self.current) {
                .close_brace => {
                    try self.advance();
                    return Value.mapValue(entries);
                },
                .eof => return error.UnexpectedEof,
                .comma => {
                    try self.advance();
                    continue;
                },
                else => {},
            }
            const key = try self.readForm();
            const value = try self.readForm();
            try entries.append(self.allocator, .{ .key = key, .value = value });
        }
    }

    fn readSet(self: *Parser) anyerror!Value {
        try self.advance(); // consume 'set_open' (which already consumed '#{')
        var items: Value.Set = .empty;
        errdefer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(items.items);
        }

        while (true) {
            switch (self.current) {
                .close_brace => {
                    try self.advance();
                    return Value.setValue(items);
                },
                .eof => return error.UnexpectedEof,
                .comma => {
                    try self.advance();
                    continue;
                },
                else => {},
            }
            var item = try self.readForm();
            // Check for duplicates (sets don't allow them)
            var found = false;
            for (items.items) |existing| {
                if (existing.equals(item)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try items.append(self.allocator, item);
            } else {
                item.deinit(self.allocator);
            }
        }
    }

    fn readQueue(self: *Parser) anyerror!Value {
        try self.advance(); // consume 'queue_tag' (which already consumed '#queue(')
        var items: Value.Queue = .empty;
        errdefer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(items.items);
        }

        while (true) {
            switch (self.current) {
                .close_paren => {
                    try self.advance();
                    return Value.queueValue(items);
                },
                .eof => return error.UnexpectedEof,
                .comma => {
                    try self.advance();
                    continue;
                },
                else => {},
            }
            const item = try self.readForm();
            try items.append(self.allocator, item);
        }
    }

    fn parseNumber(_: *Parser, s: []const u8) anyerror!Value {
        if (std.mem.indexOfScalar(u8, s, '.')) |_| {
            const f = try std.fmt.parseFloat(f64, s);
            return Value.floatValue(f);
        } else {
            const i = try std.fmt.parseInt(i64, s, 10);
            return Value.intValue(i);
        }
    }

    fn symValue(self: *Parser, s: []const u8) anyerror!Value {
        var tmp_buf: [256]u8 = undefined;
        const copy_len = if (s.len < tmp_buf.len) s.len else tmp_buf.len;
        @memcpy(tmp_buf[0..copy_len], s[0..copy_len]);
        const duped = try self.allocator.dupe(u8, tmp_buf[0..copy_len]);
        return .{ .type = .symbol, .sym_val = duped };
    }

    fn parseSymbol(self: *Parser, s: []const u8) anyerror!Value {
        // Handle special literal symbols
        if (std.mem.eql(u8, s, "true")) return Value.boolValue(true);
        if (std.mem.eql(u8, s, "false")) return Value.boolValue(false);
        if (std.mem.eql(u8, s, "nil")) return Value.nilValue();
        // Copy via stack buffer to avoid aliasing with brk_allocator
        var tmp_buf: [256]u8 = undefined;
        const copy_len = if (s.len < tmp_buf.len) s.len else tmp_buf.len;
        @memcpy(tmp_buf[0..copy_len], s[0..copy_len]);
        const duped = try self.allocator.dupe(u8, tmp_buf[0..copy_len]);
        if (s.len > tmp_buf.len) {
            // For very long symbols, do a two-step copy
            const extra = try self.allocator.alloc(u8, s.len - copy_len);
            @memcpy(extra, s[copy_len..]);
            const full = try self.allocator.alloc(u8, s.len);
            @memcpy(full[0..copy_len], tmp_buf[0..copy_len]);
            @memcpy(full[copy_len..], extra);
            self.allocator.free(extra);
            return .{ .type = .symbol, .sym_val = full };
        }
        return .{ .type = .symbol, .sym_val = duped };
    }
};

test "parser: empty list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "()");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .list);
    try std.testing.expect(form.list_val.items.len == 0);
}

test "parser: simple list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "(+ 1 2)");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .list);
    try std.testing.expect(form.list_val.items.len == 3);
}

test "parser: nested list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "((+ 1 2) 3)");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .list);
    try std.testing.expect(form.list_val.items.len == 2);
}

test "parser: vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "[1 2 3]");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .vector);
    try std.testing.expect(form.vec_val.items.len == 3);
}

test "parser: string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "\"hello\"");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .string);
    try std.testing.expect(std.mem.eql(u8, form.str_val, "hello"));
}

test "parser: keyword" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, ":foo");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, form.kw_val, "foo"));
}

test "parser: integer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "42");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .integer);
    try std.testing.expect(form.int_val == 42);
}

test "parser: float" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "3.14");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .float);
}

test "parser: booleans" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "true");
    defer p.deinit();
    var form = try p.parse();
    defer form.deinit(allocator);
    try std.testing.expect(form.type == .bool);
    try std.testing.expect(form.bool_val == true);

    var p2 = try Parser.init(allocator, "false");
    defer p2.deinit();
    var form2 = try p2.parse();
    defer form2.deinit(allocator);
    try std.testing.expect(form2.type == .bool);
    try std.testing.expect(form2.bool_val == false);
}

test "parser: nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.brk_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "nil");
    defer p.deinit();
    var form = try p.parse();
    defer form.deinit(allocator);
    try std.testing.expect(form.type == .nil);
}
