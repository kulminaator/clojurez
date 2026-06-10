const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("lexer.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const BI = @import("big_int.zig");
const BD = @import("big_decimal.zig");

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
    // Fn shorthand mode: when true, % symbols are intercepted
    fn_shorthand_args: ?*FnShorthandArgs = null,

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

    /// Return the number of bytes consumed from the input so far.
    /// Returns the start position of the current (lookahead) token,
    /// which is exactly where the previously parsed form ended.
    pub fn consumed(self: *const Parser) usize {
        return self.lexer.token_start;
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
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var quoted: list.List = .empty;
                errdefer quoted.deinit(self.allocator);
                try quoted.append(self.allocator, try self.symValue("quote"));
                try quoted.append(self.allocator, form);
                return Value.listValue(quoted);
            },
            .backtick => {
                // `x is shorthand for (quasiquote x)
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var qq: list.List = .empty;
                errdefer qq.deinit(self.allocator);
                try qq.append(self.allocator, try self.symValue("quasiquote"));
                try qq.append(self.allocator, form);
                return Value.listValue(qq);
            },
            .deref => {
                // @x is shorthand for (deref x)
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var deref_list: list.List = .empty;
                errdefer deref_list.deinit(self.allocator);
                try deref_list.append(self.allocator, try self.symValue("deref"));
                try deref_list.append(self.allocator, form);
                return Value.listValue(deref_list);
            },
            .unquote => {
                // ~x is shorthand for (unquote x)
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var uq: list.List = .empty;
                errdefer uq.deinit(self.allocator);
                try uq.append(self.allocator, try self.symValue("unquote"));
                try uq.append(self.allocator, form);
                return Value.listValue(uq);
            },
            .unquote_splicing => {
                // ~@x is shorthand for (unquote-splicing x)
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var uqs: list.List = .empty;
                errdefer uqs.deinit(self.allocator);
                try uqs.append(self.allocator, try self.symValue("unquote-splicing"));
                try uqs.append(self.allocator, form);
                return Value.listValue(uqs);
            },
            .string => |s| {
                const val = try Value.stringValue(self.allocator, s);
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                return val;
            },
            .number => |s| {
                const val = try self.parseNumber(s);
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                return val;
            },
            .symbol => |s| {
                const val = try self.parseSymbol(s);
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                return val;
            },
            .keyword => |s| {
                const val = try Value.keywordValue(self.allocator, s);
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                return val;
            },
            .fn_shorthand => |body_text| {
                // Parse body with arg tracking: intercept % symbols during parsing
                const val = try self.readFnShorthand(body_text);
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                return val;
            },
            else => {
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
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

    fn parseNumber(self: *Parser, s: []const u8) anyerror!Value {
        const allocator = self.allocator;
        // Check for BigDecimal suffix 'M' (e.g., "123.456M")
        if (s.len > 1 and s[s.len - 1] == 'M') {
            const bd = try BD.BigDecimal.fromString(allocator, s[0 .. s.len - 1]);
            return try Value.decimalValue(allocator, bd);
        }
        // Check for BigInt suffix 'N' (e.g., "12345678901234567890N")
        if (s.len > 1 and s[s.len - 1] == 'N') {
            const bi = try BI.bigIntFromString(allocator, s[0 .. s.len - 1]);
            return try Value.bigIntValue(allocator, bi);
        }
        // Check for float (contains '.')
        if (std.mem.indexOfScalar(u8, s, '.')) |_| {
            const f = try std.fmt.parseFloat(f64, s);
            return Value.floatValue(f);
        }
        // Try to parse as i64
        if (std.fmt.parseInt(i64, s, 10)) |i| {
            return Value.intValue(i);
        } else |_| {
            // Overflow: parse as BigInt
            const bi = try BI.bigIntFromString(allocator, s);
            return try Value.bigIntValue(allocator, bi);
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
        // In fn shorthand mode, intercept % symbols
        if (self.fn_shorthand_args) |args| {
            if (s.len > 0 and s[0] == '%') {
                return args.registerArg(self.allocator, s);
            }
        }
        // Handle special literal symbols
        if (std.mem.eql(u8, s, "true")) return Value.boolValue(true);
        if (std.mem.eql(u8, s, "false")) return Value.boolValue(false);
        if (std.mem.eql(u8, s, "nil")) return Value.nilValue();
        // Copy via stack buffer to avoid aliasing with page_allocator
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

    /// Expand #(body) shorthand into (fn [params] body).
    /// Parses body with arg tracking: % symbols are intercepted during parsing.
    fn readFnShorthand(self: *Parser, body_text: []const u8) anyerror!Value {
        // Wrap body in parens so it parses as a single form
        const wrapped_len = body_text.len + 2;
        var wrapped_buf: [1024]u8 = undefined;
        var wrapped: []u8 = if (wrapped_len <= wrapped_buf.len)
            wrapped_buf[0..wrapped_len]
        else
            try self.allocator.alloc(u8, wrapped_len);
        const owned = wrapped_len > wrapped_buf.len;
        defer if (owned) self.allocator.free(wrapped);
        wrapped[0] = '(';
        @memcpy(wrapped[1 .. 1 + body_text.len], body_text);
        wrapped[wrapped_len - 1] = ')';

        // Create arg tracker
        var args: FnShorthandArgs = .{
            .allocator = self.allocator,
            .arg_symbols = undefined,
        };
        @memset(&args.arg_symbols, null);

        // Create sub-parser with fn shorthand mode
        var body_parser = try Parser.init(self.allocator, wrapped);
        body_parser.fn_shorthand_args = &args;
        defer body_parser.deinit();

        // Parse the body - % symbols are intercepted by parseSymbol
        const body_form = try body_parser.parse();

        // Build (fn [params] body)
        var fn_form: list.List = .empty;
        try fn_form.append(self.allocator, try self.symValue("fn"));

        // Build params vector from tracked args
        var params_vec: vec.Vector = .empty;
        try args.buildParams(self.allocator, &params_vec);

        try fn_form.append(self.allocator, Value.vectorValue(params_vec));
        // Don't deinit params_vec — items transferred to fn_form
        try fn_form.append(self.allocator, body_form);

        return Value.listValue(fn_form);
    }

    /// Tracks % arg references during fn shorthand parsing.
    const FnShorthandArgs = struct {
        allocator: Allocator,
        max_positional: usize = 0,
        has_rest: bool = false,
        // Cache for generated arg symbols (index 1-based, [0] unused)
        arg_symbols: [32]?[]const u8 = undefined,

        /// Register a % arg reference and return the corresponding symbol.
        fn registerArg(self: *FnShorthandArgs, allocator: Allocator, s: []const u8) anyerror!Value {
            if (std.mem.eql(u8, s, "%")) {
                // bare % → %1
                return self.getArgSymbol(1);
            } else if (std.mem.eql(u8, s, "%&")) {
                self.has_rest = true;
                const rest_name = try allocator.dupe(u8, "%&");
                return .{ .type = .symbol, .sym_val = rest_name };
            } else if (s.len >= 2 and std.ascii.isDigit(s[1])) {
                const n = std.fmt.parseInt(usize, s[1..], 10) catch return error.TypeError;
                return self.getArgSymbol(n);
            }
            return error.TypeError;
        }

        fn getArgSymbol(self: *FnShorthandArgs, n: usize) anyerror!Value {
            if (n > self.max_positional) self.max_positional = n;
            if (n >= self.arg_symbols.len) {
                // Dynamic allocation for high arg numbers
                const name = try std.fmt.allocPrint(self.allocator, "%{d}", .{n});
                return .{ .type = .symbol, .sym_val = name };
            }
            if (self.arg_symbols[n] == null) {
                const name = try std.fmt.allocPrint(self.allocator, "%{d}", .{n});
                self.arg_symbols[n] = name;
            }
            return .{ .type = .symbol, .sym_val = self.arg_symbols[n].? };
        }

        /// Build the params vector from tracked args.
        fn buildParams(self: *FnShorthandArgs, allocator: Allocator, params_vec: *vec.Vector) anyerror!void {
            var i: usize = 1;
            while (i <= self.max_positional) : (i += 1) {
                const name = try std.fmt.allocPrint(allocator, "%{d}", .{i});
                try params_vec.append(allocator, .{ .type = .symbol, .sym_val = name });
            }
            if (self.has_rest) {
                const rest_name = try allocator.dupe(u8, "%&");
                try params_vec.append(allocator, .{ .type = .symbol, .sym_val = rest_name });
            }
        }

        fn deinit(self: *FnShorthandArgs) void {
            var i: usize = 1;
            while (i < self.arg_symbols.len) : (i += 1) {
                if (self.arg_symbols[i] != null) {
                    self.allocator.free(self.arg_symbols[i]);
                }
            }
        }
    };
};

test "parser: empty list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "3.14");
    defer p.deinit();

    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .float);
}

test "parser: booleans" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "nil");
    defer p.deinit();
    var form = try p.parse();
    defer form.deinit(allocator);
    try std.testing.expect(form.type == .nil);
}

test "parser: fn shorthand single arg" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "#(identity %)");
    defer p.deinit();
    var form = try p.parse();
    defer form.deinit(allocator);

    // Should expand to (fn [%1] (identity %1))
    try std.testing.expect(form.type == .list);
    try std.testing.expect(form.list_val.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[0].sym_val, "fn"));
    try std.testing.expect(form.list_val.items[1].type == .vector);
    try std.testing.expect(form.list_val.items[1].vec_val.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[1].vec_val.items[0].sym_val, "%1"));
    // Check body: (identity %1)
    try std.testing.expect(form.list_val.items[2].type == .list);
    try std.testing.expect(form.list_val.items[2].list_val.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[2].list_val.items[1].sym_val, "%1"));
}

test "parser: fn shorthand no args" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "#(identity 42)");
    defer p.deinit();
    var form = try p.parse();
    defer form.deinit(allocator);

    // Should expand to (fn [] (identity 42))
    try std.testing.expect(form.type == .list);
    try std.testing.expect(form.list_val.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[0].sym_val, "fn"));
    try std.testing.expect(form.list_val.items[1].type == .vector);
    try std.testing.expect(form.list_val.items[1].vec_val.items.len == 0);
}

test "parser: fn shorthand two args" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "#(+ %1 %2)");
    defer p.deinit();
    var form = try p.parse();
    defer form.deinit(allocator);

    try std.testing.expect(form.type == .list);
    try std.testing.expect(form.list_val.items.len == 3);
    try std.testing.expect(form.list_val.items[1].vec_val.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[1].vec_val.items[0].sym_val, "%1"));
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[1].vec_val.items[1].sym_val, "%2"));
    // Check body: (+ %1 %2)
    try std.testing.expect(form.list_val.items[2].type == .list);
    try std.testing.expect(form.list_val.items[2].list_val.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[2].list_val.items[1].sym_val, "%1"));
    try std.testing.expect(std.mem.eql(u8, form.list_val.items[2].list_val.items[2].sym_val, "%2"));
}
