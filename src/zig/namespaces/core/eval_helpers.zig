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

const Allocator = std.mem.Allocator;

// Bind a parameter to an argument, supporting destructuring
fn bindParam(allocator: Allocator, param: *const Value, arg: *const Value, env: *vm.Env) anyerror!void {
    switch (std.meta.activeTag(param.*)) {
        .symbol => {
            try env.put(param.symbol, try vm.clone(arg, allocator));
        },
        .vector => {
            var arg_items: []const Value = undefined;
            switch (std.meta.activeTag(arg.*)) {
                .list => arg_items = arg.list.items.items,
                .vector => arg_items = arg.vector.items.items,
                else => return error.TypeError,
            }
            if (param.vector.items.items.len != arg_items.len) return error.ArityError;
            var i: usize = 0;
            while (i < param.vector.items.items.len) : (i += 1) {
                try bindParam(allocator, &param.vector.items.items[i], &arg_items[i], env);
            }
        },
        .list => {
            if (param.list.items.items.len != arg.list.items.items.len) return error.ArityError;
            var i: usize = 0;
            while (i < param.list.items.items.len) : (i += 1) {
                try bindParam(allocator, &param.list.items.items[i], &arg.list.items.items[i], env);
            }
        },
        else => {},
    }
}

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
                            const resolved_op_ptr = try evalForm(allocator, body_op, env);
                            defer vm.valueDeinit(&resolved_op_ptr.*, allocator);
                            var call_args: list.List = .empty;
                            errdefer call_args.deinit(allocator);
                            try call_args.append(allocator, try vm.clone(&args_list.items[0], allocator));
                            try call_args.append(allocator, try vm.clone(&args_list.items[1], allocator));
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
                const fn_clone = try vm.clone(f, allocator);
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
                    try rest_list.append(allocator, try vm.clone(&args_list.items[j], allocator));
                }
                try new_env.put(arity.rest_name.?, try vm.listValue(allocator, rest_list));
            } else if (has_rest) {
                try new_env.put(arity.rest_name.?, try vm.listValue(allocator, .empty));
            }

            return try evalBody(allocator, &arity.body, &new_env);
        },
        .builtin_fn => {
            var f_mut = f.*;
            const result = try f_mut.builtin_fn(&f_mut, args_list, env);
            return try allocBuiltinResult(allocator, result);
        },
        .keyword => {
            // Keyword as function: looks up the keyword in a map
            if (args_list.items.len != 1) return error.ArityError;
            const coll = &args_list.items[0];
            if (std.meta.activeTag(coll.*) != .map) return try allocBuiltinResult(allocator, vm.nilValue());
            for (coll.map.entries.items) |entry| {
                if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, f.keyword)) {
                    return try allocBuiltinResult(allocator, try vm.clone(&entry.value, allocator));
                }
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
        try cloned_body.append(allocator, try vm.clone(&item, allocator));
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
        else => return try allocBuiltinResult(allocator, try vm.clone(form, allocator)),
    }
}

// ============================================================================
// Type-specific evaluators
// Each function handles evaluation for one vm.Type, moving all the
// type-specific details out of the main dispatcher.
// ============================================================================

/// Self-evaluating types return a clone of themselves.
fn evalSelfEvaluating(allocator: Allocator, form: *const Value) anyerror!*Value {
    return try allocBuiltinResult(allocator, try vm.clone(form, allocator));
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
    if (val) |v| return try allocBuiltinResult(allocator, try vm.clone(&v, allocator));
    return fallbackSymbolLookup(allocator, sym, env);
}

fn evalUnqualifiedSymbol(allocator: Allocator, sym: []const u8, env: *vm.Env) anyerror!*Value {
    if (env.get(sym)) |v| return try allocBuiltinResult(allocator, try vm.clone(&v, allocator));
    std.debug.print("Undefined symbol: '{s}'\n", .{sym});
    return error.UndefinedSymbol;
}

/// Fallback: try direct env lookup, then report undefined.
fn fallbackSymbolLookup(allocator: Allocator, sym: []const u8, env: *vm.Env) anyerror!*Value {
    const val = env.get(sym);
    if (val) |v| return try allocBuiltinResult(allocator, try vm.clone(&v, allocator));
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
    }

    // Non-special-form: evaluate as function call
    return evalFunctionCall(allocator, form, env);
}

/// (quote form) — return form unevaluated.
fn evalQuote(allocator: Allocator, form: *const Value) anyerror!*Value {
    if (form.list.items.items.len != 2) return error.ArityError;
    return try allocBuiltinResult(allocator, try vm.clone(&form.list.items.items[1], allocator));
}

/// (quasiquote form) — template with unquote.
fn evalQuasiquote(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len != 2) return error.ArityError;
    const result = try eval_macro.unquoteProcess(allocator, form.list.items.items[1], env, 0);
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
        if (std.meta.activeTag(sym.*) != .symbol) return error.TypeError;
        const val_ptr = try evalForm(allocator, &bind_items[bi + 1], &new_env);
        try new_env.put(sym.symbol, val_ptr.*);
    }

    return evalDoSlice(allocator, form.list.items.items[2..], &new_env);
}

/// (fn name? ([params] body...)...) — anonymous function.
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
    const params = &form.list.items.items[idx];
    if (std.meta.activeTag(params.*) != .list and std.meta.activeTag(params.*) != .vector) return error.TypeError;
    const params_list = if (std.meta.activeTag(params.*) == .vector) try helpers.listFromVector(allocator, params.vector.items) else params.list.items;
    const body = if (form.list.items.items.len >= idx + 1) form.list.items.items[idx + 1 ..] else &[_]Value{};

    var body_list: list.List = .empty;
    errdefer body_list.deinit(allocator);
    try body_list.append(allocator, try vm.symValue(allocator, "do"));
    for (body) |form_item| {
        try body_list.append(allocator, try vm.clone(&form_item, allocator));
    }
    const cloned_params = try params_list.clone(allocator);
    const cloned_body = try body_list.clone(allocator);
    const fn_env = try env.clone(allocator);
    return try allocBuiltinResult(allocator, try vm.fnValueSingleNamed(allocator, cloned_params, cloned_body, fn_env, null, false, fn_name));
}

/// (lazy-seq body...) — create a lazy sequence.
fn evalLazySeq(allocator: Allocator, form: *const Value, env: *vm.Env) anyerror!*Value {
    if (form.list.items.items.len < 2) return error.ArityError;
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "do"));
    for (form.list.items.items[1..]) |f_item| {
        try body.append(allocator, try vm.clone(&f_item, allocator));
    }
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = body,
        .env = try env.clone(allocator),
    };
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
            try macro_args.append(allocator, try vm.clone(&arg, allocator));
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
        try cons_list.append(allocator, try vm.clone(&cdata.head, allocator));
        c = try vm.clone(&cdata.tail, allocator);
    }
    if (std.meta.activeTag(c) == .list) {
        for (c.list.items.items) |item| {
            try cons_list.append(allocator, try vm.clone(&item, allocator));
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
        return try vm.clone(form, env_env.allocator);
    }

    const allocator = env_env.allocator;
    const first = &form.list.items.items[0];

    // Resolve the operator
    var op: Value = undefined;
    if (std.meta.activeTag(first.*) == .symbol) {
        if (env_env.get(first.*.symbol)) |v| {
            op = try vm.clone(&v, allocator);
        } else {
            // Symbol not found - return form unchanged
            return try vm.clone(form, allocator);
        }
    } else {
        // Not a symbol - return form unchanged
        return try vm.clone(form, allocator);
    }
    defer vm.valueDeinit(&op, allocator);

    // Check if operator is a macro
    if (std.meta.activeTag(op) == .function and op.function.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        defer macro_args.deinit(allocator);
        for (form.list.items.items[1..]) |arg| {
            try macro_args.append(allocator, try vm.clone(&arg, allocator));
        }
        // Call the macro with unevaluated args and return the result WITHOUT evaluating
        const result_ptr = try callBuiltin(allocator, &op, &macro_args, env_env);
        const result = result_ptr.*;
        allocator.destroy(result_ptr);
        return result;
    }

    // Not a macro - return form unchanged
    return try vm.clone(form, allocator);
}

/// macroexpand: repeatedly expand macros until no more expansion.
/// Takes a single argument: the form to expand.
pub fn core_macroexpand(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;

    var current = try vm.clone(&args.items[0], env_env.allocator);
    errdefer vm.valueDeinit(&current, env_env.allocator);

    while (true) {
        var call_args: list.List = .empty;
        errdefer call_args.deinit(env_env.allocator);
        try call_args.append(env_env.allocator, try vm.clone(&current, env_env.allocator));
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
