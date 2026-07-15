const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("lexer.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const vec = @import("vector.zig");
const BI = @import("big_int.zig");
const BD = @import("big_decimal.zig");
const phm = @import("persistent_hash_map.zig");

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
    // Debug mode: track form nesting for --parse-debug
    debug_mode: bool = false,
    debug_stack: std.ArrayListUnmanaged(DebugForm) = .empty,

    pub const DebugForm = struct {
        form_type: []const u8, // "list", "vector", "map", "set"
        name: []const u8, // first symbol name (e.g. "defn", "let")
        open_line: usize,
    };

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
        self.debug_stack.deinit(self.allocator);
    }

    fn debugOpenForm(self: *Parser, form_type: []const u8, name: []const u8) void {
        if (!self.debug_mode) return;
        const line = self.lexer.currentLine();
        // Duplicate name so it survives token advancement
        const name_dup = if (name.len > 0) self.allocator.dupe(u8, name) catch return else "";
        // Print nesting context
        std.debug.print("## PARSEDEBUG Line:{d} ", .{line});
        if (self.debug_stack.items.len > 0) {
            std.debug.print("InForm:{s} ", .{self.debug_stack.items[self.debug_stack.items.len - 1].name});
        } else {
            std.debug.print("InForm:top ", .{});
        }
        std.debug.print("OpeningForm:{s} ", .{form_type});
        if (name.len > 0) std.debug.print("({s}) ", .{name});
        std.debug.print("\n", .{});
        self.debug_stack.append(self.allocator, .{ .form_type = form_type, .name = name_dup, .open_line = line }) catch {};
    }

    fn debugCloseForm(self: *Parser, form_type: []const u8) void {
        if (!self.debug_mode) return;
        const line = self.lexer.currentLine();
        const name = if (self.debug_stack.items.len > 0) self.debug_stack.items[self.debug_stack.items.len - 1].name else "?";
        const open_line = if (self.debug_stack.items.len > 0) self.debug_stack.items[self.debug_stack.items.len - 1].open_line else 0;
        std.debug.print("## PARSEDEBUG Line:{d} ", .{line});
        if (self.debug_stack.items.len > 1) {
            std.debug.print("InForm:{s} ", .{self.debug_stack.items[self.debug_stack.items.len - 2].name});
        } else {
            std.debug.print("InForm:top ", .{});
        }
        std.debug.print("ClosingForm:{s} ", .{form_type});
        std.debug.print("({s}) ", .{name});
        std.debug.print("StartedFormLine:{d} ", .{open_line});
        std.debug.print("\n", .{});
        if (self.debug_stack.items.len > 0) {
            const popped = self.debug_stack.pop() orelse return;
            if (popped.name.len > 0) self.allocator.free(popped.name);
        }
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

    pub fn advance(self: *Parser) anyerror!void {
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
                const line = self.lexer.currentLine();
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var quoted: list.List = .empty;
                errdefer quoted.deinit(self.allocator);
                try quoted.append(self.allocator, try self.symValue("quote"));
                try quoted.append(self.allocator, form);
                return try vm.listValueWithLine(self.allocator, quoted, line);
            },
            .backtick => {
                // `x is shorthand for (quasiquote x)
                const line = self.lexer.currentLine();
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var qq: list.List = .empty;
                errdefer qq.deinit(self.allocator);
                try qq.append(self.allocator, try self.symValue("quasiquote"));
                try qq.append(self.allocator, form);
                return try vm.listValueWithLine(self.allocator, qq, line);
            },
            .deref => {
                // @x is shorthand for (deref x)
                const line = self.lexer.currentLine();
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var deref_list: list.List = .empty;
                errdefer deref_list.deinit(self.allocator);
                try deref_list.append(self.allocator, try self.symValue("deref"));
                try deref_list.append(self.allocator, form);
                return try vm.listValueWithLine(self.allocator, deref_list, line);
            },
            .unquote => {
                // ~x is shorthand for (unquote x)
                const line = self.lexer.currentLine();
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var uq: list.List = .empty;
                errdefer uq.deinit(self.allocator);
                try uq.append(self.allocator, try self.symValue("unquote"));
                try uq.append(self.allocator, form);
                return try vm.listValueWithLine(self.allocator, uq, line);
            },
            .unquote_splicing => {
                // ~@x is shorthand for (unquote-splicing x)
                const line = self.lexer.currentLine();
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                const form = try self.readForm();
                var uqs: list.List = .empty;
                errdefer uqs.deinit(self.allocator);
                try uqs.append(self.allocator, try self.symValue("unquote-splicing"));
                try uqs.append(self.allocator, form);
                return try vm.listValueWithLine(self.allocator, uqs, line);
            },
            .string => |s| {
                const val = try vm.stringValue(self.allocator, s);
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                return val;
            },
            .regex => |s| {
                const val = try vm.regexValue(self.allocator, s);
                self.current.deinit(self.allocator);
                self.current = .{ .eof = {} };
                try self.advance();
                return val;
            },
            .character => |c| {
                const val = vm.charValue(c);
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
                const val = try vm.keywordValue(self.allocator, s);
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
        const line = self.lexer.currentLine();
        try self.advance(); // consume '('
        var items = list.empty();
        errdefer items.deinit(self.allocator);

        // Get form name from first token (if it's a symbol)
        var form_name: []const u8 = "";
        switch (self.current) {
            .symbol => |s| form_name = s,
            else => {},
        }
        self.debugOpenForm("list", form_name);

        while (true) {
            switch (self.current) {
                .close_paren => {
                    self.debugCloseForm("list");
                    try self.advance();
                    return try vm.listValueWithLine(self.allocator, items, line);
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
        self.debugOpenForm("vector", "");

        while (true) {
            switch (self.current) {
                .close_bracket => {
                    self.debugCloseForm("vector");
                    try self.advance();
                    return try vm.vectorValue(self.allocator, items);
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
        var entries: vm.Map = .empty;
        errdefer {
            for (entries.items) |*entry| {
                vm.valueDeinit(&entry.key, self.allocator);
                vm.valueDeinit(&entry.value, self.allocator);
            }
            self.allocator.free(entries.items);
        }
        self.debugOpenForm("map", "");

        while (true) {
            switch (self.current) {
                .close_brace => {
                    self.debugCloseForm("map");
                    try self.advance();
                    return try vm.mapValue(self.allocator, entries);
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
        var items: vm.Set = .empty;
        errdefer {
            for (items.items) |*item| {
                vm.valueDeinit(item, self.allocator);
            }
            self.allocator.free(items.items);
        }
        self.debugOpenForm("set", "");

        while (true) {
            switch (self.current) {
                .close_brace => {
                    self.debugCloseForm("set");
                    try self.advance();
                    return try vm.setValue(self.allocator, items);
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
                if (vm.equals(existing, item)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try items.append(self.allocator, item);
            } else {
                vm.valueDeinit(&item, self.allocator);
            }
        }
    }

    fn readQueue(self: *Parser) anyerror!Value {
        try self.advance(); // consume 'queue_tag' (which already consumed '#queue(')
        var items: vm.Queue = .empty;
        errdefer {
            for (items.items) |*item| {
                vm.valueDeinit(item, self.allocator);
            }
            self.allocator.free(items.items);
        }

        while (true) {
            switch (self.current) {
                .close_paren => {
                    try self.advance();
                    return try vm.queueValue(self.allocator, items);
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
            return try vm.decimalValue(allocator, bd);
        }
        // Check for BigInt suffix 'N' (e.g., "12345678901234567890N")
        if (s.len > 1 and s[s.len - 1] == 'N') {
            const bi = try BI.bigIntFromString(allocator, s[0 .. s.len - 1]);
            return try vm.bigIntValue(allocator, bi);
        }
        // Check for float (contains '.')
        if (std.mem.indexOfScalar(u8, s, '.')) |_| {
            const f = try std.fmt.parseFloat(f64, s);
            return vm.floatValue(f);
        }
        // Try to parse as i64
        if (std.fmt.parseInt(i64, s, 10)) |i| {
            return vm.intValue(i);
        } else |_| {
            // Overflow: parse as BigInt
            const bi = try BI.bigIntFromString(allocator, s);
            return try vm.bigIntValue(allocator, bi);
        }
    }

    fn symValue(self: *Parser, s: []const u8) anyerror!Value {
        _ = self;
        return phm.sym(s);
    }

    fn parseSymbol(self: *Parser, s: []const u8) anyerror!Value {
        // In fn shorthand mode, intercept % symbols
        if (self.fn_shorthand_args) |args| {
            if (s.len > 0 and s[0] == '%') {
                return args.registerArg(self.allocator, s);
            }
        }
        // Handle special literal symbols
        if (std.mem.eql(u8, s, "true")) return vm.boolValue(true);
        if (std.mem.eql(u8, s, "false")) return vm.boolValue(false);
        if (std.mem.eql(u8, s, "nil")) return vm.nilValue();
        return phm.sym(s);
    }

    /// Expand #(body) shorthand into (fn [params] body).
    /// Parses body with arg tracking: % symbols are intercepted during parsing.
    fn readFnShorthand(self: *Parser, body_text: []const u8) anyerror!Value {
        const line = self.lexer.currentLine();
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
        };

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

        try fn_form.append(self.allocator, try vm.vectorValue(self.allocator, params_vec));
        // Don't deinit params_vec — items transferred to fn_form
        try fn_form.append(self.allocator, body_form);

        return try vm.listValueWithLine(self.allocator, fn_form, line);
    }

    /// Tracks % arg references during fn shorthand parsing.
    const FnShorthandArgs = struct {
        allocator: Allocator,
        max_positional: usize = 0,
        has_rest: bool = false,

        /// Register a % arg reference and return the corresponding symbol.
        fn registerArg(self: *FnShorthandArgs, allocator: Allocator, s: []const u8) anyerror!Value {
            if (std.mem.eql(u8, s, "%")) {
                // bare % → %1
                return self.getArgSymbol(allocator, 1);
            } else if (std.mem.eql(u8, s, "%&")) {
                self.has_rest = true;
                return phm.sym("%&");
            } else if (s.len >= 2 and std.ascii.isDigit(s[1])) {
                const n = std.fmt.parseInt(usize, s[1..], 10) catch return error.TypeError;
                return self.getArgSymbol(allocator, n);
            }
            return error.TypeError;
        }

        fn getArgSymbol(self: *FnShorthandArgs, allocator: Allocator, n: usize) anyerror!Value {
            if (n > self.max_positional) self.max_positional = n;
            const name = try std.fmt.allocPrint(allocator, "%{d}", .{n});
            errdefer allocator.free(name);
            const val = phm.sym(name);
            allocator.free(name);
            return val;
        }

        /// Build the params vector from tracked args.
        fn buildParams(self: *FnShorthandArgs, allocator: Allocator, params_vec: *vec.Vector) anyerror!void {
            var i: usize = 1;
            while (i <= self.max_positional) : (i += 1) {
                const name = try std.fmt.allocPrint(allocator, "%{d}", .{i});
                errdefer allocator.free(name);
                const sym_val = phm.sym(name);
                allocator.free(name);
                try params_vec.append(allocator, sym_val);
            }
            if (self.has_rest) {
                try params_vec.append(allocator, phm.sym("%&"));
            }
        }

        fn deinit(self: *FnShorthandArgs) void {
            // No-op: symbol strings are from phm.sym cache (page_allocator)
            _ = self;
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
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .list);
    try std.testing.expect(form.list.items.items.len == 0);
}

test "parser: simple list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "(+ 1 2)");
    defer p.deinit();

    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .list);
    try std.testing.expect(form.list.items.items.len == 3);
}

test "parser: nested list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "((+ 1 2) 3)");
    defer p.deinit();

    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .list);
    try std.testing.expect(form.list.items.items.len == 2);
}

test "parser: vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "[1 2 3]");
    defer p.deinit();

    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .vector);
    try std.testing.expect(form.vector.items.items.len == 3);
}

test "parser: string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "\"hello\"");
    defer p.deinit();

    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .string);
    try std.testing.expect(std.mem.eql(u8, form.string.slice(), "hello"));
}

test "parser: keyword" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, ":foo");
    defer p.deinit();

    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .keyword);
    try std.testing.expect(std.mem.eql(u8, form.keyword.slice(), "foo"));
}

test "parser: integer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "42");
    defer p.deinit();

    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .integer);
    try std.testing.expect(form.integer == 42);
}

test "parser: float" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "3.14");
    defer p.deinit();

    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .float);
}

test "parser: booleans" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "true");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);
    try std.testing.expect(std.meta.activeTag(form) == .bool);
    try std.testing.expect(form.bool == true);

    var p2 = try Parser.init(allocator, "false");
    defer p2.deinit();
    var form2 = try p2.parse();
    defer vm.valueDeinit(&form2, allocator);
    try std.testing.expect(std.meta.activeTag(form2) == .bool);
    try std.testing.expect(form2.bool == false);
}

test "parser: nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "nil");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);
    try std.testing.expect(std.meta.activeTag(form) == .nil);
}

test "parser: fn shorthand single arg" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "#(identity %)");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    // Should expand to (fn [%1] (identity %1))
    try std.testing.expect(std.meta.activeTag(form) == .list);
    try std.testing.expect(form.list.items.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[0].symbol.slice(), "fn"));
    try std.testing.expect(std.meta.activeTag(form.list.items.items[1]) == .vector);
    try std.testing.expect(form.list.items.items[1].vector.items.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[1].vector.items.items[0].symbol.slice(), "%1"));
    // Check body: (identity %1)
    try std.testing.expect(std.meta.activeTag(form.list.items.items[2]) == .list);
    try std.testing.expect(form.list.items.items[2].list.items.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[2].list.items.items[1].symbol.slice(), "%1"));
}

test "parser: fn shorthand no args" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "#(identity 42)");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    // Should expand to (fn [] (identity 42))
    try std.testing.expect(std.meta.activeTag(form) == .list);
    try std.testing.expect(form.list.items.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[0].symbol.slice(), "fn"));
    try std.testing.expect(std.meta.activeTag(form.list.items.items[1]) == .vector);
    try std.testing.expect(form.list.items.items[1].vector.items.items.len == 0);
}

test "parser: fn shorthand two args" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "#(+ %1 %2)");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);

    try std.testing.expect(std.meta.activeTag(form) == .list);
    try std.testing.expect(form.list.items.items.len == 3);
    try std.testing.expect(form.list.items.items[1].vector.items.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[1].vector.items.items[0].symbol.slice(), "%1"));
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[1].vector.items.items[1].symbol.slice(), "%2"));
    // Check body: (+ %1 %2)
    try std.testing.expect(std.meta.activeTag(form.list.items.items[2]) == .list);
    try std.testing.expect(form.list.items.items[2].list.items.items.len == 3);
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[2].list.items.items[1].symbol.slice(), "%1"));
    try std.testing.expect(std.mem.eql(u8, form.list.items.items[2].list.items.items[2].symbol.slice(), "%2"));
}

test "parser: char literal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "\\A");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);
    try std.testing.expect(std.meta.activeTag(form) == .character);
    try std.testing.expect(form.character == 'A');
}

test "parser: char newline" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "\\newline");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);
    try std.testing.expect(std.meta.activeTag(form) == .character);
    try std.testing.expect(form.character == 10);
}

test "parser: char unicode escape" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "\\u0041");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);
    try std.testing.expect(std.meta.activeTag(form) == .character);
    try std.testing.expect(form.character == 65);
}

test "parser: char in list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try Parser.init(allocator, "(\\A \\B \\C)");
    defer p.deinit();
    var form = try p.parse();
    defer vm.valueDeinit(&form, allocator);
    try std.testing.expect(std.meta.activeTag(form) == .list);
    try std.testing.expect(form.list.items.items.len == 3);
    try std.testing.expect(std.meta.activeTag(form.list.items.items[0]) == .character);
    try std.testing.expect(form.list.items.items[0].character == 'A');
    try std.testing.expect(form.list.items.items[1].character == 'B');
    try std.testing.expect(form.list.items.items[2].character == 'C');
}
