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

// Debug: track allocBuiltinResult calls
var debug_alloc_builtin_active: bool = false;
var debug_alloc_builtin_count: usize = 0;
var debug_alloc_builtin_limit: usize = 0;

pub fn debugAllocBuiltinStart(limit: usize) void {
    debug_alloc_builtin_active = true;
    debug_alloc_builtin_count = 0;
    debug_alloc_builtin_limit = limit;
}
pub fn debugAllocBuiltinStop() void {
    debug_alloc_builtin_active = false;
}

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
            // In GC model, val is passed by copy and GC keeps underlying data alive.
            // No clone needed — the HAMT stores a Value referencing the same GC-tracked data.
            try env.put(pattern.symbol, val);
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
                            try rest_list.append(allocator, vitems[k]);
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
                            try rest_list.append(allocator, vitems[k]);
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
            try regular_params.append(allocator, item);
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

pub fn callBuiltin(allocator: Allocator, f: *const Value, args: []const Value, env: *vm.Env) anyerror!*Value {
    switch (std.meta.activeTag(f.*)) {
        .function => {
            const fn_data = f.function;
            const arg_count = args.len;

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
                            // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
                            const resolved_op = try evalFormDirect(allocator, body_op, fn_data.env);
                            // Use stack array — no clone needed (GC keeps data alive), no deinit needed.
                            var args_arr: [2]Value = .{ args[0], args[1] };
                            var op_val = resolved_op;
                            return try callBuiltin(allocator, &op_val, &args_arr, env);
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
                    // identity: return the argument directly (no clone needed — GC keeps data alive)
                    return try allocBuiltinResult(allocator, args[0]);
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
                            // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
                            const resolved_op = try evalFormDirect(allocator, body_op, fn_data.env);
                            // Use stack array — no clone needed (GC keeps data alive), no deinit needed.
                            var args_arr: [1]Value = .{ args[0] };
                            var op_val = resolved_op;
                            return try callBuiltin(allocator, &op_val, &args_arr, env);
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
                            // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
                            const resolved_op = try evalFormDirect(allocator, body_op, fn_data.env);
                            // Use stack array — no clone needed (GC keeps data alive), no deinit needed.
                            var args_arr: [2]Value = .{ args[0], body_arg1.* };
                            var op_val = resolved_op;
                            return try callBuiltin(allocator, &op_val, &args_arr, env);
                        } else if (arg1_is_param and arg0_is_literal) {
                            // (op <literal> param) — e.g. (- 0 n)
                            // Resolve operator from function's definition env (has ns_manager)
                            // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
                            const resolved_op = try evalFormDirect(allocator, body_op, fn_data.env);
                            // Use stack array — no clone needed (GC keeps data alive), no deinit needed.
                            var args_arr: [2]Value = .{ body_arg0.*, args[0] };
                            var op_val = resolved_op;
                            return try callBuiltin(allocator, &op_val, &args_arr, env);
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
                const fn_clone = f.*;
                try new_env.put(fn_name, fn_clone);
            }

            const min_args = arity.params.items.len;
            const has_rest = arity.rest_name != null;

            var i: usize = 0;
            while (i < arity.params.items.len) : (i += 1) {
                const param = &arity.params.items[i];
                try bindParam(allocator, param, &args[i], &new_env);
            }

            if (has_rest and args.len > min_args) {
                var rest_list: list.List = .empty;
                errdefer rest_list.deinit(allocator);
                var j: usize = min_args;
                while (j < args.len) : (j += 1) {
                    try rest_list.append(allocator, args[j]);
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
                const args_wrapper = list.List{ .items = @constCast(args), .capacity = args.len };
                const result = try protocols_mod.dispatchProtocolMethod(allocator, args_wrapper, &new_env, 0);
                new_env.deinit(allocator);
                return try allocBuiltinResult(allocator, result);
            }

            // Check for bytecode — if available, use the bytecode VM
            if (debug_alloc_builtin_active) {
                const has_bc = arity.bytecode != null;
                std.debug.print("[CALL_BUILTIN] bytecode={s}\n", .{if (has_bc) "YES" else "NO"});
            }
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
            // Builtins expect *const list.List — create a thin wrapper around the slice.
            const args_wrapper: list.List = .{ .items = @constCast(args), .capacity = args.len };
            const result = try f_mut.builtin_fn(&f_mut, &args_wrapper, env);
            return try allocBuiltinResult(allocator, result);
        },
        .keyword => {
            // Keyword as function: looks up the keyword in a map or record
            if (args.len != 1) return error.ArityError;
            const coll = &args[0];
            if (std.meta.activeTag(coll.*) == .map) {
                for (coll.map.entries.items) |entry| {
                    if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, f.keyword)) {
                        return try allocBuiltinResult(allocator, entry.value);
                    }
                }
            } else if (std.meta.activeTag(coll.*) == .record) {
                for (coll.record.fields.items) |entry| {
                    if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, f.keyword)) {
                        return try allocBuiltinResult(allocator, entry.value);
                    }
                }
                for (coll.record.extmap.items) |entry| {
                    if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, f.keyword)) {
                        return try allocBuiltinResult(allocator, entry.value);
                    }
                }
            }
            return try allocBuiltinResult(allocator, vm.nilValue());
        },
        .map => {
            // Map as function: looks up key in map, returns nil if not found
            if (args.len < 1 or args.len > 2) return error.ArityError;
            const key = &args[0];
            for (f.map.entries.items) |entry| {
                if (vm.equals(entry.key, key.*)) {
                    return try allocBuiltinResult(allocator, entry.value);
                }
            }
            if (args.len == 2) {
                return try allocBuiltinResult(allocator, args[1]);
            }
            return try allocBuiltinResult(allocator, vm.nilValue());
        },
        .set => {
            // Set as function: returns the element if present, nil otherwise
            if (args.len != 1) return error.ArityError;
            const key = &args[0];
            for (f.set.items.items) |item| {
                if (vm.equals(item, key.*)) {
                    return try allocBuiltinResult(allocator, item);
                }
            }
            return try allocBuiltinResult(allocator, vm.nilValue());
        },
        .record => {
            // Record as function: looks up key in fields or extmap
            if (args.len < 1 or args.len > 2) return error.ArityError;
            const key = &args[0];
            for (f.record.fields.items) |entry| {
                if (vm.equals(entry.key, key.*)) {
                    return try allocBuiltinResult(allocator, entry.value);
                }
            }
            for (f.record.extmap.items) |entry| {
                if (vm.equals(entry.key, key.*)) {
                    return try allocBuiltinResult(allocator, entry.value);
                }
            }
            if (args.len == 2) {
                return try allocBuiltinResult(allocator, args[1]);
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
    if (debug_alloc_builtin_active) {
        if (debug_alloc_builtin_count >= debug_alloc_builtin_limit) {
            debug_alloc_builtin_active = false;
        } else {
            const src = @src();
            std.debug.print("[BUILTIN_RESULT #{d}] size=Value from {s}:{d} val_type={s}\n",
                .{ debug_alloc_builtin_count + 1, src.file, src.line, @tagName(std.meta.activeTag(val)) });
            debug_alloc_builtin_count += 1;
        }
    }
    const ptr = try allocator.create(Value);
    ptr.* = val;
    return ptr;
}

pub fn evalBody(allocator: Allocator, body: *const list.List, env: *vm.Env) anyerror!*Value {
    if (body.items.len == 0) return try allocBuiltinResult(allocator, vm.nilValue());
    // Body is stored as (do body...) for user-defined functions (from evalFn).
    // For partial/comp/fnil/juxt functions, body starts with the actual form.
    if (body.items.len >= 1 and
        std.meta.activeTag(body.items[0]) == .symbol and
        std.mem.eql(u8, body.items[0].symbol, "do"))
    {
        // Common case: skip "do" and evaluate body forms directly.
        // The body is part of the function definition (immutable, permanently rooted).
        return evalDoSlice(allocator, body.items[1..], env);
    }
    // Rare case: body doesn't start with "do" (partial, comp, fnil, juxt).
    // Clone and wrap in a list value for normal evaluation.
    const list_val = try vm.listValue(allocator, try body.clone(allocator));
    return try evalForm(allocator, &list_val, env);
}

/// Evaluate a form, returning Value by copy — no *Value allocation.
/// Use this instead of evalForm when the result is immediately consumed
/// (read, used, then discarded) rather than stored or returned.
/// Eliminates the allocBuiltinResult allocation for intermediate results.
pub fn evalFormDirect(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!Value {
    const ptr = try evalForm(allocator, form, env);
    const v = ptr.*;
    allocator.destroy(ptr); // no-op in GC allocator, but correct pattern
    return v;
}

/// Call a function, returning Value by copy — no *Value allocation.
/// Use this instead of callBuiltin when the result is immediately consumed
/// (read, used, then discarded) rather than stored or returned.
pub fn callBuiltinDirect(allocator: Allocator, f: *const Value, args: []const Value, env: *vm.Env) anyerror!Value {
    const ptr = try callBuiltin(allocator, f, args, env);
    const v = ptr.*;
    allocator.destroy(ptr); // no-op in GC allocator, but correct pattern
    return v;
}

/// Main evaluation dispatcher — routes to type-specific evaluators.
pub fn evalForm(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (debug_alloc_builtin_active) {
        if (debug_alloc_builtin_count < debug_alloc_builtin_limit) {
            std.debug.print("[EVAL_FORM] type={s}\n", .{@tagName(std.meta.activeTag(form.*))});
        }
    }
    switch (std.meta.activeTag(form.*)) {
        .nil, .bool, .integer, .float, .string, .keyword => return evalSelfEvaluating(allocator, form),
        .symbol => return evalSymbol(allocator, form, env),
        .list => return evalList(allocator, form, env),
        .vector => return evalVector(allocator, form, env),
        .cons => return evalCons(allocator, form, env),
        else => return try allocBuiltinResult(allocator, form.*),
    }
}

// ============================================================================
// Type-specific evaluators
// Each function handles evaluation for one vm.Type, moving all the
// type-specific details out of the main dispatcher.
// ============================================================================

/// Self-evaluating types return a clone of themselves.
fn evalSelfEvaluating(allocator: Allocator, form: *const Value) anyerror!*Value {
    return try allocBuiltinResult(allocator, form.*);
}

/// Self-evaluating types: return the input pointer directly — no allocation.
/// The form IS the value for nil, bool, integer, float, string, keyword.
/// The form is part of the AST (immutable, permanently rooted).
fn evalSelfRef(form: *const Value) *const Value {
    return form;
}

/// Resolve a symbol to a pointer into the env's HAMT — no allocation.
/// Returns *const Value pointing directly into the HAMT node.
/// Mirrors evalSymbol's logic but avoids shallowClone + allocBuiltinResult.
fn resolveSymbolRef(form: *const Value, env: *vm.Env) anyerror!*const Value {
    const sym = form.symbol;
    // Handle qualified symbols: alias/name or namespace/name
    if (std.mem.indexOfScalar(u8, sym, '/')) |slash_idx| {
        return resolveQualifiedSymbolRef(sym, slash_idx, env);
    }
    return resolveUnqualifiedSymbolRef(sym, env);
}

/// Resolve an unqualified symbol, returning pointer into HAMT.
/// Checks dynamic vars first (via ns_manager), then walks parent chain on entries.
fn resolveUnqualifiedSymbolRef(sym: []const u8, env: *vm.Env) anyerror!*const Value {
    // Check namespace manager dynamic vars first (visible across all function calls)
    var dyn_cursor: ?*vm.Env = env;
    while (dyn_cursor) |e| : (dyn_cursor = e.parent) {
        if (e.ns_manager) |ns_mgr| {
            if (!ns_mgr.dynamic_vars.isEmpty()) {
                if (ns_mgr.dynamic_vars.findPtr(phm.sym(sym))) |ptr| return ptr;
            }
            break;
        }
    }
    // Walk parent chain on entries HAMT
    if (env.getPtr(sym)) |ptr| return ptr;
    std.debug.print("Undefined symbol: '{s}'\n", .{sym});
    return error.UndefinedSymbol;
}

/// Resolve a qualified symbol (alias/name), returning pointer into HAMT.
fn resolveQualifiedSymbolRef(sym: []const u8, slash_idx: usize, env: *vm.Env) anyerror!*const Value {
    const alias = sym[0..slash_idx];
    const name = sym[slash_idx + 1 ..];
    const ns_mgr = eval_ns.findNsManager(env) orelse {
        return fallbackSymbolLookupRef(sym, env);
    };
    const current_ns = ns_mgr.getCurrentNamespace();
    const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
    const target_env = ns_mgr.getNamespace(target_ns) orelse {
        return fallbackSymbolLookupRef(sym, env);
    };
    if (target_env.getPtr(name)) |ptr| return ptr;
    return fallbackSymbolLookupRef(sym, env);
}

/// Fallback: try direct env.getPtr lookup, then report undefined.
fn fallbackSymbolLookupRef(sym: []const u8, env: *vm.Env) anyerror!*const Value {
    if (env.getPtr(sym)) |ptr| return ptr;
    std.debug.print("Undefined symbol: '{s}'\n", .{sym});
    return error.UndefinedSymbol;
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
    if (val) |v| return try allocBuiltinResult(allocator, v);
    return fallbackSymbolLookup(allocator, sym, env);
}

fn evalUnqualifiedSymbol(allocator: Allocator, sym: []const u8, env: *vm.Env) anyerror!*Value {
    if (env.get(sym)) |v| return try allocBuiltinResult(allocator, v);
    std.debug.print("Undefined symbol: '{s}'\n", .{sym});
    return error.UndefinedSymbol;
}

/// Fallback: try direct env lookup, then report undefined.
fn fallbackSymbolLookup(allocator: Allocator, sym: []const u8, env: *vm.Env) anyerror!*Value {
    const val = env.get(sym);
    if (val) |v| return try allocBuiltinResult(allocator, v);
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
        try args_list.append(allocator, items[i]);
    }

    const result = try protocols_mod.dispatchProtocolMethod(allocator, args_list, env, 0);
    return try allocBuiltinResult(allocator, result);
}

/// (quote form) — return form unevaluated.
fn evalQuote(allocator: Allocator, form: *const Value) anyerror!*Value {
    if (form.list.items.items.len != 2) return error.ArityError;
    return try allocBuiltinResult(allocator, form.list.items.items[1]);
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
    // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
    const test_val = try evalFormDirect(allocator, &form.list.items.items[1], env);
    if (vm.isTruthy(test_val)) {
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
    // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
    const test_val = try evalFormDirect(allocator, &form.list.items.items[1], env);
    if (vm.isTruthy(test_val)) {
        return evalDoSlice(allocator, form.list.items.items[2..], env);
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// Evaluate a slice of forms as a do block (return last value).
/// Phase 4: Non-final forms use evalFormDirect (Value by copy, no *Value allocation).
fn evalDoSlice(allocator: Allocator, forms: []const Value, env: *vm.Env) anyerror!*Value {
    if (forms.len == 0) return try allocBuiltinResult(allocator, vm.nilValue());
    // Non-tail forms: evaluate and discard (no *Value allocation)
    var i: usize = 0;
    while (i < forms.len - 1) : (i += 1) {
        _ = try evalFormDirect(allocator, &forms[i], env);
    }
    // Tail form: evaluate and return (needs *Value for caller)
    return try evalForm(allocator, &forms[forms.len - 1], env);
}

/// (and form*) — short-circuit and.
fn evalAnd(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len == 1) return try allocBuiltinResult(allocator, vm.boolValue(true));
    var i: usize = 1;
    while (i < form.list.items.items.len) : (i += 1) {
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const val = try evalFormDirect(allocator, &form.list.items.items[i], env);
        if (!vm.isTruthy(val)) {
            return try allocBuiltinResult(allocator, val);
        }
        if (i == form.list.items.items.len - 1) {
            return try allocBuiltinResult(allocator, val);
        }
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// (or form*) — short-circuit or.
fn evalOr(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len == 0) return try allocBuiltinResult(allocator, vm.nilValue());
    var i: usize = 1;
    while (i < form.list.items.items.len) : (i += 1) {
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const val = try evalFormDirect(allocator, &form.list.items.items[i], env);
        if (vm.isTruthy(val)) return try allocBuiltinResult(allocator, val);
    }
    return try allocBuiltinResult(allocator, vm.nilValue());
}

/// (cond test1 result1 test2 result2 ...) — multi-way conditional.
fn evalCond(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    var i: usize = 1;
    while (i < form.list.items.items.len) : (i += 2) {
        if (i + 1 >= form.list.items.items.len) return error.ArityError;
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const test_val = try evalFormDirect(allocator, &form.list.items.items[i], env);
        if (vm.isTruthy(test_val)) {
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
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const val = try evalFormDirect(allocator, &bind_items[bi + 1], &new_env);
        // Use bindPattern to support destructuring: [a b], [a & rest], nested
        try bindPattern(allocator, sym.*, val, &new_env);
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
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const val = try evalFormDirect(allocator, &bind_items[i + 1], &loop_env);
        try loop_env.put(sym.symbol, val);
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
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const val = try evalFormDirect(allocator, &args[i], env);
        try loop_env.put(ctx.bind_names[i], val);
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
                try body_list.append(allocator, form_item);
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
            try body_list.append(allocator, form_item);
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
        try body.append(allocator, f_item);
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
    // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
    const op_val = try evalFormDirect(allocator, first, env);

    // Check if operator is a macro
    if (std.meta.activeTag(op_val) == .function and op_val.function.is_macro) {
        var macro_args: list.List = .empty;
        errdefer macro_args.deinit(allocator);
        for (form.list.items.items[1..]) |arg| {
            try macro_args.append(allocator, arg);
        }
        const expanded_ptr = try callBuiltin(allocator, &op_val, macro_args.items, env);
        const expanded = expanded_ptr.*;
        allocator.destroy(expanded_ptr);
        return try evalForm(allocator, &expanded, env);
    }

    // Evaluate all arguments and call the function.
    // Use no-alloc paths for symbols and self-evaluating types.
    // For lists/vectors/cons (nested calls), use evalFormDirect which returns Value by copy.
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    for (form.list.items.items[1..]) |arg| {
        const arg_val: Value = switch (std.meta.activeTag(arg)) {
            // Symbol: resolve directly into HAMT — no allocation
            .symbol => blk: {
                const ptr = try resolveSymbolRef(&arg, env);
                break :blk ptr.*;
            },
            // Self-evaluating types: form IS the value — no allocation
            .nil, .bool, .integer, .float, .string, .keyword => evalSelfRef(&arg).*,
            // Lists, vectors, cons need evaluation (nested calls, etc.)
            // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
            .list, .vector, .cons => try evalFormDirect(allocator, &arg, env),
            // Everything else (regex, char, etc.): shallow clone via evalFormDirect
            else => try evalFormDirect(allocator, &arg, env),
        };
        try args.append(allocator, arg_val);
    }
    return try callBuiltin(allocator, &op_val, args.items, env);
}

/// Evaluate a vector: evaluate each element.
fn evalVector(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(allocator);
    for (form.vector.items.items) |item| {
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const val = try evalFormDirect(allocator, &item, env);
        try new_vec.append(allocator, val);
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
        try cons_list.append(allocator, cdata.head);
        c = cdata.tail;
    }
    if (std.meta.activeTag(c) == .list) {
        for (c.list.items.items) |item| {
            try cons_list.append(allocator, item);
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
    // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
    const op_val = try evalFormDirect(allocator, first_item, env);
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    for (cons_list.items[1..]) |arg| {
        // Phase 4: Use evalFormDirect — Value by copy, no *Value allocation
        const val = try evalFormDirect(allocator, &arg, env);
        try args.append(allocator, val);
    }
    return try callBuiltin(allocator, &op_val, args.items, env);
}

/// macroexpand-1: expand a macro call once, or return the form unchanged.
/// Takes a single argument: the form to expand.
pub fn core_macroexpand_1(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const form = &args.items[0];

    // Only lists can be macro calls
    if (std.meta.activeTag(form.*) != .list or form.*.list.items.items.len == 0) {
        return form.*;
    }

    const allocator = env_env.allocator;
    const first = &form.list.items.items[0];

    // Resolve the operator
    var op: Value = undefined;
    if (std.meta.activeTag(first.*) == .symbol) {
        if (env_env.get(first.*.symbol)) |v| {
            op = v;
        } else {
            // Symbol not found - return form unchanged
            return form.*;
        }
    } else {
        // Not a symbol - return form unchanged
        return form.*;
    }
    defer vm.valueDeinit(&op, allocator);

    // Check if operator is a macro
    if (std.meta.activeTag(op) == .function and op.function.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        defer macro_args.deinit(allocator);
        for (form.list.items.items[1..]) |arg| {
            try macro_args.append(allocator, arg);
        }
        // Call the macro with unevaluated args and return the result WITHOUT evaluating
        const result_ptr = try callBuiltin(allocator, &op, macro_args.items, env_env);
        const result = result_ptr.*;
        allocator.destroy(result_ptr);
        return result;
    }

    // Not a macro - return form unchanged
    return form.*;
}

/// macroexpand: repeatedly expand macros until no more expansion.
/// Takes a single argument: the form to expand.
pub fn core_macroexpand(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;

    var current = args.items[0];
    errdefer vm.valueDeinit(&current, env_env.allocator);

    while (true) {
        var call_args: list.List = .empty;
        errdefer call_args.deinit(env_env.allocator);
        try call_args.append(env_env.allocator, current);
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
