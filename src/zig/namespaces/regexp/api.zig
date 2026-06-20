// Public API functions for zig.regexp
// These functions are registered as built-in functions in the zig.regexp namespace.

const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const eval_mod = @import("../../eval.zig");
const regexp = @import("regexp.zig");
const Env = Value.Env;
const Allocator = std.mem.Allocator;

// ============================================================
// Public API: re-pattern
// ============================================================

pub fn core_re_pattern(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    // If already a regex, return it as-is
    if (arg.type == .regex) return try arg.clone(env.allocator);
    // If already a map with :pattern, return it as-is
    if (arg.type == .map) {
        for (arg.map_val.items) |entry| {
            if (entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, "pattern")) {
                return try arg.clone(env.allocator);
            }
        }
    }
    if (arg.type != .string) return error.TypeError;

    const allocator = env.allocator;
    const s = arg.str_val;

    // Validate the pattern by parsing it (we store the string and re-parse on use)
    var ast = try regexp.parseRegex(s, allocator);
    ast.deinit(allocator);

    // Return a map with :pattern key (for compatibility with map? check)
    var m: Value.Map = .empty;
    errdefer m.deinit(allocator);
    try m.append(allocator, .{
        .key = try Value.keywordValue(allocator, "pattern"),
        .value = try Value.stringValue(allocator, s),
    });
    return Value.mapValue(m);
}

// ============================================================
// Public API: re-matches (full string match)
// ============================================================

pub fn core_re_matches(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    if (try regexp.nfaMatch(&nfa, s.str_val, allocator)) {
        return try Value.stringValue(allocator, s.str_val);
    }
    return Value.nilValue();
}

// ============================================================
// Public API: re-find (find first match)
// ============================================================

pub fn core_re_find(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

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
// Public API: re-seq (sequence of all matches)
// ============================================================

pub fn core_re_seq(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

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
            // Advance past the match (by byte length / code point count)
            const cp_count = Value.utf8CodepointCount(match_str);
            start += cp_count;
        } else {
            start += 1;
        }
    }

    // Convert to vector
    var v = vec.Vector.empty;
    errdefer v.deinit(allocator);
    for (matches.items) |m| {
        try v.append(allocator, m);
    }
    return Value.vectorValue(v);
}

// ============================================================
// Public API: re-split
// ============================================================

pub fn core_re_split(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.str_val;
    const n = Value.utf8CodepointCount(str);
    var parts = std.ArrayListUnmanaged(Value).empty;
    errdefer {
        for (parts.items) |*p| p.deinit(allocator);
        parts.deinit(allocator);
    }

    var start: usize = 0;
    var last_end: usize = 0;
    while (start < n) : (start += 1) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLen(&nfa, remaining, allocator);
        if (match_len > 0) {
            const before_str = regexp.substringRange(str, last_end, start);
            try parts.append(allocator, try Value.stringValue(allocator, before_str));
            last_end = start + Value.utf8CodepointCount(remaining[0..match_len]);
            start = last_end - 1; // -1 because loop increments
        }
    }
    // Add final part
    const final_str = regexp.substringFrom(str, last_end);
    try parts.append(allocator, try Value.stringValue(allocator, final_str));

    // Convert to vector
    var v = vec.Vector.empty;
    errdefer v.deinit(allocator);
    for (parts.items) |p| {
        try v.append(allocator, p);
    }
    return Value.vectorValue(v);
}

// ============================================================
// Public API: re-replace (first match only)
// ============================================================

pub fn core_re_replace(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 3) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    const replacement = args.items[2];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.str_val;
    const n = Value.utf8CodepointCount(str);

    var start: usize = 0;
    while (start < n) : (start += 1) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLen(&nfa, remaining, allocator);
        if (match_len > 0) {
            const match_str = remaining[0..match_len];
            const after = remaining[match_len..];

            // Get replacement string
            var repl_str: []const u8 = undefined;
            if (replacement.type == .function or replacement.type == .builtin_fn) {
                var match_val = try Value.stringValue(allocator, match_str);
                defer match_val.deinit(allocator);
                var call_args = list.List.empty;
                errdefer call_args.deinit(allocator);
                try call_args.append(allocator, match_val);
                var call_result = try callBuiltin(allocator, replacement, call_args, env);
                defer call_result.deinit(allocator);
                repl_str = try getReplacementString(allocator, call_result);
            } else {
                repl_str = try getReplacementString(allocator, replacement);
            }

            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, regexp.substringRange(str, 0, start));
            try buf.appendSlice(allocator, repl_str);
            try buf.appendSlice(allocator, after);

            return try Value.stringValue(allocator, try buf.toOwnedSlice(allocator));
        }
    }
    return try Value.stringValue(allocator, str);
}

// ============================================================
// Public API: re-replace-all
// ============================================================

pub fn core_re_replace_all(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 3) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    const replacement = args.items[2];
    if (s.type != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.str_val;
    const n = Value.utf8CodepointCount(str);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var start: usize = 0;
    while (start < n) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLen(&nfa, remaining, allocator);
        if (match_len > 0) {
            const match_str = remaining[0..match_len];

            // Get replacement string
            var repl_str: []const u8 = undefined;
            if (replacement.type == .function or replacement.type == .builtin_fn) {
                var match_val = try Value.stringValue(allocator, match_str);
                defer match_val.deinit(allocator);
                var call_args = list.List.empty;
                errdefer call_args.deinit(allocator);
                try call_args.append(allocator, match_val);
                var call_result = try callBuiltin(allocator, replacement, call_args, env);
                defer call_result.deinit(allocator);
                repl_str = try getReplacementString(allocator, call_result);
            } else {
                repl_str = try getReplacementString(allocator, replacement);
            }
            try buf.appendSlice(allocator, repl_str);

            start += Value.utf8CodepointCount(match_str);
        } else {
            try buf.appendSlice(allocator, regexp.codepointBytes(str, start));
            start += 1;
        }
    }

    return try Value.stringValue(allocator, try buf.toOwnedSlice(allocator));
}

// ============================================================
// Helper: get NFA from pattern value
// ============================================================

fn getNfaFromPattern(allocator: Allocator, pattern: Value) anyerror!regexp.Nfa {
    const s = try regexp.extractPatternString(pattern);
    var ast = try regexp.parseRegex(s, allocator);
    defer ast.deinit(allocator);
    const nfa = try regexp.thompsonBuild(ast, allocator);
    return nfa;
}

// ============================================================
// Helper: get replacement string from a Value
// ============================================================

fn getReplacementString(allocator: Allocator, v: Value) anyerror![]const u8 {
    if (v.type == .string) return v.str_val;
    return v.fmt(allocator);
}

// ============================================================
// Helper: call a builtin or function value
// ============================================================

fn callBuiltin(allocator: Allocator, op: Value, args: list.List, env: *Env) anyerror!Value {
    return try eval_mod.call(allocator, op, &args, env, 0);
}

// ============================================================
// Register all regexp functions in the zig.regexp namespace
// ============================================================

pub fn registerRegexpFunctions(env: *Env) anyerror!void {
    try env.put("re-pattern", Value.builtinFnValue(core_re_pattern));
    try env.put("re-matches", Value.builtinFnValue(core_re_matches));
    try env.put("re-find", Value.builtinFnValue(core_re_find));
    try env.put("re-seq", Value.builtinFnValue(core_re_seq));
    try env.put("re-split", Value.builtinFnValue(core_re_split));
    try env.put("re-replace", Value.builtinFnValue(core_re_replace));
    try env.put("re-replace-all", Value.builtinFnValue(core_re_replace_all));
}
