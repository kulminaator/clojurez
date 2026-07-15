// Public API functions for zig.regexp
// These functions are registered as built-in functions in the zig.regexp namespace.

const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const eval_mod = @import("../../eval.zig");
const regexp = @import("regexp.zig");
const Env = vm.Env;
const Allocator = std.mem.Allocator;

// ============================================================
// Public API: re-pattern
// ============================================================

pub fn core_re_pattern(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    // If already a regex, return it as-is
    if (std.meta.activeTag(arg) == .regex) return try vm.shallowClone(&arg, env.allocator);
    // If already a map with :pattern, return it as-is
    if (std.meta.activeTag(arg) == .map) {
        for (arg.map.entries.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword.slice(), "pattern")) {
                return try vm.shallowClone(&arg, env.allocator);
            }
        }
    }
    if (std.meta.activeTag(arg) != .string) return error.TypeError;

    const allocator = env.allocator;
    const s = arg.string.slice();

    // Validate the pattern by parsing it (we store the string and re-parse on use)
    var ast = try regexp.parseRegex(s, allocator);
    ast.deinit(allocator);

    // Return a map with :pattern key (for compatibility with map? check)
    var m: vm.Map = .empty;
    errdefer {
        for (m.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(m.items);
    }
    try m.append(allocator, .{
        .key = try vm.keywordValue(allocator, "pattern"),
        .value = try vm.stringValue(allocator, s),
    });
    return try vm.mapValue(allocator, m);
}

// ============================================================
// Public API: re-matches (full string match)
// ============================================================

pub fn core_re_matches(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (std.meta.activeTag(s) != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    if (try regexp.nfaMatch(&nfa, s.string.slice(), allocator)) {
        return try vm.stringValue(allocator, s.string.slice());
    }
    return vm.nilValue();
}

// ============================================================
// Public API: re-find (find first match)
// ============================================================

pub fn core_re_find(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (std.meta.activeTag(s) != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.string.slice();
    const n = vm.utf8CodepointCount(str);

    var start: usize = 0;
    while (start <= n) : (start += 1) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLenAt(&nfa, remaining, allocator, start);
        if (match_len != null) {
            const len = match_len.?;
            const match_str = remaining[0..len];
            return try vm.stringValue(allocator, match_str);
        }
    }
    return vm.nilValue();
}

// ============================================================
// Public API: re-seq (sequence of all matches)
// ============================================================

pub fn core_re_seq(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (std.meta.activeTag(s) != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.string.slice();
    const n = vm.utf8CodepointCount(str);
    var matches = std.ArrayListUnmanaged(Value).empty;
    errdefer {
        for (matches.items) |*m| vm.valueDeinit(m, allocator);
        matches.deinit(allocator);
    }

    var start: usize = 0;
    while (start <= n) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLenAt(&nfa, remaining, allocator, start);
        if (match_len != null) {
            const len = match_len.?;
            const match_str = remaining[0..len];
            try matches.append(allocator, try vm.stringValue(allocator, match_str));
            // For zero-length matches, advance by 1 to avoid infinite loop
            if (len == 0) {
                start += 1;
            } else {
                const cp_count = vm.utf8CodepointCount(match_str);
                start += cp_count;
            }
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
    return try vm.vectorValue(allocator, v);
}

// ============================================================
// Public API: re-split
// ============================================================

pub fn core_re_split(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const pattern = args.items[0];
    const s = args.items[1];
    if (std.meta.activeTag(s) != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.string.slice();
    const n = vm.utf8CodepointCount(str);
    var parts = std.ArrayListUnmanaged(Value).empty;
    errdefer {
        for (parts.items) |*p| vm.valueDeinit(p, allocator);
        parts.deinit(allocator);
    }

    var start: usize = 0;
    var last_end: usize = 0;
    while (start <= n) : (start += 1) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLenAt(&nfa, remaining, allocator, start);
        if (match_len != null) {
            const len = match_len.?;
            if (len == 0) continue; // skip zero-length matches for split
            const before_str = regexp.substringRange(str, last_end, start);
            try parts.append(allocator, try vm.stringValue(allocator, before_str));
            last_end = start + vm.utf8CodepointCount(remaining[0..len]);
            start = last_end - 1; // -1 because loop increments
        }
    }
    // Add final part
    const final_str = regexp.substringFrom(str, last_end);
    try parts.append(allocator, try vm.stringValue(allocator, final_str));

    // Convert to vector
    var v = vec.Vector.empty;
    errdefer v.deinit(allocator);
    for (parts.items) |p| {
        try v.append(allocator, p);
    }
    return try vm.vectorValue(allocator, v);
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
    if (std.meta.activeTag(s) != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.string.slice();
    const n = vm.utf8CodepointCount(str);

    var start: usize = 0;
    while (start <= n) : (start += 1) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLenAt(&nfa, remaining, allocator, start);
        if (match_len != null) {
            const len = match_len.?;
            const match_str = remaining[0..len];
            const after = remaining[len..];

            // Get replacement string
            var repl_str: []const u8 = undefined;
            if (std.meta.activeTag(replacement) == .function or std.meta.activeTag(replacement) == .builtin_fn) {
                var match_val = try vm.stringValue(allocator, match_str);
                defer vm.valueDeinit(&match_val, allocator);
                var call_args = list.List.empty;
                errdefer call_args.deinit(allocator);
                try call_args.append(allocator, match_val);
                var call_result = try callBuiltin(allocator, replacement, call_args, env);
                defer vm.valueDeinit(&call_result, allocator);
                repl_str = try getReplacementString(allocator, call_result);
            } else {
                repl_str = try getReplacementString(allocator, replacement);
            }

            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, regexp.substringRange(str, 0, start));
            try buf.appendSlice(allocator, repl_str);
            try buf.appendSlice(allocator, after);

            return try vm.stringValue(allocator, try buf.toOwnedSlice(allocator));
        }
    }
    return try vm.stringValue(allocator, str);
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
    if (std.meta.activeTag(s) != .string) return error.TypeError;

    const allocator = env.allocator;
    var nfa = try getNfaFromPattern(allocator, pattern);
    defer nfa.deinit(allocator);

    const str = s.string.slice();
    const n = vm.utf8CodepointCount(str);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var start: usize = 0;
    while (start <= n) {
        const remaining = regexp.substringFrom(str, start);
        const match_len = try regexp.nfaMatchLenAt(&nfa, remaining, allocator, start);
        if (match_len != null) {
            const len = match_len.?;
            const match_str = remaining[0..len];

            // Get replacement string
            var repl_str: []const u8 = undefined;
            if (std.meta.activeTag(replacement) == .function or std.meta.activeTag(replacement) == .builtin_fn) {
                var match_val = try vm.stringValue(allocator, match_str);
                defer vm.valueDeinit(&match_val, allocator);
                var call_args = list.List.empty;
                errdefer call_args.deinit(allocator);
                try call_args.append(allocator, match_val);
                var call_result = try callBuiltin(allocator, replacement, call_args, env);
                defer vm.valueDeinit(&call_result, allocator);
                repl_str = try getReplacementString(allocator, call_result);
            } else {
                repl_str = try getReplacementString(allocator, replacement);
            }
            try buf.appendSlice(allocator, repl_str);

            if (len == 0) {
                start += 1;
            } else {
                start += vm.utf8CodepointCount(match_str);
            }
        } else {
            try buf.appendSlice(allocator, regexp.codepointBytes(str, start));
            start += 1;
        }
    }

    return try vm.stringValue(allocator, try buf.toOwnedSlice(allocator));
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
    if (std.meta.activeTag(v) == .string) return v.string.slice();
    return vm.fmt(v, allocator);
}

// ============================================================
// Helper: call a builtin or function value
// ============================================================

fn callBuiltin(allocator: Allocator, op: Value, args: list.List, env: *Env) anyerror!Value {
    const call_result = try eval_mod.callWithEnv(allocator, &op, &args, env, 0);
    // Phase 1: call_result.value is now Value by copy (not *Value)
    return call_result.value;
}

// ============================================================
// Register all regexp functions in the zig.regexp namespace
// ============================================================

pub fn registerRegexpFunctions(env: *Env) anyerror!void {
    try env.put("re-pattern", vm.builtinFnValue(core_re_pattern));
    try env.put("re-matches", vm.builtinFnValue(core_re_matches));
    try env.put("re-find", vm.builtinFnValue(core_re_find));
    try env.put("re-seq", vm.builtinFnValue(core_re_seq));
    try env.put("re-split", vm.builtinFnValue(core_re_split));
    try env.put("re-replace", vm.builtinFnValue(core_re_replace));
    try env.put("re-replace-all", vm.builtinFnValue(core_re_replace_all));
}
