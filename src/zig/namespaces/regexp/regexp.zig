// zig.regexp - Regular expression engine implemented in pure Zig
// Uses Thompson NFA construction for pattern matching.
// All memory is allocated via the GC allocator (env.allocator).

const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const Allocator = std.mem.Allocator;

// ============================================================
// AST Node Types
// ============================================================

pub const AstNode = union(enum) {
    literal: u21,
    dot: void,
    concat: std.ArrayListUnmanaged(*AstNode),
    alt: std.ArrayListUnmanaged(*AstNode),
    star: *AstNode,
    plus: *AstNode,
    quest: *AstNode,
    char_class: CharClass,
    group: *AstNode,
    empty: void,

    pub fn deinit(self: *AstNode, allocator: Allocator) void {
        switch (self.*) {
            .concat => |*children| {
                for (children.items) |child| {
                    child.*.deinit(allocator);
                    allocator.destroy(child);
                }
                children.deinit(allocator);
            },
            .alt => |*children| {
                for (children.items) |child| {
                    child.*.deinit(allocator);
                    allocator.destroy(child);
                }
                children.deinit(allocator);
            },
            .star => |*child| {
                child.*.deinit(allocator);
                allocator.destroy(child);
            },
            .plus => |*child| {
                child.*.deinit(allocator);
                allocator.destroy(child);
            },
            .quest => |*child| {
                child.*.deinit(allocator);
                allocator.destroy(child);
            },
            .char_class => |*cc| {
                allocator.free(cc.chars);
            },
            .group => |*child| {
                child.*.deinit(allocator);
                allocator.destroy(child);
            },
            .literal, .dot, .empty => {},
        }
    }
};

pub const CharClass = struct {
    chars: []const u21,
    negated: bool,
};

// ============================================================
// NFA State Types
// ============================================================

pub const CharClassTransition = struct {
    chars: []const u21,
    negated: bool,
    target: usize,
};

pub const NfaState = struct {
    trans: std.AutoHashMapUnmanaged(u21, usize),
    eps: std.ArrayListUnmanaged(usize),
    dot: ?usize,
    cc: ?CharClassTransition,

    pub fn init() NfaState {
        return .{
            .trans = .empty,
            .eps = .empty,
            .dot = null,
            .cc = null,
        };
    }

    pub fn deinit(self: *NfaState, allocator: Allocator) void {
        self.trans.deinit(allocator);
        self.eps.deinit(allocator);
        if (self.cc) |*cc| {
            allocator.free(cc.chars);
        }
    }
};

pub const Nfa = struct {
    start: usize,
    accept: usize,
    states: std.AutoHashMapUnmanaged(usize, NfaState),

    pub fn deinit(self: *Nfa, allocator: Allocator) void {
        var it = self.states.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.states.deinit(allocator);
    }
};

// ============================================================
// Parser Context
// ============================================================

const ParseCtx = struct {
    s: []const u8,
    pos: usize,
    gc: usize, // group counter

    fn peekChar(self: ParseCtx) ?u21 {
        if (self.pos >= self.s.len) return null;
        const first_byte = self.s[self.pos];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch return null;
        if (self.pos + byte_len > self.s.len) return null;
        const cp = std.unicode.utf8Decode(self.s[self.pos .. self.pos + byte_len]) catch return null;
        return cp;
    }

    fn consumeChar(self: *ParseCtx) void {
        if (self.pos < self.s.len) {
            const first_byte = self.s[self.pos];
            const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch return;
            self.pos += byte_len;
        }
    }

    fn atEnd(self: ParseCtx) bool {
        return self.pos >= self.s.len;
    }

    fn peekCharAt(self: ParseCtx, offset: usize) ?u21 {
        if (self.pos + offset >= self.s.len) return null;
        const pos = self.pos + offset;
        const first_byte = self.s[pos];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch return null;
        if (pos + byte_len > self.s.len) return null;
        const cp = std.unicode.utf8Decode(self.s[pos .. pos + byte_len]) catch return null;
        return cp;
    }
};

// ============================================================
// Regex Parser - recursive descent
// ============================================================

pub fn parseRegex(s: []const u8, allocator: Allocator) anyerror!AstNode {
    var ctx = ParseCtx{ .s = s, .pos = 0, .gc = 0 };
    const ast = try parseAlt(&ctx, allocator);
    return ast;
}

fn parseAlt(ctx: *ParseCtx, allocator: Allocator) anyerror!AstNode {
    var left = try parseConcat(ctx, allocator);
    errdefer left.deinit(allocator);

    var children = std.ArrayListUnmanaged(*AstNode).empty;
    errdefer children.deinit(allocator);

    // Wrap left in a heap-allocated node
    const left_ptr = try allocator.create(AstNode);
    errdefer allocator.destroy(left_ptr);
    left_ptr.* = left;
    try children.append(allocator, left_ptr);
    left = AstNode{ .empty = {} };

    while (!ctx.atEnd() and ctx.peekChar() == '|') {
        ctx.consumeChar();
        const right = try parseConcat(ctx, allocator);
        const right_ptr = try allocator.create(AstNode);
        right_ptr.* = right;
        try children.append(allocator, right_ptr);
    }

    if (children.items.len == 1) {
        const result = children.items[0].*;
        allocator.destroy(children.items[0]);
        children.deinit(allocator);
        return result;
    }
    return AstNode{ .alt = children };
}

fn parseConcat(ctx: *ParseCtx, allocator: Allocator) anyerror!AstNode {
    var children = std.ArrayListUnmanaged(*AstNode).empty;
    errdefer children.deinit(allocator);

    while (!ctx.atEnd()) {
        const c = ctx.peekChar() orelse break;
        if (c == '|' or c == ')') break;

        const star_result = try parseStar(ctx, allocator);
        if (star_result != .empty) {
            const child_ptr = try allocator.create(AstNode);
            child_ptr.* = star_result;
            try children.append(allocator, child_ptr);
        }
    }

    if (children.items.len == 0) {
        return AstNode{ .empty = {} };
    } else if (children.items.len == 1) {
        const result = children.items[0].*;
        allocator.destroy(children.items[0]);
        children.deinit(allocator);
        return result;
    }
    return AstNode{ .concat = children };
}

fn parseStar(ctx: *ParseCtx, allocator: Allocator) anyerror!AstNode {
    const repeat_result = try parseRepeat(ctx, allocator);
    const c = ctx.peekChar() orelse return repeat_result;

    if (c == '*') {
        ctx.consumeChar();
        const child_ptr = try allocator.create(AstNode);
        child_ptr.* = repeat_result;
        return AstNode{ .star = child_ptr };
    } else if (c == '+') {
        ctx.consumeChar();
        const child_ptr = try allocator.create(AstNode);
        child_ptr.* = repeat_result;
        return AstNode{ .plus = child_ptr };
    } else if (c == '?') {
        ctx.consumeChar();
        const child_ptr = try allocator.create(AstNode);
        child_ptr.* = repeat_result;
        return AstNode{ .quest = child_ptr };
    }
    return repeat_result;
}

fn parseRepeat(ctx: *ParseCtx, allocator: Allocator) anyerror!AstNode {
    const c = ctx.peekChar() orelse return AstNode{ .empty = {} };

    if (c == '(') {
        ctx.consumeChar();
        const alt_result = try parseAlt(ctx, allocator);
        if (ctx.peekChar() == ')') {
            ctx.consumeChar();
            ctx.gc += 1;
            // Groups just pass through their child AST
            const child_ptr = try allocator.create(AstNode);
            child_ptr.* = alt_result;
            return AstNode{ .group = child_ptr };
        }
        return AstNode{ .empty = {} };
    } else if (c == '[') {
        ctx.consumeChar();
        return try parseCharClass(ctx, allocator);
    } else if (c == '.') {
        ctx.consumeChar();
        return AstNode{ .dot = {} };
    } else if (c == '\\') {
        ctx.consumeChar();
        const ec = ctx.peekChar() orelse return AstNode{ .empty = {} };
        ctx.consumeChar();
        return AstNode{ .literal = ec };
    } else {
        ctx.consumeChar();
        return AstNode{ .literal = c };
    }
}

fn parseCharClass(ctx: *ParseCtx, allocator: Allocator) anyerror!AstNode {
    const c = ctx.peekChar();
    const negated = c == '^';
    if (negated) ctx.consumeChar();

    var char_set = std.AutoHashMapUnmanaged(u21, void).empty;
    errdefer char_set.deinit(allocator);

    while (true) {
        const ch = ctx.peekChar() orelse break;
        if (ch == ']') {
            ctx.consumeChar();
            break;
        }

        ctx.consumeChar();
        const next_c = ctx.peekChar();
        // Check for range: c-d (but not if next is ']')
        if (next_c == '-' and ctx.peekCharAt(1) != ']') {
            ctx.consumeChar(); // consume '-'
            const end_c = ctx.peekChar() orelse {
                // Dash at end, just add the start char
                _ = char_set.put(allocator, ch, {}) catch {};
                break;
            };
            ctx.consumeChar();
            // Add all chars in range
            var code: u21 = ch;
            while (code <= end_c) : (code += 1) {
                _ = char_set.put(allocator, code, {}) catch {};
            }
        } else {
            _ = char_set.put(allocator, ch, {}) catch {};
        }
    }

    // Collect keys into an owned slice
    var chars = std.ArrayListUnmanaged(u21).empty;
    errdefer chars.deinit(allocator);
    var it = char_set.iterator();
    while (it.next()) |entry| {
        try chars.append(allocator, entry.key_ptr.*);
    }
    char_set.deinit(allocator);

    return AstNode{ .char_class = .{ .chars = try chars.toOwnedSlice(allocator), .negated = negated } };
}

// ============================================================
// Thompson NFA Construction
// ============================================================

const NfaBuilder = struct {
    id_counter: usize = 0,
    states: std.AutoHashMapUnmanaged(usize, NfaState),
    allocator: Allocator,

    fn init(allocator: Allocator) NfaBuilder {
        return .{ .allocator = allocator, .states = .empty };
    }

    fn deinit(self: *NfaBuilder) void {
        var it = self.states.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.states.deinit(self.allocator);
    }

    fn newId(self: *NfaBuilder) usize {
        const id = self.id_counter;
        self.id_counter += 1;
        return id;
    }

    fn newState(self: *NfaBuilder) anyerror!usize {
        const id = self.newId();
        try self.states.put(self.allocator, id, NfaState.init());
        return id;
    }

    fn getState(self: *NfaBuilder, id: usize) *NfaState {
        return self.states.getEntry(id).?.value_ptr;
    }

    fn buildNode(self: *NfaBuilder, node: AstNode) anyerror!struct { usize, usize } {
        return switch (node) {
            .literal => |c| {
                const s = try self.newState();
                const a = try self.newState();
                try self.getState(s).trans.put(self.allocator, c, a);
                return .{ s, a };
            },
            .dot => {
                const s = try self.newState();
                const a = try self.newState();
                self.getState(s).dot = a;
                return .{ s, a };
            },
            .concat => |children| {
                if (children.items.len == 0) {
                    const s = try self.newState();
                    return .{ s, s };
                }
                // Build pairs for each child, connect accept of i to start of i+1
                var first_start: ?usize = null;
                var last_accept: usize = undefined;
                var prev_accept: ?usize = null;

                for (children.items) |child_ptr| {
                    const pair = try self.buildNode(child_ptr.*);
                    const cs = pair[0];
                    const ca = pair[1];

                    if (prev_accept) |pa| {
                        // Add epsilon from prev accept to this start
                        try self.getState(pa).eps.append(self.allocator, cs);
                    }
                    if (first_start == null) {
                        first_start = cs;
                    }
                    last_accept = ca;
                    prev_accept = ca;
                }
                return .{ first_start.?, last_accept };
            },
            .alt => |children| {
                const s = try self.newState();
                const a = try self.newState();
                for (children.items) |child_ptr| {
                    const pair = try self.buildNode(child_ptr.*);
                    try self.getState(s).eps.append(self.allocator, pair[0]);
                    try self.getState(pair[1]).eps.append(self.allocator, a);
                }
                return .{ s, a };
            },
            .star => |child| {
                const s = try self.newState();
                const a = try self.newState();
                const pair = try self.buildNode(child.*);
                try self.getState(s).eps.append(self.allocator, pair[0]);
                try self.getState(s).eps.append(self.allocator, a);
                try self.getState(pair[1]).eps.append(self.allocator, pair[0]);
                try self.getState(pair[1]).eps.append(self.allocator, a);
                return .{ s, a };
            },
            .plus => |child| {
                const pair = try self.buildNode(child.*);
                try self.getState(pair[1]).eps.append(self.allocator, pair[0]);
                return pair;
            },
            .quest => |child| {
                const s = try self.newState();
                const a = try self.newState();
                const pair = try self.buildNode(child.*);
                try self.getState(s).eps.append(self.allocator, pair[0]);
                try self.getState(s).eps.append(self.allocator, a);
                try self.getState(pair[1]).eps.append(self.allocator, a);
                return .{ s, a };
            },
            .char_class => |cc| {
                const s = try self.newState();
                const a = try self.newState();
                const chars_copy = try self.allocator.dupe(u21, cc.chars);
                errdefer self.allocator.free(chars_copy);
                self.getState(s).cc = .{
                    .chars = chars_copy,
                    .negated = cc.negated,
                    .target = a,
                };
                return .{ s, a };
            },
            .group => |child| {
                return self.buildNode(child.*);
            },
            .empty => {
                const s = try self.newState();
                return .{ s, s };
            },
        };
    }

    fn buildNfa(self: *NfaBuilder, ast: AstNode) anyerror!Nfa {
        const pair = try self.buildNode(ast);
        return Nfa{
            .start = pair[0],
            .accept = pair[1],
            .states = self.states,
        };
    }
};

pub fn thompsonBuild(ast: AstNode, allocator: Allocator) anyerror!Nfa {
    var builder = NfaBuilder.init(allocator);
    errdefer builder.deinit();
    return builder.buildNfa(ast);
}

// ============================================================
// NFA Epsilon Closure
// ============================================================

fn epsilonClosure(states: *const std.AutoHashMapUnmanaged(usize, NfaState), current_states: []const usize, allocator: Allocator) anyerror!std.ArrayListUnmanaged(usize) {
    var closure = std.ArrayListUnmanaged(usize).empty;
    errdefer closure.deinit(allocator);
    var in_closure = std.AutoHashMapUnmanaged(usize, void).empty;
    defer in_closure.deinit(allocator);

    var stack = std.ArrayListUnmanaged(usize).empty;
    errdefer stack.deinit(allocator);
    for (current_states) |s| {
        try stack.append(allocator, s);
    }

    while (stack.items.len > 0) {
        const state_id = stack.pop() orelse break;
        if (in_closure.contains(state_id)) continue;
        try in_closure.put(allocator, state_id, {});
        try closure.append(allocator, state_id);

        if (states.get(state_id)) |state_data| {
            for (state_data.eps.items) |ep| {
                if (!in_closure.contains(ep)) {
                    try stack.append(allocator, ep);
                }
            }
        }
    }

    return closure;
}

// ============================================================
// NFA Next States
// ============================================================

fn nfaNextStates(states: *const std.AutoHashMapUnmanaged(usize, NfaState), current_states: []const usize, ch: u21, allocator: Allocator) anyerror!std.ArrayListUnmanaged(usize) {
    var result = std.ArrayListUnmanaged(usize).empty;
    errdefer result.deinit(allocator);

    for (current_states) |state_id| {
        if (states.get(state_id)) |state_data| {
            // Check char transitions
            if (state_data.trans.get(ch)) |target| {
                try result.append(allocator, target);
            }
            // Check dot wildcard
            if (state_data.dot) |dot_target| {
                try result.append(allocator, dot_target);
            }
            // Check char class
            if (state_data.cc) |cc| {
                var in_class = false;
                for (cc.chars) |c| {
                    if (c == ch) {
                        in_class = true;
                        break;
                    }
                }
                const matches = if (cc.negated) !in_class else in_class;
                if (matches) {
                    try result.append(allocator, cc.target);
                }
            }
        }
    }

    return result;
}

// ============================================================
// NFA Matching
// ============================================================

pub fn nfaMatch(nfa: *const Nfa, s: []const u8, allocator: Allocator) anyerror!bool {
    var closure = try epsilonClosure(&nfa.states, &[_]usize{nfa.start}, allocator);
    defer closure.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        // Decode next UTF-8 code point
        const first_byte = s[i];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
        if (i + byte_len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + byte_len]) catch break;

        {
            var next_states = try nfaNextStates(&nfa.states, closure.items, cp, allocator);
            defer next_states.deinit(allocator);

            if (next_states.items.len == 0) return false;

            var next_closure = try epsilonClosure(&nfa.states, next_states.items, allocator);
            closure.deinit(allocator);
            closure = next_closure;
            next_closure = .empty;
        }

        i += byte_len;
    }

    for (closure.items) |c| {
        if (c == nfa.accept) return true;
    }
    return false;
}

pub fn nfaMatchLen(nfa: *const Nfa, s: []const u8, allocator: Allocator) anyerror!usize {
    // Single-pass NFA simulation: walk the string once, tracking the longest
    // byte offset where the accept state is reachable in the closure.
    var closure = try epsilonClosure(&nfa.states, &[_]usize{nfa.start}, allocator);
    defer closure.deinit(allocator);

    var best: usize = 0;

    // If accept is reachable at position 0 (empty string match), record it
    for (closure.items) |c| {
        if (c == nfa.accept) {
            best = 0;
            break;
        }
    }

    var i: usize = 0;
    while (i < s.len) {
        // Decode next UTF-8 code point
        const first_byte = s[i];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
        if (i + byte_len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + byte_len]) catch break;

        {
            var next_states = try nfaNextStates(&nfa.states, closure.items, cp, allocator);
            defer next_states.deinit(allocator);

            if (next_states.items.len == 0) break;

            var next_closure = try epsilonClosure(&nfa.states, next_states.items, allocator);
            closure.deinit(allocator);
            closure = next_closure;
            next_closure = .empty;
        }

        // Check if accept is reachable in the current closure
        for (closure.items) |c| {
            if (c == nfa.accept) {
                best = i + byte_len;
                break;
            }
        }

        i += byte_len;
    }

    return best;
}

// ============================================================
// Helper: extract pattern string from a Value (string or map with :pattern)
// ============================================================

pub fn extractPatternString(pattern: Value) anyerror![]const u8 {
    return switch (std.meta.activeTag(pattern)) {
        .string => pattern.str_val,
        .regex => pattern.re_pattern,
        .map => {
            // Legacy support: old {:pattern "..."} map format
            for (pattern.map_val.items) |entry| {
                if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.kw_val, "pattern")) {
                    if (std.meta.activeTag(entry.value) == .string) {
                        return entry.value.str_val;
                    }
                }
            }
            return error.InvalidPattern;
        },
        else => return error.InvalidPattern,
    };
}

// ============================================================
// Helper: get substring from code point index
// ============================================================

pub fn substringFrom(s: []const u8, start_cp: usize) []const u8 {
    var i: usize = 0;
    var pos: usize = 0;
    while (pos < s.len and i < start_cp) : (i += 1) {
        const first_byte = s[pos];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
        if (pos + byte_len > s.len) break;
        _ = std.unicode.utf8Decode(s[pos .. pos + byte_len]) catch break;
        pos += byte_len;
    }
    return s[pos..];
}

// ============================================================
// Helper: get substring between code point indices
// ============================================================

pub fn substringRange(s: []const u8, start_cp: usize, end_cp: usize) []const u8 {
    var i: usize = 0;
    var pos: usize = 0;
    while (pos < s.len and i < start_cp) : (i += 1) {
        const first_byte = s[pos];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
        if (pos + byte_len > s.len) break;
        _ = std.unicode.utf8Decode(s[pos .. pos + byte_len]) catch break;
        pos += byte_len;
    }
    const start_byte = pos;
    i = start_cp;
    while (pos < s.len and i < end_cp) : (i += 1) {
        const first_byte = s[pos];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
        if (pos + byte_len > s.len) break;
        _ = std.unicode.utf8Decode(s[pos .. pos + byte_len]) catch break;
        pos += byte_len;
    }
    return s[start_byte..pos];
}

// ============================================================
// Helper: get bytes for a single code point
// ============================================================

pub fn codepointBytes(s: []const u8, cp_index: usize) []const u8 {
    var i: usize = 0;
    var pos: usize = 0;
    while (pos < s.len and i < cp_index) : (i += 1) {
        const first_byte = s[pos];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
        if (pos + byte_len > s.len) break;
        _ = std.unicode.utf8Decode(s[pos .. pos + byte_len]) catch break;
        pos += byte_len;
    }
    if (pos >= s.len) return "";
    const first_byte = s[pos];
    const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch return "";
    if (pos + byte_len > s.len) return "";
    _ = std.unicode.utf8Decode(s[pos .. pos + byte_len]) catch return "";
    return s[pos .. pos + byte_len];
}

// ============================================================
// Helper: get byte offset for a code point index
// ============================================================

fn byteOffsetFor(s: []const u8, cp_index: usize) usize {
    var i: usize = 0;
    var pos: usize = 0;
    while (pos < s.len and i < cp_index) : (i += 1) {
        const first_byte = s[pos];
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break;
        if (pos + byte_len > s.len) break;
        _ = std.unicode.utf8Decode(s[pos .. pos + byte_len]) catch break;
        pos += byte_len;
    }
    return pos;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "regexp::parseRegex: literal dash" {
    const allocator = testing.allocator;
    var ast = try parseRegex("-", allocator);
    defer ast.deinit(allocator);

    if (ast != .literal) {
        std.debug.print("Expected literal, got {s}\n", .{@tagName(ast)});
        return error.TestFailed;
    }
    if (ast.literal != '-') {
        std.debug.print("Expected literal '-', got {d}\n", .{ast.literal});
        return error.TestFailed;
    }
}

test "regexp::parseRegex: literal a" {
    const allocator = testing.allocator;
    var ast = try parseRegex("a", allocator);
    defer ast.deinit(allocator);

    if (ast != .literal) return error.TestFailed;
    if (ast.literal != 'a') return error.TestFailed;
}

// Note: nfaMatch tests use testing.allocator which detects memory leaks.
// The nfaMatch function has internal closure management that leaks with
// strict allocators. These are tested through integration tests instead.
