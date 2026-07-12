// Shared evaluation helpers for calling user-defined functions from built-ins
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const phm = @import("../../persistent_hash_map.zig");
const helpers = @import("helpers.zig");
const eval_ns = @import("../../eval_ns.zig");
const eval_macro = @import("../../eval_macro.zig");
const gc_mod = @import("../../gc.zig");

const Allocator = std.mem.Allocator;

/// Loop context for evalLoop/evalRecur coordination.
/// Stack-based to support nested loops.
const LoopContext = struct {
    env: ?*vm.Env = null,
    bind_names: []const []const u8 = &.{},
    body: []const Value = &.{},
};

var loop_stack: std.ArrayListUnmanaged(LoopContext) = .empty;

/// Check if a form looks like a multi-arity fn body: ([params] body...) or ([params] body...)
fn isMultiArityForm(form: Value) bool {
    const items = switch (std.meta.activeTag(form)) {
        .list => form.list.items.items,
        .vector => form.vector.items.items,
        else => return false,
    };
    if (items.len < 1) return false;
    return std.meta.activeTag(items[0]) == .list or std.meta.activeTag(items[0]) == .vector;
}

// Bind a parameter to an argument, supporting destructuring.
// Delegates to bindPattern which handles symbols, vectors with & rest, nested patterns.
fn bindParam(allocator: Allocator, param: *const Value, arg: *const Value, env: *vm.Env) anyerror!void {
    try bindPattern(allocator, param.*, arg.*, env);
}

/// Bind a pattern (symbol or destructuring vector) to a value.
/// Handles: symbols, vector destructuring [a b], [a & rest], nested vectors.
fn bindPattern(allocator: Allocator, pattern: Value, val: Value, env: *vm.Env) anyerror!void {
    switch (std.meta.activeTag(pattern)) {
        .symbol => {
            try env.put(pattern.symbol, try vm.shallowClone(&val, allocator));
        },
        .vector => {
            // Vector destructuring: [a b & rest] matches elements of val
            const vitems = switch (std.meta.activeTag(val)) {
                .list => val.list.items.items,
                .vector => val.vector.items.items,
                else => return error.TypeError,
            };
            var j: usize = 0;
            while (j < pattern.vector.items.items.len) : (j += 1) {
                const pat_item = pattern.vector.items.items[j];
                // Handle & rest (& is parsed as a symbol)
                if (std.meta.activeTag(pat_item) == .symbol and std.mem.eql(u8, pat_item.symbol, "&")) {
                    if (j + 1 < pattern.vector.items.items.len) {
                        const rest_sym = pattern.vector.items.items[j + 1];
                        // Collect remaining items into a list (starting from current position j)
                        var rest_list: list.List = .empty;
                        errdefer rest_list.deinit(allocator);
                        var k: usize = j;
                        while (k < vitems.len) : (k += 1) {
                            try rest_list.append(allocator, try vm.shallowClone(&vitems[k], allocator));
                        }
                        if (std.meta.activeTag(rest_sym) == .symbol) {
                            try env.put(rest_sym.symbol, try vm.listValue(allocator, rest_list));
                        }
                        j += 1; // Skip the rest symbol
                    }
                    break;
                } else if (j < vitems.len) {
                    try bindPattern(allocator, pat_item, vitems[j], env);
                }
            }
        },
        .list => {
            // List destructuring: same as vector
            const vitems = switch (std.meta.activeTag(val)) {
                .list => val.list.items.items,
                .vector => val.vector.items.items,
                else => return error.TypeError,
            };
            var j: usize = 0;
            while (j < pattern.list.items.items.len) : (j += 1) {
                const pat_item = pattern.list.items.items[j];
                if (std.meta.activeTag(pat_item) == .symbol and std.mem.eql(u8, pat_item.symbol, "&")) {
                    if (j + 1 < pattern.list.items.items.len) {
                        const rest_sym = pattern.list.items.items[j + 1];
                        var rest_list: list.List = .empty;
                        errdefer rest_list.deinit(allocator);
                        var k: usize = j;
                        while (k < vitems.len) : (k += 1) {
                            try rest_list.append(allocator, try vm.shallowClone(&vitems[k], allocator));
                        }
                        if (std.meta.activeTag(rest_sym) == .symbol) {
                            try env.put(rest_sym.symbol, try vm.listValue(allocator, rest_list));
                        }
                        j += 1;
                    }
                    break;
                } else if (j < vitems.len) {
                    try bindPattern(allocator, pat_item, vitems[j], env);
                }
            }
        },
        else => return error.TypeError,
    }
}

/// Parse a parameter list, extracting regular params and optional rest param.
/// E.g., [a b & rest] => { params: (a b), rest_name: "rest" }
/// E.g., [a b]        => { params: (a b), rest_name: null }
pub fn parseParams(allocator: Allocator, params: list.List) anyerror!ParsedParams {
    var regular_params: list.List = .empty;
    errdefer regular_params.deinit(allocator);
    var rest_name: ?[]u8 = null;

    var i: usize = 0;
    var found_amp = false;
    while (i < params.items.len) : (i += 1) {
        const item = params.items[i];
        if (!found_amp and std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.symbol, "&")) {
            found_amp = true;
            continue;
        }
        if (found_amp) {
            if (std.meta.activeTag(item) != .symbol) return error.TypeError;
            rest_name = try allocator.dupe(u8, item.symbol);
            break;
        } else {
            try regular_params.append(allocator, try vm.shallowClone(&item, allocator));
        }
    }

    return ParsedParams{
        .params = regular_params,
        .rest_name = rest_name,
    };
}

pub const ParsedParams = struct {
    params: list.List,
    rest_name: ?[]u8,
};

pub fn callBuiltin(allocator: Allocator, f: *const Value, args_list: *const list.List, env: *vm.Env) anyerror!*Value {
    switch (std.meta.activeTag(f.*)) {
        .function => {
            const fn_data = f.function;
            const arg_count = args_list.items.len;

            // Find matching arity
            var matched_arity: ?*const vm.Arity = null;
            var ai: usize = 0;
            while (ai < fn_data.arities.items.len) : (ai += 1) {
                const arity = &fn_data.arities.items[ai];
                const min_args = arity.params.items.len;
                const has_rest = arity.rest_name != null;
                if (has_rest) {
                    if (arg_count >= min_args) {
                        matched_arity = arity;
                        break;
                    }
                } else {
                    if (arg_count == min_args) {
                        matched_arity = arity;
                        break;
                    }
                }
            }
            if (matched_arity == null) return error.ArityError;
            const arity = matched_arity.?;

            // Fast path: 2-param, no-rest, body is a single 2-arg call with matching params.
            // Covers wrapper functions like (defn + [a b] (zig.core/+ a b)).
            // Avoids env creation, hash-map param binding, body cloning, and symbol resolution.
            if (arity.params.items.len == 2 and arity.rest_name == null and arg_count == 2) {
                if (std.meta.activeTag(arity.params.items[0]) == .symbol and std.meta.activeTag(arity.params.items[1]) == .symbol) {
                    // Body is wrapped as (do <call>). Find the actual call.
                    var body_call: list.List = undefined;
                    if (arity.body.items.len >= 2 and
                        std.meta.activeTag(arity.body.items[0]) == .symbol and
                        std.mem.eql(u8, arity.body.items[0].symbol, "do") and
                        std.meta.activeTag(arity.body.items[1]) == .list)
                    {
                        body_call = arity.body.items[1].list.items;
                    } else if (arity.body.items.len == 1 and std.meta.activeTag(arity.body.items[0]) == .list) {
                        body_call = arity.body.items[0].list.items;
                    } else {
                        body_call = list.empty();
                    }
                    if (body_call.items.len == 3) {
                        const body_op = &body_call.items[0];
                        const body_arg0 = &body_call.items[1];
                        const body_arg1 = &body_call.items[2];
                        if (std.meta.activeTag(body_arg0.*) == .symbol and std.meta.activeTag(body_arg1.*) == .symbol and
                            std.mem.eql(u8, body_arg0.symbol, arity.params.items[0].symbol) and
                            std.mem.eql(u8, body_arg1.symbol, arity.params.items[1].symbol))
                        {
                            // Resolve operator from function's definition env (has ns_manager)
                            const resolved_op_ptr = try evalForm(allocator, body_op, fn_data.env);
                            defer vm.valueDeinit(&resolved_op_ptr.*, allocator);
                            var call_args: list.List = .empty;
                            errdefer call_args.deinit(allocator);
                            try call_args.append(allocator, try vm.shallowClone(&args_list.items[0], allocator));
                            try call_args.append(allocator, try vm.shallowClone(&args_list.items[1], allocator));
                            return try callBuiltin(allocator, resolved_op_ptr, &call_args, env);
                        }
                    }
                }
            }

            // Fast path: 1-param, no-rest, body is a simple pattern.
            // Covers: identity, not, inc, dec, zero?, pos?, neg?, etc.
            // Avoids env creation, hash-map param binding, body cloning, and symbol resolution.
            if (arity.params.items.len == 1 and arity.rest_name == null and arg_count == 1 and
                std.meta.activeTag(arity.params.items[0]) == .symbol)
            {
                const param_name = arity.params.items[0].symbol;

                // --- Pattern 1: body is bare param symbol → identity ---
                if (arity.body.items.len == 1 and
                    std.meta.activeTag(arity.body.items[0]) == .symbol and
                    std.mem.eql(u8, arity.body.items[0].symbol, param_name))
                {
                    // identity: return the argument directly
                    return try allocBuiltinResult(allocator, try vm.shallowClone(&args_list.items[0], allocator));
                }

                // --- Pattern 2 & 3: body is a single call ---
                // Unwrap (do <call>) if present
                var body_call: list.List = undefined;
                if (arity.body.items.len >= 2 and
                    std.meta.activeTag(arity.body.items[0]) == .symbol and
                    std.mem.eql(u8, arity.body.items[0].symbol, "do") and
                    std.meta.activeTag(arity.body.items[1]) == .list)
                {
                    body_call = arity.body.items[1].list.items;
                } else if (arity.body.items.len == 1 and std.meta.activeTag(arity.body.items[0]) == .list) {
                    body_call = arity.body.items[0].list.items;
                } else {
                    body_call = list.empty();
                }

                if (body_call.items.len == 2 or body_call.items.len == 3) {
                    const body_op = &body_call.items[0];

                    if (body_call.items.len == 2) {
                        // --- Pattern 2: (op param) → e.g. not, boolean ---
                        const body_arg0 = &body_call.items[1];
                        if (std.meta.activeTag(body_arg0.*) == .symbol and
                            std.mem.eql(u8, body_arg0.symbol, param_name))
                        {
                            // Resolve operator from function's definition env (has ns_manager)
                            const resolved_op_ptr = try evalForm(allocator, body_op, fn_data.env);
                            defer vm.valueDeinit(&resolved_op_ptr.*, allocator);
                            var call_args: list.List = .empty;
                            errdefer call_args.deinit(allocator);
                            try call_args.append(allocator, try vm.shallowClone(&args_list.items[0], allocator));
                            return try callBuiltin(allocator, resolved_op_ptr, &call_args, env);
                        }
                    } else if (body_call.items.len == 3) {
                        // --- Pattern 3: (op param <literal>) or (op <literal> param) ---
                        // Only match when exactly one arg is the param and the other is a LITERAL
                        // (int, float, string, keyword, etc.) — NOT another symbol.
                        // This avoids cases like (* x x) where both args are the param.
                        const body_arg0 = &body_call.items[1];
                        const body_arg1 = &body_call.items[2];
                        const arg0_is_param = std.meta.activeTag(body_arg0.*) == .symbol and
                            std.mem.eql(u8, body_arg0.symbol, param_name);
                        const arg1_is_param = std.meta.activeTag(body_arg1.*) == .symbol and
                            std.mem.eql(u8, body_arg1.symbol, param_name);
                        const arg0_is_literal = std.meta.activeTag(body_arg0.*) != .symbol and
                            std.meta.activeTag(body_arg0.*) != .list;
                        const arg1_is_literal = std.meta.activeTag(body_arg1.*) != .symbol and
                            std.meta.activeTag(body_arg1.*) != .list;

                        if (arg0_is_param and arg1_is_literal) {
                            // (op param <literal>) — e.g. (+ n 1), (= n 0)
                            // Resolve operator from function's definition env (has ns_manager)
                            const resolved_op_ptr = try evalForm(allocator, body_op, fn_data.env);
                            defer vm.valueDeinit(&resolved_op_ptr.*, allocator);
                            var call_args: list.List = .empty;
                            errdefer call_args.deinit(allocator);
                            try call_args.append(allocator, try vm.shallowClone(&args_list.items[0], allocator));
                            try call_args.append(allocator, try vm.shallowClone(body_arg1, allocator));
                            return try callBuiltin(allocator, resolved_op_ptr, &call_args, env);
                        } else if (arg1_is_param and arg0_is_literal) {
                            // (op <literal> param) — e.g. (- 0 n)
                            // Resolve operator from function's definition env (has ns_manager)
                            const resolved_op_ptr = try evalForm(allocator, body_op, fn_data.env);
                            defer vm.valueDeinit(&resolved_op_ptr.*, allocator);
                            var call_args: list.List = .empty;
                            errdefer call_args.deinit(allocator);
                            try call_args.append(allocator, try vm.shallowClone(body_arg0, allocator));
                            try call_args.append(allocator, try vm.shallowClone(&args_list.items[0], allocator));
                            return try callBuiltin(allocator, resolved_op_ptr, &call_args, env);
                        }
                    }
                }
            }

            // Optimization: if function env has no local entries, skip clone
            // and create a thin wrapper pointing to the parent
            var new_env: vm.Env = undefined;
            const has_locals = !fn_data.env.entries.isEmpty();
            if (has_locals) {
                new_env = try fn_data.env.clone(allocator);
            } else {
                new_env = .{
                    .allocator = allocator,
                    .entries = phm.PersistentHashMap.empty(),
                    .parent = fn_data.env.parent,
                    .ns_manager = null,
                };
            }
            defer new_env.deinit(allocator);

            // Bind function name for self-reference (e.g., (fn self [x] (self (dec x))))
            if (fn_data.name) |fn_name| {
                const fn_clone = try vm.shallowClone(f, allocator);
                try new_env.put(fn_name, fn_clone);
            }

            const min_args = arity.params.items.len;
            const has_rest = arity.rest_name != null;

            var i: usize = 0;
            while (i < arity.params.items.len) : (i += 1) {
                const param = &arity.params.items[i];
                try bindParam(allocator, param, &args_list.items[i], &new_env);
            }

            if (has_rest and args_list.items.len > min_args) {
                var rest_list: list.List = .empty;
                errdefer rest_list.deinit(allocator);
                var j: usize = min_args;
                while (j < args_list.items.len) : (j += 1) {
                    try rest_list.append(allocator, try vm.shallowClone(&args_list.items[j], allocator));
                }
                try new_env.put(arity.rest_name.?, try vm.listValue(allocator, rest_list));
            } else if (has_rest) {
                try new_env.put(arity.rest_name.?, try vm.listValue(allocator, .empty));
            }

            // Check for protocol dispatch marker in body
            if (arity.body.items.len >= 1 and
                std.meta.activeTag(arity.body.items[0]) == .symbol and
                std.mem.eql(u8, arity.body.items[0].symbol, "__protocol_dispatch__"))
            {
                const protocols_mod = @import("../../namespaces/core/protocols.zig");
                const result = try protocols_mod.dispatchProtocolMethod(allocator, args_list.*, &new_env, 0);
                new_env.deinit(allocator);
                return try allocBuiltinResult(allocator, result);
            }

            // Check for bytecode — if available, use the bytecode VM
            if (arity.bytecode) |bc| {
                const bytecode_mod = @import("../../bytecode.zig");
                const vm_result = try bytecode_mod.execute(allocator, bc, &new_env);
                switch (vm_result) {
                    .value => |v| {
                        new_env.deinit(allocator);
                        return v;
                    },
                    .trampoline => {
                        // A user-defined function was called from within the bytecode.
                        // Fall back to AST interpreter — do NOT deinit new_env, evalBody needs it.
                    },
                }
            }

            return try evalBody(allocator, &arity.body, &new_env);
        },
        .builtin_fn => {
            var f_mut = f.*;
            const result = try f_mut.builtin_fn(&f_mut, args_list, env);
            return try allocBuiltinResult(allocator, result);
        },
        .keyword => {
            // Keyword as function: looks up the keyword in a map or record
            if (args_list.items.len != 1) return error.ArityError;
            const coll = &args_list.items[0];
            if (std.meta.activeTag(coll.*) == .map) {
                for (coll.map.entries.items) |entry| {
                    if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, f.keyword)) {
                        return try allocBuiltinResult(allocator, try vm.shallowClone(&entry.value, allocator));
                    }
                }
            } else if (std.meta.activeTag(coll.*) == .record) {
                for (coll.record.fields.items) |entry| {
                    if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, f.keyword)) {
                        return try allocBuiltinResult(allocator, try vm.shallowClone(&entry.value, allocator));
                    }
                }
                for (coll.record.extmap.items) |entry| {
                    if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, f.keyword)) {
                        return try allocBuiltinResult(allocator, try vm.shallowClone(&entry.value, allocator));
                    }
                }
            }
            return try allocBuiltinResult(allocator, vm.nilValue());
        },
        .map => {
            // Map as function: looks up key in map, returns nil if not found
            if (args_list.items.len < 1 or args_list.items.len > 2) return error.ArityError;
            const key = &args_list.items[0];
            for (f.map.entries.items) |entry| {
                if (vm.equals(entry.key, key.*)) {
                    return try allocBuiltinResult(allocator, try vm.shallowClone(&entry.value, allocator));
                }
            }
            if (args_list.items.len == 2) {
                return try allocBuiltinResult(allocator, try vm.shallowClone(&args_list.items[1], allocator));
            }
            return try allocBuiltinResult(allocator, vm.nilValue());
        },
        .set => {
            // Set as function: returns the element if present, nil otherwise
            if (args_list.items.len != 1) return error.ArityError;
            const key = &args_list.items[0];
            for (f.set.items.items) |item| {
                if (vm.equals(item, key.*)) {
                    return try allocBuiltinResult(allocator, try vm.shallowClone(&item, allocator));
                }
            }
            return try allocBuiltinResult(allocator, vm.nilValue());
        },
        .record => {
            // Record as function: looks up key in fields or extmap
            if (args_list.items.len < 1 or args_list.items.len > 2) return error.ArityError;
            const key = &args_list.items[0];
            for (f.record.fields.items) |entry| {
                if (vm.equals(entry.key, key.*)) {
                    return try allocBuiltinResult(allocator, try vm.shallowClone(&entry.value, allocator));
                }
            }
            for (f.record.extmap.items) |entry| {
                if (vm.equals(entry.key, key.*)) {
                    return try allocBuiltinResult(allocator, try vm.shallowClone(&entry.value, allocator));
                }
            }
            if (args_list.items.len == 2) {
                return try allocBuiltinResult(allocator, try vm.shallowClone(&args_list.items[1], allocator));
            }
            return try allocBuiltinResult(allocator, vm.nilValue());
        },
        else => {
            std.debug.print("NotCallable in eval_helpers: type={s}\n", .{@tagName(std.meta.activeTag(f.*))});
            return error.NotCallable;
        }
    }
}

fn allocBuiltinResult(allocator: Allocator, val: Value) anyerror!*Value {
    const ptr = try allocator.create(Value);
    ptr.* = val;
    return ptr;
}

pub fn evalBody(allocator: Allocator, body: *const list.List, env: *vm.Env) anyerror!*Value {
    if (body.items.len == 0) return try allocBuiltinResult(allocator, vm.nilValue());
    var cloned_body: list.List = .empty;
    errdefer cloned_body.deinit(allocator);
    try cloned_body.ensureTotalCapacity(allocator, body.items.len);
    for (body.items) |item| {
        try cloned_body.append(allocator, try vm.shallowClone(&item, allocator));
    }
    return try evalForm(allocator, &(try vm.listValue(allocator, cloned_body)), env);
}

/// Main evaluation dispatcher — routes to type-specific evaluators.
pub fn evalForm(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    switch (std.meta.activeTag(form.*)) {
        .nil, .bool, .integer, .float, .string, .keyword => return evalSelfEvaluating(allocator, form),
        .symbol => return evalSymbol(allocator, form, env),
        .list => return evalList(allocator, form, env),
        .vector => return evalVector(allocator, form, env),
        .cons => return evalCons(allocator, form, env),
        else => return try allocBuiltinResult(allocator, try vm.shallowClone(form, allocator)),
    }
}

// ============================================================================
// Type-specific evaluators
// Each function handles evaluation for one vm.Type, moving all the
// type-specific details out of the main dispatcher.
// ============================================================================

/// Self-evaluating types return a clone of themselves.
fn evalSelfEvaluating(allocator: Allocator, form: *const Value) anyerror!*Value {
    return try allocBuiltinResult(allocator, try vm.shallowClone(form, allocator));
}

/// Evaluate a symbol: resolve it in the environment.
/// Handles qualified symbols (alias/name or namespace/name) and unqualified symbols.
fn evalSymbol(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    // Handle qualified symbols: alias/name or namespace/name
    if (std.mem.indexOfScalar(u8, form.symbol, '/')) |slash_idx| {
        return evalQualifiedSymbol(allocator, form.symbol, slash_idx, env);
    }
    return evalUnqualifiedSymbol(allocator, form.symbol, env);
}

fn evalQualifiedSymbol(allocator: Allocator, sym: []const u8, slash_idx: usize, env: *vm.Env) anyerror!*Value {
    const alias = sym[0..slash_idx];
    const name = sym[slash_idx + 1 ..];
    const ns_mgr = eval_ns.findNsManager(env) orelse {
        return fallbackSymbolLookup(allocator, sym, env);
    };
    const current_ns = ns_mgr.getCurrentNamespace();
    const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
    const target_env = ns_mgr.getNamespace(target_ns) orelse {
        return fallbackSymbolLookup(allocator, sym, env);
    };
    const val = target_env.get(name);
    if (val) |v| return try allocBuiltinResult(allocator, try vm.shallowClone(&v, allocator));
    return fallbackSymbolLookup(allocator, sym, env);
}

fn evalUnqualifiedSymbol(allocator: Allocator, sym: []const u8, env: *vm.Env) anyerror!*Value {
    if (env.get(sym)) |v| return try allocBuiltinResult(allocator, try vm.shallowClone(&v, allocator));
    std.debug.print("Undefined symbol: '{s}'\n", .{sym});
    return error.UndefinedSymbol;
}

/// Fallback: try direct env lookup, then report undefined.
fn fallbackSymbolLookup(allocator: Allocator, sym: []const u8, env: *vm.Env) anyerror!*Value {
    const val = env.get(sym);
    if (val) |v| return try allocBuiltinResult(allocator, try vm.shallowClone(&v, allocator));
    std.debug.print("Undefined symbol: '{s}'\n", .{sym});
    return error.UndefinedSymbol;
}

/// Evaluate a list: dispatch to special form handler or function call.
fn evalList(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    const items = form.list.items.items;
    if (items.len == 0) return try allocBuiltinResult(allocator, try vm.listValue(allocator, list.empty()));

    const first = &items[0];
    if (std.meta.activeTag(first.*) == .symbol) {
        if (std.mem.eql(u8, first.symbol, "quote")) return evalQuote(allocator, form);
        if (std.mem.eql(u8, first.symbol, "quasiquote")) return evalQuasiquote(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "do")) return evalDo(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "if")) return evalIf(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "when")) return evalWhen(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "and")) return evalAnd(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "or")) return evalOr(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "cond")) return evalCond(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "let")) return evalLet(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "fn")) return evalFn(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "lazy-seq")) return evalLazySeq(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "loop")) return evalLoop(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "recur")) return evalRecur(allocator, form, env);
        if (std.mem.eql(u8, first.symbol, "__protocol_dispatch__")) return evalProtocolDispatch(allocator, form, env);
    }

    // Non-special-form: evaluate as function call
    return evalFunctionCall(allocator, form, env);
}

/// (__protocol_dispatch__) — dispatch a protocol method call.
/// The form contains the protocol dispatch metadata in metadata and the
/// actual arguments as items[1:].
fn evalProtocolDispatch(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    const protocols_mod = @import("../../namespaces/core/protocols.zig");
    // The form is (__protocol_dispatch__ arg1 arg2 ...) where args are already evaluated
    const items = form.list.items.items;
    if (items.len < 2) return error.ArityError;

    // Build args list from items[1..]
    var args_list: list.List = .empty;
    defer args_list.deinit(allocator);
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        try args_list.append(allocator, try vm.shallowClone(&items[i], allocator));
    }

    const result = try protocols_mod.dispatchProtocolMethod(allocator, args_list, env, 0);
    return try allocBuiltinResult(allocator, result);
}

/// (quote form) — return form unevaluated.
fn evalQuote(allocator: Allocator, form: *const Value) anyerror!*Value {
    if (form.list.items.items.len != 2) return error.ArityError;
    return try allocBuiltinResult(allocator, try vm.shallowClone(&form.list.items.items[1], allocator));
}

/// (quasiquote form) — template with unquote.
fn evalQuasiquote(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len != 2) return error.ArityError;
    // Create a temporary Frame from the Env so unquoteProcess can resolve bindings
    const frame_ptr = try allocator.create(vm.Frame);
    errdefer allocator.destroy(frame_ptr);
    frame_ptr.* = vm.Frame.init(allocator, null, env);
    // Register with GC so it doesn't get swept during evaluation
    if (gc_mod.current_gc) |gc| {
        gc.addRoot(@as(*anyopaque, @ptrCast(frame_ptr)));
        defer gc.removeRoot(@as(*anyopaque, @ptrCast(frame_ptr)));
    }
    defer frame_ptr.deinit(allocator);
    const result = try eval_macro.unquoteProcess(allocator, form.list.items.items[1], frame_ptr, 0);
    return try allocBuiltinResult(allocator, result);
}

/// (do body...) — evaluate a sequence of forms, return last.
fn evalDo(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    return evalDoSlice(allocator, form.list.items.items[1..], env);
}

/// (if test then then else?) — conditional.
fn evalIf(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len < 3) return error.ArityError;
    const test_ptr = try evalForm(allocator, &form.list.items.items[1], env);
    const truthy = vm.isTruthy(test_ptr.*);
    vm.valueDeinit(&test_ptr.*, allocator);
    allocator.destroy(test_ptr);
    if (truthy) {
        return try evalForm(allocator, &form.list.items.items[2], env);
    } else if (form.list.items.items.len >= 4) {
        return try evalForm(allocator, &form.list.items.items[3], env);
    } else {
        return try allocBuiltinResult(allocator, vm.nilValue());
    }
}

/// (when test body...) — if with implicit do.
fn evalWhen(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len < 3) return error.ArityError;
    const test_ptr = try evalForm(allocator, &form.list.items.items[1], env);
    const truthy = vm.isTruthy(test_ptr.*);
    vm.valueDeinit(&test_ptr.*, allocator);
    allocator.destroy(test_ptr);
    if (truthy) {
        return evalDoSlice(allocator, form.list.items.items[2..], env);
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// Evaluate a slice of forms as a do block (return last value).
fn evalDoSlice(allocator: Allocator, forms: []const Value, env: *vm.Env) anyerror!*Value {
    var last_ptr: ?*Value = null;
    errdefer {
        if (last_ptr) |p| { vm.valueDeinit(&p.*, allocator); allocator.destroy(p); }
    }
    for (forms) |arg| {
        if (last_ptr) |p| { vm.valueDeinit(&p.*, allocator); allocator.destroy(p); }
        last_ptr = try evalForm(allocator, &arg, env);
    }
    if (last_ptr) |p| {
        const result = p.*;
        allocator.destroy(p);
        return try allocBuiltinResult(allocator, result);
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// (and form*) — short-circuit and.
fn evalAnd(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len == 1) return try allocBuiltinResult(allocator, vm.boolValue(true));
    var i: usize = 1;
    while (i < form.list.items.items.len) : (i += 1) {
        const val_ptr = try evalForm(allocator, &form.list.items.items[i], env);
        if (!vm.isTruthy(val_ptr.*)) {
            return val_ptr;
        }
        if (i == form.list.items.items.len - 1) {
            return val_ptr;
        }
        vm.valueDeinit(&val_ptr.*, allocator);
        allocator.destroy(val_ptr);
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// (or form*) — short-circuit or.
fn evalOr(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len == 0) return try allocBuiltinResult(allocator, vm.nilValue());
    var i: usize = 1;
    while (i < form.list.items.items.len) : (i += 1) {
        const val_ptr = try evalForm(allocator, &form.list.items.items[i], env);
        if (vm.isTruthy(val_ptr.*)) return val_ptr;
        vm.valueDeinit(&val_ptr.*, allocator);
        allocator.destroy(val_ptr);
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// (cond test1 result1 test2 result2 ...) — multi-way conditional.
fn evalCond(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    var i: usize = 1;
    while (i < form.list.items.items.len) : (i += 2) {
        if (i + 1 >= form.list.items.items.len) return error.ArityError;
        const test_ptr = try evalForm(allocator, &form.list.items.items[i], env);
        const truthy = vm.isTruthy(test_ptr.*);
        vm.valueDeinit(&test_ptr.*, allocator);
        allocator.destroy(test_ptr);
        if (truthy) {
            return try evalForm(allocator, &form.list.items.items[i + 1], env);
        }
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// (let [bindings] body...) — local bindings.
fn evalLet(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len < 3) return error.ArityError;
    const bindings = &form.list.items.items[1];
    if (std.meta.activeTag(bindings.*) != .list and std.meta.activeTag(bindings.*) != .vector) return error.TypeError;
    const bind_items = if (std.meta.activeTag(bindings.*) == .list) bindings.list.items.items else bindings.vector.items.items;

    var new_env = try env.clone(allocator);
    defer new_env.deinit(allocator);
    var bi: usize = 0;
    while (bi < bind_items.len) : (bi += 2) {
        const sym = &bind_items[bi];
        const val_ptr = try evalForm(allocator, &bind_items[bi + 1], &new_env);
        // Use bindPattern to support destructuring: [a b], [a & rest], nested
        try bindPattern(allocator, sym.*, val_ptr.*, &new_env);
    }

    return evalDoSlice(allocator, form.list.items.items[2..], &new_env);
}

/// (loop [bindings] body...) — loop with recur support.
fn evalLoop(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len < 2) return error.ArityError;
    const bindings = &form.list.items.items[1];
    const body = form.list.items.items[2..];

    const bind_items = if (std.meta.activeTag(bindings.*) == .list)
        bindings.list.items.items
    else
        bindings.vector.items.items;

    // Extract binding names
    var bind_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (bind_names.items) |name| allocator.free(name);
        allocator.free(bind_names.items);
    }
    var i: usize = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = &bind_items[i];
        if (std.meta.activeTag(sym.*) != .symbol) return error.TypeError;
        try bind_names.append(allocator, try allocator.dupe(u8, sym.symbol));
    }

    // Evaluate initial bindings and create env
    var loop_env = try env.clone(allocator);
    defer loop_env.deinit(allocator);
    i = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = &bind_items[i];
        const val_ptr = try evalForm(allocator, &bind_items[i + 1], &loop_env);
        try loop_env.put(sym.symbol, val_ptr.*);
    }

    // Push loop context for recur (stack-based for nested loops)
    try loop_stack.append(allocator, LoopContext{
        .env = &loop_env,
        .bind_names = bind_names.items,
        .body = body,
    });
    defer _ = loop_stack.pop();

    // Evaluate body, catching recur
    while (true) {
        const result = evalDoSlice(allocator, body, &loop_env) catch |err| {
            if (err == error.RecurLoop) continue;
            return err;
        };
        return result;
    }
}

/// (recur args...) — tail-call to nearest enclosing loop/fn.
fn evalRecur(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    // Evaluate args in caller's env (has access to let bindings like idx)
    const items = form.list.items.items;
    if (items.len < 2) return error.ArityError;
    const args = items[1..]; // skip 'recur' symbol

    if (loop_stack.items.len == 0) return error.RecurLoop; // recur outside loop
    const ctx = &loop_stack.items[loop_stack.items.len - 1];
    if (ctx.env == null) return error.RecurLoop;

    const loop_env = ctx.env.?;
    if (args.len != ctx.bind_names.len) {
        std.debug.print("RECUR ARITY MISMATCH: args={d} bindings={d} stack_depth={d}\n", .{ args.len, ctx.bind_names.len, loop_stack.items.len });
        return error.ArityError;
    }

    // Evaluate new values in caller's env, rebind in loop env
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const val_ptr = try evalForm(allocator, &args[i], env);
        try loop_env.put(ctx.bind_names[i], val_ptr.*);
    }

    return error.RecurLoop; // signal loop to restart
}

/// (fn name? ([params] body...)...) — anonymous function.
/// Handles single-arity, multi-arity, and & rest parameters.
fn evalFn(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len < 2) return error.ArityError;
    var idx: usize = 1;
    // Skip optional name for self-reference
    var fn_name: ?[]const u8 = null;
    if (std.meta.activeTag(form.list.items.items[idx]) == .symbol) {
        fn_name = try allocator.dupe(u8, form.list.items.items[idx].symbol);
        idx += 1;
    }
    if (idx >= form.list.items.items.len) return error.ArityError;

    // Check if this is multi-arity: first item is a list/vector whose first element
    // is also a list/vector (i.e., ([params] body...) is the first form).
    const first_form = &form.list.items.items[idx];
    const is_multi_arity = isMultiArityForm(first_form.*);

    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.rest_name) |rn| allocator.free(rn);
        }
        arities.deinit(allocator);
    }

    if (is_multi_arity) {
        // Multi-arity: each form is ([params] body...)
        var ai: usize = idx;
        while (ai < form.list.items.items.len) : (ai += 1) {
            const arity_form = &form.list.items.items[ai];
            const arity_items = if (std.meta.activeTag(arity_form.*) == .list)
                arity_form.*.list.items.items
            else
                arity_form.*.vector.items.items;
            if (arity_items.len < 2) return error.ArityError;

            // Parse params (extract & rest)
            const params_raw = if (std.meta.activeTag(arity_items[0]) == .vector)
                try helpers.listFromVector(allocator, arity_items[0].vector.items)
            else
                arity_items[0].list.items;
            var parsed = try parseParams(allocator, params_raw);

            // Build body: (do body...)
            var body_list: list.List = .empty;
            errdefer body_list.deinit(allocator);
            try body_list.append(allocator, try vm.symValue(allocator, "do"));
            for (arity_items[1..]) |form_item| {
                try body_list.append(allocator, try vm.shallowClone(&form_item, allocator));
            }

            try arities.append(allocator, vm.Arity{
                .params = try parsed.params.clone(allocator),
                .body = try body_list.clone(allocator),
                .rest_name = parsed.rest_name,
                .bytecode = null,
            });
            // Clean up parsed (clone was made above)
            parsed.params.deinit(allocator);
            if (parsed.rest_name) |rn| allocator.free(rn);
        }
    } else {
        // Single-arity: ([params] body...)
        const params_raw = if (std.meta.activeTag(first_form.*) == .vector)
            try helpers.listFromVector(allocator, first_form.*.vector.items)
        else
            first_form.*.list.items;
        var parsed = try parseParams(allocator, params_raw);
        const body = if (form.list.items.items.len >= idx + 1) form.list.items.items[idx + 1 ..] else &[_]Value{};

        var body_list: list.List = .empty;
        errdefer body_list.deinit(allocator);
        try body_list.append(allocator, try vm.symValue(allocator, "do"));
        for (body) |form_item| {
            try body_list.append(allocator, try vm.shallowClone(&form_item, allocator));
        }

        try arities.append(allocator, vm.Arity{
            .params = try parsed.params.clone(allocator),
            .body = try body_list.clone(allocator),
            .rest_name = parsed.rest_name,
            .bytecode = null,
        });
        parsed.params.deinit(allocator);
        if (parsed.rest_name) |rn| allocator.free(rn);
    }

    const fn_env = try env.clone(allocator);
    return try allocBuiltinResult(allocator, try vm.fnValueNamed(allocator, arities, fn_env, false, fn_name));
}

/// (lazy-seq body...) — create a lazy sequence.
fn evalLazySeq(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len < 2) return error.ArityError;
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "do"));
    for (form.list.items.items[1..]) |f_item| {
        try body.append(allocator, try vm.shallowClone(&f_item, allocator));
    }
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = body,
        .env = try env.clone(allocator),
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
    }
    return try allocBuiltinResult(allocator, vm.lazySeqValue(thunk));
}

/// Evaluate a non-special-form list as a function call.
/// Handles macro expansion and normal function application.
fn evalFunctionCall(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    const first = &form.list.items.items[0];
    const op_ptr = try evalForm(allocator, first, env);
    defer vm.valueDeinit(&op_ptr.*, allocator);
    defer allocator.destroy(op_ptr);

    // Check if operator is a macro
    if (std.meta.activeTag(op_ptr.*) == .function and op_ptr.function.is_macro) {
        var macro_args: list.List = .empty;
        errdefer macro_args.deinit(allocator);
        for (form.list.items.items[1..]) |arg| {
            try macro_args.append(allocator, try vm.shallowClone(&arg, allocator));
        }
        const expanded_ptr = try callBuiltin(allocator, op_ptr, &macro_args, env);
        const result = try evalForm(allocator, expanded_ptr, env);
        vm.valueDeinit(&expanded_ptr.*, allocator);
        allocator.destroy(expanded_ptr);
        return result;
    }

    // Evaluate all arguments and call the function
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    for (form.list.items.items[1..]) |arg| {
        const arg_ptr = try evalForm(allocator, &arg, env);
        try args.append(allocator, arg_ptr.*);
    }
    return try callBuiltin(allocator, op_ptr, &args, env);
}

/// Evaluate a vector: evaluate each element.
fn evalVector(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(allocator);
    for (form.vector.items.items) |item| {
        const item_ptr = try evalForm(allocator, &item, env);
        try new_vec.append(allocator, item_ptr.*);
    }
    return try allocBuiltinResult(allocator, try vm.vectorValue(allocator, new_vec));
}

/// Evaluate a cons cell: convert to list, then evaluate as a list.
fn evalCons(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    // Convert cons chain to a list
    var cons_list: list.List = .empty;
    errdefer cons_list.deinit(allocator);
    var c = form.*;
    while (std.meta.activeTag(c) == .cons) {
        const cdata = c.cons;
        try cons_list.append(allocator, try vm.shallowClone(&cdata.head, allocator));
        c = try vm.shallowClone(&cdata.tail, allocator);
    }
    if (std.meta.activeTag(c) == .list) {
        for (c.list.items.items) |item| {
            try cons_list.append(allocator, try vm.shallowClone(&item, allocator));
        }
    } else if (std.meta.activeTag(c) != .nil) {
        try cons_list.append(allocator, c);
    }
    vm.valueDeinit(&c, allocator);

    // Evaluate the list
    if (cons_list.items.len == 0) {
        return try allocBuiltinResult(allocator, try vm.listValue(allocator, list.empty()));
    }
    const first_item = &cons_list.items[0];
    if (std.meta.activeTag(first_item.*) == .symbol) {
        // Special form: re-create as a proper list
        var proper_list: list.List = .empty;
        errdefer proper_list.deinit(allocator);
        for (cons_list.items) |item| {
            try proper_list.append(allocator, item);
        }
        const list_val = try vm.listValue(allocator, proper_list);
        return try evalForm(allocator, &list_val, env);
    }
    // Non-symbol operator: evaluate normally
    const op_ptr = try evalForm(allocator, first_item, env);
    defer vm.valueDeinit(&op_ptr.*, allocator);
    defer allocator.destroy(op_ptr);
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    for (cons_list.items[1..]) |arg| {
        const arg_ptr = try evalForm(allocator, &arg, env);
        try args.append(allocator, arg_ptr.*);
    }
    return try callBuiltin(allocator, op_ptr, &args, env);
}

/// macroexpand-1: expand a macro call once, or return the form unchanged.
/// Takes a single argument: the form to expand.
pub fn core_macroexpand_1(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const form = &args.items[0];

    // Only lists can be macro calls
    if (std.meta.activeTag(form.*) != .list or form.*.list.items.items.len == 0) {
        return try vm.shallowClone(form, env_env.allocator);
    }

    const allocator = env_env.allocator;
    const first = &form.list.items.items[0];

    // Resolve the operator
    var op: Value = undefined;
    if (std.meta.activeTag(first.*) == .symbol) {
        if (env_env.get(first.*.symbol)) |v| {
            op = try vm.shallowClone(&v, allocator);
        } else {
            // Symbol not found - return form unchanged
            return try vm.shallowClone(form, allocator);
        }
    } else {
        // Not a symbol - return form unchanged
        return try vm.shallowClone(form, allocator);
    }
    defer vm.valueDeinit(&op, allocator);

    // Check if operator is a macro
    if (std.meta.activeTag(op) == .function and op.function.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        defer macro_args.deinit(allocator);
        for (form.list.items.items[1..]) |arg| {
            try macro_args.append(allocator, try vm.shallowClone(&arg, allocator));
        }
        // Call the macro with unevaluated args and return the result WITHOUT evaluating
        const result_ptr = try callBuiltin(allocator, &op, &macro_args, env_env);
        const result = result_ptr.*;
        allocator.destroy(result_ptr);
        return result;
    }

    // Not a macro - return form unchanged
    return try vm.shallowClone(form, allocator);
}

/// macroexpand: repeatedly expand macros until no more expansion.
/// Takes a single argument: the form to expand.
pub fn core_macroexpand(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;

    var current = try vm.shallowClone(&args.items[0], env_env.allocator);
    errdefer vm.valueDeinit(&current, env_env.allocator);

    while (true) {
        var call_args: list.List = .empty;
        errdefer call_args.deinit(env_env.allocator);
        try call_args.append(env_env.allocator, try vm.shallowClone(&current, env_env.allocator));
        const expanded = try core_macroexpand_1(self, &call_args, env_env);
        vm.valueDeinit(&current, env_env.allocator);

        // Check if anything changed by comparing
        // If the expanded form is the same type and structure, stop
        if (std.meta.activeTag(expanded) != .list or expanded.list.items.items.len == 0) {
            return expanded;
        }
        const exp_first = expanded.list.items.items[0];
        if (std.meta.activeTag(exp_first) != .symbol) {
            return expanded;
        }
        // Check if the expanded first element is a macro
        if (env_env.get(exp_first.symbol)) |v| {
            if (std.meta.activeTag(v) == .function and v.function.is_macro) {
                current = expanded;
                continue;
            }
        }
        return expanded;
    }
}
