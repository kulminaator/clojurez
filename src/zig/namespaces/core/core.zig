// Core built-in functions coordinator
// Imports from domain modules and provides higher-order functions (apply, partial, comp, fnil, juxt, etc.)
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;

// Domain modules
const arithmetic = @import("arithmetic.zig");
const comparison = @import("comparison.zig");
const type_predicates = @import("type_predicates.zig");
const strings = @import("strings.zig");
const sequences = @import("sequences.zig");
const chunks = @import("chunks.zig");
const seq_ops = @import("seq_ops.zig");
const seq_sort = @import("seq_sort.zig");
const maps = @import("maps.zig");
const sets = @import("sets.zig");
const collections = @import("collections.zig");
const io = @import("io.zig");
const atoms = @import("atoms.zig");
const bitwise = @import("bitwise.zig");
const random = @import("random.zig");
const gc_builtins = @import("gc.zig");
const eval_helpers = @import("eval_helpers.zig");
const regexp_core = @import("regexp.zig");
const records = @import("records.zig");
const namespace = @import("namespace.zig");
const threading = @import("threading.zig");

// ---- Collection predicates (empty?, not-empty, seq) ----

pub fn core_empty_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (std.meta.activeTag(coll)) {
        .list => coll.list.items.items.len,
        .vector => coll.vector.items.items.len,
        .map => coll.map.entries.items.len,
        .set => coll.set.items.items.len,
        .queue => coll.queue.items.items.len,
        .string => coll.string.len,
        else => return error.TypeError,
    };
    return vm.boolValue(len == 0);
}

pub fn core_not_empty(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (std.meta.activeTag(coll)) {
        .list => coll.list.items.items.len,
        .vector => coll.vector.items.items.len,
        .map => coll.map.entries.items.len,
        .set => coll.set.items.items.len,
        .queue => coll.queue.items.items.len,
        else => return vm.nilValue(),
    };
    if (len == 0) return vm.nilValue();
    return try vm.shallowClone(&coll, env_env.allocator);
}

// ---- Higher-order functions ----

// apply - apply function to a collection of arguments
pub fn core_apply(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];

    var call_args: list.List = .empty;
    errdefer call_args.deinit(env_env.allocator);

    var i: usize = 1;
    while (i < args.items.len - 1) : (i += 1) {
        try call_args.append(env_env.allocator, try vm.shallowClone(&args.items[i], env_env.allocator));
    }

    const coll = args.items[args.items.len - 1];
    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }
    for (items) |item| {
        try call_args.append(env_env.allocator, try vm.shallowClone(&item, env_env.allocator));
    }

    const result_ptr = try eval_helpers.callBuiltin(env_env.allocator, &f, &call_args, env_env);
    const result = result_ptr.*;
    env_env.allocator.destroy(result_ptr);
    return result;
}

// trampoline - calls f, if result is a fn calls it, repeats until non-fn result
pub fn core_trampoline(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len < 1) return error.ArityError;

    // Clone to main allocator — args may be on arena
    var current = try vm.shallowClone(&args.items[0], allocator);
    if (args.items.len > 1) {
        var call_args: list.List = .empty;
        errdefer call_args.deinit(allocator);
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            try call_args.append(allocator, try vm.shallowClone(&args.items[i], allocator));
        }
        const result_ptr = try eval_helpers.callBuiltin(allocator, &current, &call_args, env_env);
        const new_current = result_ptr.*;
        allocator.destroy(result_ptr);
        vm.valueDeinit(&current, allocator);
        current = new_current;
    }

    var max_iterations: usize = 10000;
    while (max_iterations > 0) : (max_iterations -= 1) {
        if (std.meta.activeTag(current) != .function and std.meta.activeTag(current) != .builtin_fn) {
            return current;
        }
        const empty_args: list.List = .empty;
        const result_ptr = try eval_helpers.callBuiltin(allocator, &current, &empty_args, env_env);
        const new_current = result_ptr.*;
        allocator.destroy(result_ptr);
        vm.valueDeinit(&current, allocator);
        current = new_current;
    }
    vm.valueDeinit(&current, allocator);
    return error.StackOverflow;
}

// if-not - if test is false, evaluate then, else evaluate else (if provided)
pub fn core_if_not(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    const cond = args.items[0];
    if (!vm.isTruthy(cond)) {
        return try vm.shallowClone(&args.items[1], env_env.allocator);
    }
    if (args.items.len == 3) {
        return try vm.shallowClone(&args.items[2], env_env.allocator);
    }
    return vm.nilValue();
}

// partial - return a function that is a partial application of f
pub fn core_partial(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    try fn_env.put("__partial_fn", try vm.shallowClone(&f, env_env.allocator));
    var partial_args: list.List = .empty;
    errdefer partial_args.deinit(env_env.allocator);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        try partial_args.append(env_env.allocator, try vm.shallowClone(&args.items[i], env_env.allocator));
    }
    try fn_env.put("__partial_args", try vm.listValue(env_env.allocator, partial_args));

    var params_list: list.List = .empty;
    errdefer params_list.deinit(env_env.allocator);
    try params_list.append(env_env.allocator, try vm.symValue(env_env.allocator, "args"));

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try vm.symValue(env_env.allocator, "apply"));
    try body.append(env_env.allocator, try vm.symValue(env_env.allocator, "__partial_fn"));
    var concat_call: list.List = .empty;
    errdefer concat_call.deinit(env_env.allocator);
    try concat_call.append(env_env.allocator, try vm.symValue(env_env.allocator, "concat"));
    try concat_call.append(env_env.allocator, try vm.symValue(env_env.allocator, "__partial_args"));
    try concat_call.append(env_env.allocator, try vm.symValue(env_env.allocator, "args"));
    try body.append(env_env.allocator, try vm.listValue(env_env.allocator, concat_call));

    const cloned_params = try params_list.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    var final_env = try env_env.clone(env_env.allocator);
    try final_env.put("__partial_fn", try vm.shallowClone(&f, env_env.allocator));
    var stored_args: list.List = .empty;
    errdefer stored_args.deinit(env_env.allocator);
    i = 1;
    while (i < args.items.len) : (i += 1) {
        try stored_args.append(env_env.allocator, try vm.shallowClone(&args.items[i], env_env.allocator));
    }
    try final_env.put("__partial_args", try vm.listValue(env_env.allocator, stored_args));

    return try vm.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// comp - compose functions (right to left)
pub fn core_comp(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;

    if (args.items.len == 1) return try vm.shallowClone(&args.items[0], env_env.allocator);

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__comp_fn_{d}", .{i});
        try fn_env.put(key, try vm.shallowClone(&args.items[i], env_env.allocator));
    }

    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    try params.append(env_env.allocator, try vm.symValue(env_env.allocator, "x"));

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try vm.symValue(env_env.allocator, "do"));

    var current: Value = try vm.symValue(env_env.allocator, "x");
    var j: usize = args.items.len;
    while (j > 0) {
        j -= 1;
        const key = try std.fmt.allocPrint(env_env.allocator, "__comp_fn_{d}", .{j});
        var call: list.List = .empty;
        errdefer call.deinit(env_env.allocator);
        try call.append(env_env.allocator, try vm.symValue(env_env.allocator, key));
        try call.append(env_env.allocator, current);
        current = try vm.listValue(env_env.allocator, call);
    }

    try body.append(env_env.allocator, current);

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return try vm.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// fnil - provide default values for nil arguments
pub fn core_fnil(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];
    const defaults_count = args.items.len - 1;

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    try fn_env.put("__fnil_fn", try vm.shallowClone(&f, env_env.allocator));

    var d: usize = 0;
    while (d < defaults_count) : (d += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__fnil_default_{d}", .{d});
        try fn_env.put(key, try vm.shallowClone(&args.items[d + 1], env_env.allocator));
    }

    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    d = 0;
    while (d < defaults_count) : (d += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "a{d}", .{d});
        try params.append(env_env.allocator, try vm.symValue(env_env.allocator, key));
    }

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try vm.symValue(env_env.allocator, "apply"));
    try body.append(env_env.allocator, try vm.symValue(env_env.allocator, "__fnil_fn"));

    var list_call: list.List = .empty;
    errdefer list_call.deinit(env_env.allocator);
    try list_call.append(env_env.allocator, try vm.symValue(env_env.allocator, "list"));
    d = 0;
    while (d < defaults_count) : (d += 1) {
        const param_key = try std.fmt.allocPrint(env_env.allocator, "a{d}", .{d});
        const default_key = try std.fmt.allocPrint(env_env.allocator, "__fnil_default_{d}", .{d});

        var if_call: list.List = .empty;
        errdefer if_call.deinit(env_env.allocator);
        try if_call.append(env_env.allocator, try vm.symValue(env_env.allocator, "if"));

        var nil_q_call: list.List = .empty;
        errdefer nil_q_call.deinit(env_env.allocator);
        try nil_q_call.append(env_env.allocator, try vm.symValue(env_env.allocator, "nil?"));
        try nil_q_call.append(env_env.allocator, try vm.symValue(env_env.allocator, param_key));
        try if_call.append(env_env.allocator, try vm.listValue(env_env.allocator, nil_q_call));
        try if_call.append(env_env.allocator, try vm.symValue(env_env.allocator, default_key));
        try if_call.append(env_env.allocator, try vm.symValue(env_env.allocator, param_key));

        try list_call.append(env_env.allocator, try vm.listValue(env_env.allocator, if_call));
    }
    try body.append(env_env.allocator, try vm.listValue(env_env.allocator, list_call));

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return try vm.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// juxt - juxtaposition of functions
pub fn core_juxt(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__juxt_fn_{d}", .{i});
        try fn_env.put(key, try vm.shallowClone(&args.items[i], env_env.allocator));
    }

    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    try params.append(env_env.allocator, try vm.symValue(env_env.allocator, "x"));

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try vm.symValue(env_env.allocator, "do"));

    var vec_call: list.List = .empty;
    errdefer vec_call.deinit(env_env.allocator);
    try vec_call.append(env_env.allocator, try vm.symValue(env_env.allocator, "vec"));
    i = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__juxt_fn_{d}", .{i});
        var call: list.List = .empty;
        errdefer call.deinit(env_env.allocator);
        try call.append(env_env.allocator, try vm.symValue(env_env.allocator, key));
        try call.append(env_env.allocator, try vm.symValue(env_env.allocator, "x"));
        try vec_call.append(env_env.allocator, try vm.listValue(env_env.allocator, call));
    }
    try body.append(env_env.allocator, try vm.listValue(env_env.allocator, vec_call));

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return try vm.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// ---- Registration ----

pub fn registerCoreFunctions(env: *Env) anyerror!void {

    // Register all domain module functions
    try arithmetic.registerArithmeticFunctions(env);
    try comparison.registerComparisonFunctions(env);
    try type_predicates.registerTypePredicateFunctions(env);
    try strings.registerStringFunctions(env);
    try sequences.registerSequenceFunctions(env);
    try chunks.registerChunkFunctions(env);
    try seq_ops.registerSequenceOpFunctions(env);
    try seq_sort.registerSeqSortFunctions(env);
    try maps.registerMapFunctions(env);
    try sets.registerSetFunctions(env);
    try collections.registerCollectionFunctions(env);
    try io.registerIOFunctions(env);
    try atoms.registerAtomFunctions(env);
    try bitwise.registerBitwiseFunctions(env);
    try random.registerRandomFunctions(env);
    try gc_builtins.registerGCFunctions(env);
    try regexp_core.registerRegexpFunctions(env);
    try threading.registerThreadingFunctions(env);

    // Collection predicates (kept here)
    try env.put("empty?", vm.builtinFnValue(core_empty_q));
    try env.put("not-empty", vm.builtinFnValue(core_not_empty));

    // Higher-order functions (kept here)
    try env.put("apply", vm.builtinFnValue(core_apply));
    try env.put("trampoline", vm.builtinFnValue(core_trampoline));
    try env.put("record-ctor", vm.builtinFnValue(records.core_record_ctor));
    try env.put("if-not", vm.builtinFnValue(core_if_not));
    try env.put("partial", vm.builtinFnValue(core_partial));
    try env.put("comp", vm.builtinFnValue(core_comp));
    try env.put("fnil", vm.builtinFnValue(core_fnil));
    try env.put("juxt", vm.builtinFnValue(core_juxt));

    // Clojure-style aliases (re-registered for convenience)
    try env.put("not", vm.builtinFnValue(comparison.core_not));
    try env.put("str", vm.builtinFnValue(strings.core_str));
    try env.put("count", vm.builtinFnValue(sequences.core_count));
    try env.put("first", vm.builtinFnValue(sequences.core_first));
    try env.put("rest", vm.builtinFnValue(sequences.core_rest));
    try env.put("nth", vm.builtinFnValue(sequences.core_nth));
    try env.put("concat", vm.builtinFnValue(sequences.core_concat));
    try env.put("list", vm.builtinFnValue(sequences.core_list));
    try env.put("vec", vm.builtinFnValue(sequences.core_vec));
    try env.put("subs", vm.builtinFnValue(strings.core_subs));
    try env.put("subvec", vm.builtinFnValue(sequences.core_subvec));

    // Metaprogramming
    try env.put("macroexpand-1", vm.builtinFnValue(eval_helpers.core_macroexpand_1));
    try env.put("macroexpand", vm.builtinFnValue(eval_helpers.core_macroexpand));

    // Namespace functions (from namespace.zig)
    try namespace.registerNamespaceFunctions(env);

    // defn is handled as a special form alias in the evaluator
}
