// clojure.core regex functions
// Wraps zig.regexp engine for use from clojure.core namespace.
// Registered in zig.core namespace.
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const eval_mod = @import("../../eval.zig");
const regexp = @import("../regexp/regexp.zig");
const Env = Value.Env;
const Allocator = std.mem.Allocator;

// ============================================================
// re-pattern: Create a regex pattern from a string
// ============================================================

pub fn core_re_pattern(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    // If already a regex, return it as-is
    if (arg.type == .regex) return try arg.clone(env.allocator);
    if (arg.type != .string) return error.TypeError;

    const allocator = env.allocator;
    const s = arg.str_val;

    // Validate the pattern by parsing it
    var ast = try regexp.parseRegex(s, allocator);
    ast.deinit(allocator);

    return Value.regexValue(allocator, s);
}

// ============================================================
// re-matches: Full string match (returns match string or nil)
// ============================================================

pub fn core_re_matches(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);

    if (try regexp.nfaMatch(&nfa, s.str_val, allocator)) {
        return try Value.stringValue(allocator, s.str_val);
    }
    return Value.nilValue();
}

// ============================================================
// re-find: Find first match in string
// ============================================================

pub fn core_re_find(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);

    const str = s.str_val;
    const n = Value.utf8CodepointCount(str);

    var start: usize = 0;
    while (start < n) : (start += 1) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLen(&nfa, remaining, allocator);
        if (match_len > 0) {
            const match_str = remaining[0..match_len];
            return try Value.stringValue(allocator, match_str);
        }
    }
    return Value.nilValue();
}

// ============================================================
// re-seq: All matches as a vector
// ============================================================

pub fn core_re_seq(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);

    const str = s.str_val;
    const n = Value.utf8CodepointCount(str);
    var matches = std.ArrayListUnmanaged(Value).empty;
    errdefer {
        for (matches.items) |*m| m.deinit(allocator);
        matches.deinit(allocator);
    }

    var start: usize = 0;
    while (start < n) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLen(&nfa, remaining, allocator);
        if (match_len > 0) {
            const match_str = remaining[0..match_len];
            try matches.append(allocator, try Value.stringValue(allocator, match_str));
            const cp_count = Value.utf8CodepointCount(match_str);
            start += cp_count;
        } else {
            start += 1;
        }
    }

    var v = vec.Vector.empty;
    errdefer v.deinit(allocator);
    for (matches.items) |m| {
        try v.append(allocator, m);
    }
    return Value.vectorValue(v);
}

// ============================================================
// re-find-with-index: Find first match with position info
// Returns [match-string, start-index, end-index] or nil
// ============================================================

pub fn core_re_find_with_index(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);

    const str = s.str_val;
    const n = Value.utf8CodepointCount(str);

    var start: usize = 0;
    while (start < n) : (start += 1) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLen(&nfa, remaining, allocator);
        if (match_len > 0) {
            const match_str = remaining[0..match_len];
            const match_cp_count = Value.utf8CodepointCount(match_str);
            var result = vec.Vector.empty;
            errdefer result.deinit(allocator);
            try result.append(allocator, try Value.stringValue(allocator, match_str));
            try result.append(allocator, Value.intValue(@intCast(start)));
            try result.append(allocator, Value.intValue(@intCast(start + match_cp_count)));
            return Value.vectorValue(result);
        }
    }
    return Value.nilValue();
}

// ============================================================
// re-find-all: Find all matches with position info
// Returns vector of [match-string, start-index, end-index]
// ============================================================

pub fn core_re_find_all(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);

    const str = s.str_val;
    const n = Value.utf8CodepointCount(str);
    var results = std.ArrayListUnmanaged(Value).empty;
    errdefer {
        for (results.items) |*m| m.deinit(allocator);
        results.deinit(allocator);
    }

    var start: usize = 0;
    while (start < n) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLen(&nfa, remaining, allocator);
        if (match_len > 0) {
            const match_str = remaining[0..match_len];
            const match_cp_count = Value.utf8CodepointCount(match_str);
            var entry = vec.Vector.empty;
            errdefer entry.deinit(allocator);
            try entry.append(allocator, try Value.stringValue(allocator, match_str));
            try entry.append(allocator, Value.intValue(@intCast(start)));
            try entry.append(allocator, Value.intValue(@intCast(start + match_cp_count)));
            try results.append(allocator, Value.vectorValue(entry));
            start += match_cp_count;
        } else {
            start += 1;
        }
    }

    var v = vec.Vector.empty;
    errdefer v.deinit(allocator);
    for (results.items) |m| {
        try v.append(allocator, m);
    }
    return Value.vectorValue(v);
}

// ============================================================
// Helper: get NFA from pattern value
// ============================================================

fn getNfaFromPattern(allocator: Allocator, pattern: Value) anyerror!regexp.Nfa {
    const s = try regexp.extractPatternString(pattern);
    var ast = try regexp.parseRegex(s, allocator);
    defer ast.deinit(allocator);
    return regexp.thompsonBuild(ast, allocator);
}

// ============================================================
// Register regex functions in zig.core namespace
// ============================================================

pub fn registerRegexpFunctions(env: *Env) anyerror!void {
    try env.put("re-pattern", Value.builtinFnValue(core_re_pattern));
    try env.put("re-matches", Value.builtinFnValue(core_re_matches));
    try env.put("re-find", Value.builtinFnValue(core_re_find));
    try env.put("re-seq", Value.builtinFnValue(core_re_seq));
    try env.put("re-find-with-index", Value.builtinFnValue(core_re_find_with_index));
    try env.put("re-find-all", Value.builtinFnValue(core_re_find_all));
}
