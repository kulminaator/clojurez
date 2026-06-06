const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = Value.Env;
const parser = @import("parser.zig");
const eval_helpers = @import("core/eval_helpers.zig");
const helpers = @import("core/helpers.zig");
const seq_ops = @import("core/seq_ops.zig");
const eval_thread = @import("eval_thread.zig");
const eval_macro = @import("eval_macro.zig");
const eval_ns = @import("eval_ns.zig");

const Allocator = std.mem.Allocator;

// Re-export findNsManager for use by main.zig and other modules
pub const findNsManager = eval_ns.findNsManager;

// Bind a symbol in the current namespace's env.
// If the env is the root env (has ns_manager), bind directly.
// Otherwise, bind in the current namespace's env.
pub fn bindInCurrentNamespace(env: *Env, name: []const u8, value: Value) anyerror!void {
    if (findNsManager(env)) |ns_mgr| {
        if (env.ns_manager != null) {
            try env.put(name, value);
        } else {
            const current_ns = ns_mgr.getCurrentNamespace();
            const ns_env = ns_mgr.getNamespace(current_ns) orelse env;
            try ns_env.put(name, value);
        }
    } else {
        try env.put(name, value);
    }
}

pub const EvalError = error{
    UndefinedSymbol,
    NotCallable,
    TypeError,
    ArityError,
    RecursionLimit,
    ReplExit,
    Recur, // internal: used by recur to signal loop/fn tail call
};

const MAX_RECURSION = 1000;

/// Main entry point for evaluation.
/// `allocator` — main allocator for values stored in env (persistent)
/// `arena_alloc` — arena allocator for temporary values (freed after expression)
/// When no arena is available, pass `allocator` for both.
pub fn eval(allocator: Allocator, arena_alloc: Allocator, form: Value, env: *Env) anyerror!Value {
    return evalRec(allocator, arena_alloc, form, env, 0);
}

// Force a lazy_map into a concrete list (for printing/display)
pub fn forceLazyMap(allocator: Allocator, arena_alloc: Allocator, lazy: Value, env: *Env) anyerror!Value {
    const lm: *Value.LazyMapData = lazy.lazy_map_val.?;
    var result: list.List = .empty;
    errdefer result.deinit(arena_alloc);

    // Use seq_ops.forceLazyMap to do the actual iteration
    var concrete = try seq_ops.forceLazyMap(allocator, lm, env);
    defer concrete.deinit(allocator);
    for (concrete.items) |item| {
        try result.append(arena_alloc, try item.clone(arena_alloc));
    }
    return Value.listValue(result);
}

pub fn evalRec(allocator: Allocator, arena_alloc: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    if (depth > MAX_RECURSION) return error.RecursionLimit;

    switch (form.type) {
        .nil, .bool, .integer, .float, .string, .keyword, .set, .queue, .atom, .lazy_map => {
            return try form.clone(arena_alloc);
        },
        .symbol => {
            if (std.mem.eql(u8, form.sym_val, "quote") or
                std.mem.eql(u8, form.sym_val, "quasiquote") or
                std.mem.eql(u8, form.sym_val, "unquote") or
                std.mem.eql(u8, form.sym_val, "unquote-splicing"))
            {
                return try form.clone(arena_alloc);
            }
            // Handle qualified symbols: alias/name or namespace/name
            if (std.mem.indexOfScalar(u8, form.sym_val, '/')) |slash_idx| {
                const alias = form.sym_val[0..slash_idx];
                const name = form.sym_val[slash_idx + 1 ..];
                // Resolve through namespace manager
                const ns_mgr = findNsManager(env) orelse {
                    const val2 = env.get(form.sym_val);
                    if (val2) |v| return try v.clone(arena_alloc);
                    return error.UndefinedSymbol;
                };
                // Look up alias in current namespace
                const current_ns = ns_mgr.getCurrentNamespace();
                const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse {
                    // Alias not found, try direct lookup
                    const val3 = env.get(form.sym_val);
                    if (val3) |v| return try v.clone(arena_alloc);
                    return error.UndefinedSymbol;
                };
                // Get target namespace's env and look up the name
                const target_env = ns_mgr.getNamespace(target_ns) orelse {
                    return error.UndefinedSymbol;
                };
                const val4 = target_env.get(name);
                if (val4) |v| return try v.clone(arena_alloc);
                return error.UndefinedSymbol;
            }
            const val = env.get(form.sym_val);
            if (val) |v| return try v.clone(arena_alloc);
            return error.UndefinedSymbol;
        },
        .list => {
            return try evalList(allocator, arena_alloc, form.list_val, env, depth);
        },
        .vector => {
            // Vectors evaluate element-wise
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(arena_alloc);
            for (form.vec_val.items) |item| {
                try new_vec.append(arena_alloc, try evalRec(allocator, arena_alloc, item, env, depth + 1));
            }
            return Value.vectorValue(new_vec);
        },
        .map => {
            // Maps evaluate key-value pairs element-wise
            var new_map: Value.Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    entry.key.deinit(arena_alloc);
                    entry.value.deinit(arena_alloc);
                }
                arena_alloc.free(new_map.items);
            }
            for (form.map_val.items) |entry| {
                try new_map.append(arena_alloc, .{
                    .key = try evalRec(allocator, arena_alloc, entry.key, env, depth + 1),
                    .value = try evalRec(allocator, arena_alloc, entry.value, env, depth + 1),
                });
            }
            return Value.mapValue(new_map);
        },
        .function, .builtin_fn => return try form.clone(arena_alloc),
        .lazy_seq => return try form.clone(arena_alloc),
    }
    unreachable;
}

// Parse ([params] body...)+ pairs from a list slice.
// Returns an ArrayListUnmanaged(Value.Arity) and updates *idx to point past the last consumed item.
fn parseArityForms(allocator: Allocator, arena_alloc: Allocator, items: []const Value, end: usize, idx: *usize) anyerror!std.ArrayListUnmanaged(Value.Arity) {
    var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(arena_alloc);
            a.body.deinit(arena_alloc);
            if (a.rest_name) |rn| arena_alloc.free(rn);
        }
        arena_alloc.free(arities.items);
    }

    while (idx.* < end) {
        const params_form = items[idx.*];
        if (params_form.type != .list and params_form.type != .vector) return error.TypeError;
        const params_list = if (params_form.type == .vector) try helpers.listFromVector(arena_alloc, params_form.vec_val) else params_form.list_val;
        idx.* += 1;

        // Collect body forms until next [params] or end
        const body_start = idx.*;
        while (idx.* < end) {
            const next = items[idx.*];
            if (looksLikeParamList(next) and idx.* + 1 < end) {
                break;
            }
            idx.* += 1;
        }
        const body_forms = items[body_start..idx.*];

        // Wrap body in a do block
        var body_list: list.List = .empty;
        errdefer body_list.deinit(arena_alloc);
        try body_list.append(arena_alloc, try Value.symValue(allocator, "do"));
        for (body_forms) |form_item| {
            try body_list.append(arena_alloc, try form_item.clone(arena_alloc));
        }

        // Parse params for variadic support (& rest)
        var parsed = try parseParams(arena_alloc, params_list);
        defer {
            parsed.params.deinit(arena_alloc);
            if (parsed.rest_name) |rn| arena_alloc.free(rn);
        }

        const cloned_params = try parsed.params.clone(arena_alloc);
        const cloned_body = try body_list.clone(arena_alloc);
        const cloned_rest = if (parsed.rest_name) |rn| try arena_alloc.dupe(u8, rn) else null;
        try arities.append(arena_alloc, Value.Arity{
            .params = cloned_params,
            .body = cloned_body,
            .rest_name = cloned_rest,
        });
    }

    return arities;
}

// Result of parsing a parameter list (may include variadic rest parameter)
const ParsedParams = struct {
    params: list.List,      // regular parameters (without & symbol)
    rest_name: ?[]const u8, // name of rest parameter, or null
};

// Parse a parameter list, extracting regular params and optional rest param.
// E.g., [a b & rest] => { params: (a b), rest_name: "rest" }
// E.g., [& args]     => { params: (), rest_name: "args" }
// E.g., [a b]        => { params: (a b), rest_name: null }
fn parseParams(arena_alloc: Allocator, params: list.List) anyerror!ParsedParams {
    var regular_params: list.List = .empty;
    errdefer regular_params.deinit(arena_alloc);
    var rest_name: ?[]const u8 = null;

    var i: usize = 0;
    var found_amp = false;
    while (i < params.items.len) : (i += 1) {
        const item = params.items[i];
        if (!found_amp and item.type == .symbol and std.mem.eql(u8, item.sym_val, "&")) {
            found_amp = true;
            continue;
        }
        if (found_amp) {
            // The symbol after & is the rest parameter name
            if (item.type != .symbol) return error.TypeError;
            rest_name = try arena_alloc.dupe(u8, item.sym_val);
            // No more params expected after rest
            break;
        } else {
            try regular_params.append(arena_alloc, try item.clone(arena_alloc));
        }
    }

    return ParsedParams{
        .params = regular_params,
        .rest_name = rest_name,
    };
}

fn evalList(allocator: Allocator, arena_alloc: Allocator, l: list.List, env: *Env, depth: usize) anyerror!Value {
    if (l.items.len == 0) return Value.listValue(list.empty());

    const first = l.items[0];

    // Self-evaluating symbols (special forms)
    if (first.type == .symbol) {
        const name = first.sym_val;

        // Special forms that don't evaluate their arguments
        // quit / exit - signal REPL to exit
        if (std.mem.eql(u8, name, "quit") or std.mem.eql(u8, name, "exit")) {
            return error.ReplExit;
        }

        // ns - namespace declaration
        // (ns namespace-name (:require [other.ns :as alias] ...))
        if (std.mem.eql(u8, name, "ns")) {
            return try eval_ns.evalNs(allocator, arena_alloc, l, env, depth);
        }

        if (std.mem.eql(u8, name, "quote")) {
            if (l.items.len != 2) return error.ArityError;
            return try l.items[1].clone(arena_alloc);
        }

        if (std.mem.eql(u8, name, "quasiquote")) {
            if (l.items.len != 2) return error.ArityError;
            return try eval_macro.unquoteProcess(allocator, arena_alloc, l.items[1], env, depth + 1);
        }

        // def - define in current namespace
        if (std.mem.eql(u8, name, "def")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            const docstring = if (l.items.len == 3 and l.items[2].type == .string)
                l.items[2]
            else null;
            const eval_idx: usize = if (l.items.len == 3 and l.items[2].type != .string) 2 else 1;
            var val = try evalRec(allocator, arena_alloc, l.items[eval_idx], env, depth + 1);
            // Clone to main allocator before storing in persistent env
            const persistent_val = try val.clone(allocator);
            val.deinit(arena_alloc);
            // Bind in current namespace's env if namespace manager is available
            try bindInCurrentNamespace(env, sym.sym_val, persistent_val);
            if (docstring) |ds| {
                _ = try ds.clone(arena_alloc); // keep docstring alive (simplified)
            }
            return try sym.clone(arena_alloc);
        }

        // let - local bindings
        if (std.mem.eql(u8, name, "let")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLet(allocator, arena_alloc, bindings, l.items[2..], env, depth + 1);
        }

        // letfn - define mutually recursive functions
        // (letfn [(name [params] body...)+] body...)
        if (std.mem.eql(u8, name, "letfn")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLetFn(allocator, arena_alloc, bindings, l.items[2..], env, depth + 1);
        }

        // if - conditional
        if (std.mem.eql(u8, name, "if")) {
            if (l.items.len < 2 or l.items.len > 4) return error.ArityError;
            const cond = try evalRec(allocator, arena_alloc, l.items[1], env, depth + 1);
            if (cond.isTruthy()) {
                if (l.items.len >= 3) return try evalRec(allocator, arena_alloc, l.items[2], env, depth + 1);
                return Value.nilValue();
            } else {
                if (l.items.len >= 4) return try evalRec(allocator, arena_alloc, l.items[3], env, depth + 1);
                return Value.nilValue();
            }
        }

        // when - (when test body...)
        if (std.mem.eql(u8, name, "when")) {
            if (l.items.len < 2) return error.ArityError;
            const cond = try evalRec(allocator, arena_alloc, l.items[1], env, depth + 1);
            if (cond.isTruthy()) {
                return try evalDo(allocator, arena_alloc, l.items[2..], env, depth + 1);
            }
            return Value.nilValue();
        }

        // cond - multi-way conditional
        if (std.mem.eql(u8, name, "cond")) {
            return try evalCond(allocator, arena_alloc, l.items[1..], env, depth + 1);
        }

        // defn - define a named function (supports multi-arity)
        // (defn name docstring? ([params] body...)+)
        if (std.mem.eql(u8, name, "defn")) {
            if (l.items.len < 3) return error.ArityError;
            const fname = l.items[1];
            if (fname.type != .symbol) return error.TypeError;
            // Handle optional docstring
            var idx: usize = 2;
            if (idx < l.items.len and l.items[idx].type == .string) {
                idx += 1;
            }
            if (idx >= l.items.len) return error.ArityError;

            var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
            errdefer {
                for (arities.items) |*a| {
                    a.params.deinit(arena_alloc);
                    a.body.deinit(arena_alloc);
                    if (a.rest_name) |rn| arena_alloc.free(rn);
                }
                arena_alloc.free(arities.items);
            }

            arities = try parseArityForms(allocator, arena_alloc, l.items, l.items.len, &idx);

            // Create fn_env with parent = env so it can see all global symbols
            // including the function itself (for recursion)
            const fn_env: Env = .{
                .allocator = allocator,
                .entries = .empty,
                .parent = env,
                .ns_manager = null,
            };
            var fn_val = Value.fnValue(arities, fn_env, false);
            // Clone to main allocator before storing in persistent env
            const persistent_fn = try fn_val.clone(allocator);
            fn_val.deinit(arena_alloc);
            // Bind in current namespace's env if namespace manager is available
            try bindInCurrentNamespace(env, fname.sym_val, persistent_fn);
            return try fname.clone(arena_alloc);
        }

        // fn - define a function (supports multi-arity)
        // (fn name? ([params] body...)+)
        if (std.mem.eql(u8, name, "fn")) {
            if (l.items.len < 2) return error.ArityError;
            var idx: usize = 1;
            // Skip optional name
            if (l.items[idx].type == .symbol) {
                idx += 1;
            }
            if (idx >= l.items.len) return error.ArityError;

            var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
            errdefer {
                for (arities.items) |*a| {
                    a.params.deinit(arena_alloc);
                    a.body.deinit(arena_alloc);
                    if (a.rest_name) |rn| arena_alloc.free(rn);
                }
                arena_alloc.free(arities.items);
            }

            arities = try parseArityForms(allocator, arena_alloc, l.items, l.items.len, &idx);

            // Clone env so the fn captures a stable copy of the environment
            const fn_env = try env.clone(arena_alloc);
            const fn_val = Value.fnValue(arities, fn_env, false);
            return fn_val;
        }

        // defmacro - define a macro (like defn but args are passed unevaluated)
        // (defmacro name docstring? ([params] body...)+)
        if (std.mem.eql(u8, name, "defmacro")) {
            if (l.items.len < 3) return error.ArityError;
            const macro_name = l.items[1];
            if (macro_name.type != .symbol) return error.TypeError;
            // Handle optional docstring
            var idx: usize = 2;
            if (idx < l.items.len and l.items[idx].type == .string) {
                idx += 1;
            }
            if (idx >= l.items.len) return error.ArityError;

            var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
            errdefer {
                for (arities.items) |*a| {
                    a.params.deinit(arena_alloc);
                    a.body.deinit(arena_alloc);
                    if (a.rest_name) |rn| arena_alloc.free(rn);
                }
                arena_alloc.free(arities.items);
            }

            arities = try parseArityForms(allocator, arena_alloc, l.items, l.items.len, &idx);

            const fn_env: Env = .{
                .allocator = allocator,
                .entries = .empty,
                .parent = env,
                .ns_manager = null,
            };
            var macro_fn = Value.fnValue(arities, fn_env, true);
            // Clone to main allocator before storing in persistent env
            const persistent_macro = try macro_fn.clone(allocator);
            macro_fn.deinit(arena_alloc);
            // Bind in current namespace's env if namespace manager is available
            try bindInCurrentNamespace(env, macro_name.sym_val, persistent_macro);
            return try macro_name.clone(arena_alloc);
        }

        // do - evaluate a sequence of forms
        if (std.mem.eql(u8, name, "do")) {
            return try evalDo(allocator, arena_alloc, l.items[1..], env, depth + 1);
        }

        // set! - modify a var
        if (std.mem.eql(u8, name, "set!")) {
            if (l.items.len != 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            const val = try evalRec(allocator, arena_alloc, l.items[2], env, depth + 1);
            // Clone to main allocator for persistent env storage
            const persistent_val = try val.clone(allocator);
            try env.put(sym.sym_val, persistent_val);
            return val; // return arena copy
        }

        // recur - tail recursion
        if (std.mem.eql(u8, name, "recur")) {
            if (l.items.len < 2) return error.ArityError;
            // Signal recur: return a special marker list
            // First element is a special symbol "__recur__", rest are evaluated new values
            var results: list.List = .empty;
            errdefer results.deinit(arena_alloc);
            try results.append(arena_alloc, try Value.symValue(allocator, "__recur__"));
            for (l.items[1..]) |arg| {
                try results.append(arena_alloc, try evalRec(allocator, arena_alloc, arg, env, depth + 1));
            }
            return Value.listValue(results);
        }

        // loop - named recursion point
        if (std.mem.eql(u8, name, "loop")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLoop(allocator, arena_alloc, bindings, l.items[2..], env, depth + 1);
        }

        // var - create a mutable var
        if (std.mem.eql(u8, name, "var")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            var val = if (l.items.len >= 3)
                try evalRec(allocator, arena_alloc, l.items[2], env, depth + 1)
            else
                Value.nilValue();
            // Clone to main allocator for persistent env storage
            const persistent_val = try val.clone(allocator);
            val.deinit(arena_alloc);
            try env.put(sym.sym_val, persistent_val);
            return try sym.clone(arena_alloc);
        }

        // deref - get the value of a derefable object (atom, var, etc.)
        if (std.mem.eql(u8, name, "deref") or std.mem.eql(u8, name, "@")) {
            if (l.items.len != 2) return error.ArityError;
            var arg = try evalRec(allocator, arena_alloc, l.items[1], env, depth + 1);
            // Extract value from atom
            if (arg.type == .atom) {
                if (arg.atom_val) |data| {
                    const val = try data.value.clone(arena_alloc);
                    arg.deinit(arena_alloc);
                    return val;
                }
                arg.deinit(arena_alloc);
                return Value.nilValue();
            }
            return arg;
        }

        // or - short-circuit or
        if (std.mem.eql(u8, name, "or")) {
            var last_val: Value = Value.nilValue();
            errdefer last_val.deinit(arena_alloc);
            for (l.items[1..]) |form_item| {
                const val = try evalRec(allocator, arena_alloc, form_item, env, depth + 1);
                if (val.isTruthy()) {
                    last_val.deinit(arena_alloc);
                    return val;
                }
                last_val.deinit(arena_alloc);
                last_val = val;
            }
            return last_val;
        }

        // and - short-circuit and
        if (std.mem.eql(u8, name, "and")) {
            for (l.items[1..]) |form_item| {
                const val = try evalRec(allocator, arena_alloc, form_item, env, depth + 1);
                if (!val.isTruthy()) return val;
            }
            return Value.boolValue(true);
        }

        // binding - dynamic variable binding (simplified)
        // Matches Clojure syntax: (binding [var1 val1 var2 val2] body...)
        if (std.mem.eql(u8, name, "binding")) {
            if (l.items.len < 3) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .vector) return error.TypeError;
            var new_env = try env.clone(arena_alloc);
            defer new_env.deinit(arena_alloc);

            var i: usize = 0;
            while (i < bindings.vec_val.items.len) : (i += 2) {
                const sym = bindings.vec_val.items[i];
                if (sym.type != .symbol) return error.TypeError;
                const val = try evalRec(allocator, arena_alloc, bindings.vec_val.items[i + 1], env, depth + 1);
                try new_env.put(sym.sym_val, val);
            }
            return try evalDo(allocator, arena_alloc, l.items[2..], &new_env, depth + 1);
        }

        // ->> thread-last macro
        // (->> x (f 1) (g 2 3)) => (g (f x 1) 2 3)
        if (std.mem.eql(u8, name, "->>")) {
            return try eval_thread.evalThreadLast(allocator, arena_alloc, l.items[1..], env, depth + 1);
        }

        // -> thread-first macro
        // (-> x (f 1) (g 2 3)) => (g (f 1 x) 2 3)
        if (std.mem.eql(u8, name, "->")) {
            return eval_thread.evalThreadFirst(allocator, arena_alloc, l.items[1..], env, depth + 1);
        }

        // lazy-seq - create a lazy sequence
        if (std.mem.eql(u8, name, "lazy-seq")) {
            if (l.items.len < 2) return error.ArityError;
            // Build the thunk body as a list of forms to evaluate
            var body: list.List = .empty;
            errdefer body.deinit(arena_alloc);
            try body.append(arena_alloc, try Value.symValue(allocator, "do"));
            for (l.items[1..]) |form| {
                try body.append(arena_alloc, try form.clone(arena_alloc));
            }
            const thunk = try arena_alloc.create(Value.LazySeqThunk);
            thunk.* = .{
                .params = list.empty(),
                .body = body,
                .env = try env.clone(arena_alloc),
            };
            return Value.lazySeqValue(thunk);
        }

        // dorun - realize a lazy sequence for side effects, return nil
        // (dorun coll) or (dorun n coll)
        if (std.mem.eql(u8, name, "dorun")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const dorun_args = l.items[1..];
            var n: ?usize = null;
            var coll_form: Value = undefined;
            if (dorun_args.len == 2) {
                var n_val = try evalRec(allocator, arena_alloc, dorun_args[0], env, depth + 1);
                defer n_val.deinit(arena_alloc);
                const n_int: i64 = switch (n_val.type) {
                    .integer => n_val.int_val,
                    .float => @as(i64, @intFromFloat(n_val.float_val)),
                    else => return error.TypeError,
                };
                n = @as(usize, @intCast(n_int));
                coll_form = dorun_args[1];
            } else {
                coll_form = dorun_args[0];
            }
            var coll = try evalRec(allocator, arena_alloc, coll_form, env, depth + 1);
            defer coll.deinit(arena_alloc);

            // Handle lazy_map: iterate element-by-element without materializing full result
            if (coll.type == .lazy_map) {
                var lm: *Value.LazyMapData = coll.lazy_map_val.?;
                var count: usize = 0;

                // Handle list/vector as inner collection
                var coll_items: []const Value = undefined;
                const coll_len: usize = switch (lm.coll.type) {
                    .list => lm.coll.list_val.items.len,
                    .vector => lm.coll.vec_val.items.len,
                    else => return Value.nilValue(),
                };
                switch (lm.coll.type) {
                    .list => coll_items = lm.coll.list_val.items,
                    .vector => coll_items = lm.coll.vec_val.items,
                    else => return Value.nilValue(),
                }
                while (lm.idx < coll_len) {
                    if (n) |limit| { if (count >= limit) break; }
                    var arg_list: list.List = .empty;
                    errdefer arg_list.deinit(arena_alloc);
                    try arg_list.append(arena_alloc, try coll_items[lm.idx].clone(arena_alloc));
                    var mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env);
                    if (mapped.type == .lazy_seq) {
                        const forced = try forceLazySeq(allocator, arena_alloc, mapped, env, depth + 1);
                        mapped.deinit(arena_alloc);
                        mapped = forced;
                    }
                    mapped.deinit(arena_alloc);
                    lm.idx += 1;
                    count += 1;
                }
                return Value.nilValue();
            }

            // Force lazy_seq if needed
            if (coll.type == .lazy_seq) {
                const forced = try forceLazySeq(allocator, arena_alloc, coll, env, depth + 1);
                coll.deinit(arena_alloc);
                coll = forced;
            }
            // Iterate through the collection (realizing it), optionally up to n elements
            var items: []const Value = undefined;
            switch (coll.type) {
                .list => items = coll.list_val.items,
                .vector => items = coll.vec_val.items,
                .set => items = coll.set_val.items,
                .queue => items = coll.queue_val.items,
                else => return Value.nilValue(),
            }
            var count: usize = 0;
            var i: usize = 0;
            while (i < items.len) : (i += 1) {
                if (n) |limit| {
                    if (count >= limit) break;
                }
                // Force nested lazy sequences
                const item = items[i];
                if (item.type == .lazy_seq) {
                    _ = try forceLazySeq(allocator, arena_alloc, item, env, depth + 1);
                }
                count += 1;
            }
            return Value.nilValue();
        }

        // doall - realize lazy sequences and return the result
        if (std.mem.eql(u8, name, "doall")) {
            if (l.items.len != 2) return error.ArityError;
            var coll = try evalRec(allocator, arena_alloc, l.items[1], env, depth + 1);
            // Handle lazy_map: force into a list and return it
            if (coll.type == .lazy_map) {
                return try forceLazyMap(allocator, arena_alloc, coll, env);
            }
            // Handle lazy_seq: force and return
            if (coll.type == .lazy_seq) {
                const forced = try forceLazySeq(allocator, arena_alloc, coll, env, depth + 1);
                coll.deinit(arena_alloc);
                return forced;
            }
            // For concrete collections, just return a clone
            return try coll.clone(arena_alloc);
        }

        // cond-> - thread-first with conditions
        // (cond-> expr test1 step1 test2 step2 ...)
        if (std.mem.eql(u8, name, "cond->")) {
            return try eval_thread.evalCondThreadFirst(allocator, arena_alloc, l.items[1..], env, depth + 1);
        }

        // cond->> - thread-last with conditions
        // (cond->> expr test1 step1 test2 step2 ...)
        if (std.mem.eql(u8, name, "cond->>")) {
            return try eval_thread.evalCondThreadLast(allocator, arena_alloc, l.items[1..], env, depth + 1);
        }

        // case - multi-way constant dispatch
        // (case expr test1 result1 test2 result2 ... default)
        if (std.mem.eql(u8, name, "case")) {
            return try evalCase(allocator, arena_alloc, l.items[1..], env, depth + 1);
        }
    }

    // Evaluate the operator
    var op = try evalRec(allocator, arena_alloc, first, env, depth + 1);
    defer op.deinit(arena_alloc);

    // Check if operator is a macro
    if (op.type == .function and op.fn_val.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        errdefer macro_args.deinit(arena_alloc);
        for (l.items[1..]) |arg| {
            try macro_args.append(arena_alloc, try arg.clone(arena_alloc));
        }
        // Call the macro with unevaluated args
        var expanded = try call(allocator, arena_alloc, op, macro_args, env, depth + 1);
        // Evaluate the expanded form
        const result = try evalRec(allocator, arena_alloc, expanded, env, depth + 1);
        expanded.deinit(arena_alloc);
        return result;
    }

    // Evaluate all arguments
    var args: list.List = .empty;
    errdefer args.deinit(arena_alloc);
    for (l.items[1..]) |arg| {
        try args.append(arena_alloc, try evalRec(allocator, arena_alloc, arg, env, depth + 1));
    }

    // Transfer ownership of args to call (call will deinit it).
    // Reset local copy to prevent double-free from errdefer.
    const transferred = args;
    args = list.List.empty;

    // Call the function
    return try call(allocator, arena_alloc, op, transferred, env, depth + 1);
}

fn evalDo(allocator: Allocator, arena_alloc: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    var result: Value = Value.nilValue();
    errdefer result.deinit(arena_alloc);

    for (forms) |form| {
        result.deinit(arena_alloc);
        result = Value.nilValue();
        result = try evalRec(allocator, arena_alloc, form, env, depth);
    }
    return result;
}

fn evalLet(allocator: Allocator, arena_alloc: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (bindings.type != .list and bindings.type != .vector) return error.TypeError;

    var new_env = try env.clone(arena_alloc);
    defer new_env.deinit(arena_alloc);

    const items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => unreachable,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const sym = items[i];
        // Evaluate binding value in new_env so later bindings can reference earlier ones
        const val = try evalRec(allocator, arena_alloc, items[i + 1], &new_env, depth);
        // Bind using destructuring if sym is a vector pattern
        try bindPattern(allocator, arena_alloc, sym, val, &new_env, depth);
    }

    return try evalDo(allocator, arena_alloc, body, &new_env, depth);
}

fn evalLetFn(allocator: Allocator, arena_alloc: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    const bind_items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => return error.TypeError,
    };

    // Create new env first so all functions can reference each other
    var new_env: Env = .{
        .allocator = allocator,
        .entries = .empty,
        .parent = env,
        .ns_manager = null,
    };
    defer new_env.deinit(arena_alloc);

    // Parse each function definition: (name [params] body...)
    for (bind_items) |binding| {
        if (binding.type != .list or binding.list_val.items.len < 3) return error.TypeError;
        const b = binding.list_val;

        // First element is the function name
        const fname = b.items[0];
        if (fname.type != .symbol) return error.TypeError;

        // Second element is the parameter list
        const params_form = b.items[1];
        if (params_form.type != .list and params_form.type != .vector) return error.TypeError;
        const params_list = if (params_form.type == .vector)
            try helpers.listFromVector(arena_alloc, params_form.vec_val)
        else
            params_form.list_val;

        // Remaining elements are the body
        var body_list: list.List = .empty;
        errdefer body_list.deinit(arena_alloc);
        try body_list.append(arena_alloc, try Value.symValue(allocator, "do"));
        for (b.items[2..]) |form_item| {
            try body_list.append(arena_alloc, try form_item.clone(arena_alloc));
        }

        // Parse params for variadic support
        var parsed = try parseParams(arena_alloc, params_list);
        defer {
            parsed.params.deinit(arena_alloc);
            if (parsed.rest_name) |rn| arena_alloc.free(rn);
        }

        // Build arity
        var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
        errdefer {
            for (arities.items) |*a| {
                a.params.deinit(arena_alloc);
                a.body.deinit(arena_alloc);
                if (a.rest_name) |rn| arena_alloc.free(rn);
            }
            arena_alloc.free(arities.items);
        }

        const cloned_params = try parsed.params.clone(arena_alloc);
        const cloned_body = try body_list.clone(arena_alloc);
        const cloned_rest = if (parsed.rest_name) |rn| try arena_alloc.dupe(u8, rn) else null;
        try arities.append(arena_alloc, Value.Arity{
            .params = cloned_params,
            .body = cloned_body,
            .rest_name = cloned_rest,
        });

        // Create fn with new_env as closure (for mutual recursion)
        const fn_env: Env = .{
            .allocator = allocator,
            .entries = .empty,
            .parent = &new_env,
            .ns_manager = null,
        };
        var fn_val = Value.fnValue(arities, fn_env, false);
        const persistent_fn = try fn_val.clone(allocator);
        fn_val.deinit(arena_alloc);

        // Bind in new_env
        try new_env.put(fname.sym_val, persistent_fn);
    }

    return try evalDo(allocator, arena_alloc, body, &new_env, depth);
}

/// Bind a value to a pattern. Supports simple symbols and vector destructuring with & rest.
fn bindPattern(allocator: Allocator, arena_alloc: Allocator, pattern: Value, val: Value, env: *Value.Env, depth: usize) anyerror!void {
    switch (pattern.type) {
        .symbol => {
            try env.put(pattern.sym_val, try val.clone(arena_alloc));
        },
        .vector => {
            // Vector destructuring: [a b & rest] matches elements of val
            const vitems = switch (val.type) {
                .list => val.list_val.items,
                .vector => val.vec_val.items,
                else => return error.TypeError,
            };
            var j: usize = 0;
            while (j < pattern.vec_val.items.len) : (j += 1) {
                const pat_item = pattern.vec_val.items[j];
                // Handle & rest (& is parsed as a symbol)
                if (pat_item.type == .symbol and std.mem.eql(u8, pat_item.sym_val, "&")) {
                    if (j + 1 < pattern.vec_val.items.len) {
                        const rest_sym = pattern.vec_val.items[j + 1];
                        // Collect remaining items into a list (starting from current position j)
                        var rest_list: list.List = .empty;
                        errdefer rest_list.deinit(arena_alloc);
                        var k: usize = j;
                        while (k < vitems.len) : (k += 1) {
                            try rest_list.append(arena_alloc, try vitems[k].clone(arena_alloc));
                        }
                        if (rest_sym.type == .symbol) {
                            try env.put(rest_sym.sym_val, Value.listValue(rest_list));
                        }
                        j += 1; // Skip the rest symbol
                    }
                    break;
                } else if (j < vitems.len) {
                    try bindPattern(allocator, arena_alloc, pat_item, vitems[j], env, depth);
                }
            }
        },
        else => return error.TypeError,
    }
}

fn evalCond(allocator: Allocator, arena_alloc: Allocator, clauses: []const Value, env: *Env, depth: usize) anyerror!Value {
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const cond = clauses[i];
        // Handle :else clause
        if (cond.type == .keyword and std.mem.eql(u8, cond.kw_val, "else")) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, arena_alloc, clauses[i + 1], env, depth);
        }

        const result = try evalRec(allocator, arena_alloc, cond, env, depth);
        if (result.isTruthy()) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, arena_alloc, clauses[i + 1], env, depth);
        }
    }
    return Value.nilValue();
}

fn evalLoop(allocator: Allocator, arena_alloc: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (bindings.type != .list and bindings.type != .vector) return error.TypeError;

    const bind_items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => unreachable,
    };

    // Extract binding names
    var bind_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (bind_names.items) |name| arena_alloc.free(name);
        arena_alloc.free(bind_names.items);
    }
    var i: usize = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        if (sym.type != .symbol) return error.TypeError;
        try bind_names.append(arena_alloc, try arena_alloc.dupe(u8, sym.sym_val));
    }

    // Initialize environment with initial binding values
    var new_env = try env.clone(arena_alloc);
    defer new_env.deinit(arena_alloc);

    i = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        const val = try evalRec(allocator, arena_alloc, bind_items[i + 1], env, depth);
        try new_env.put(sym.sym_val, val);
    }

    // Loop: evaluate body, check for recur marker, rebind and repeat
    var loop_depth: usize = depth;
    while (true) {
        if (loop_depth > MAX_RECURSION) return error.RecursionLimit;

        var result = try evalDo(allocator, arena_alloc, body, &new_env, loop_depth);

        // Check for recur marker: list starting with __recur__ symbol
        if (result.type == .list and result.list_val.items.len > 0 and
            result.list_val.items[0].type == .symbol and
            std.mem.eql(u8, result.list_val.items[0].sym_val, "__recur__"))
        {
            const recur_vals = result.list_val.items[1..];
            if (recur_vals.len != bind_names.items.len) {
                result.deinit(arena_alloc);
                return error.ArityError;
            }
            // Rebind loop variables with new values
            var j: usize = 0;
            while (j < recur_vals.len) : (j += 1) {
                const new_val = try recur_vals[j].clone(allocator);
                try new_env.put(bind_names.items[j], new_val);
            }
            result.deinit(arena_alloc);
            loop_depth += 1;
            continue;
        }

        return result;
    }
}

pub fn call(allocator: Allocator, arena_alloc: Allocator, op: Value, args_list: list.List, env: *Env, depth: usize) anyerror!Value {
    var args = args_list;
    defer args.deinit(arena_alloc);

    switch (op.type) {
        .function => {
            const fn_data = op.fn_val;
            const arg_count = args.items.len;

            // Find matching arity: exact match first, then variadic with enough args
            var matched_arity: ?*const Value.Arity = null;
            var i: usize = 0;
            while (i < fn_data.arities.items.len) : (i += 1) {
                const arity = &fn_data.arities.items[i];
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

            // Optimization: skip env clone if no local entries
            var new_env: Env = undefined;
            if (fn_data.env.entries.entries.len > 0) {
                new_env = try fn_data.env.clone(arena_alloc);
            } else {
                new_env = .{
                    .allocator = allocator,
                    .entries = .empty,
                    .parent = fn_data.env.parent,
                    .ns_manager = null,
                };
            }
            defer new_env.deinit(arena_alloc);

            const min_args = arity.params.items.len;
            const has_rest = arity.rest_name != null;

            // Bind regular parameters to arguments (with destructuring support)
            var j: usize = 0;
            while (j < arity.params.items.len) : (j += 1) {
                const param = arity.params.items[j];
                try bindParam(allocator, arena_alloc, param, args.items[j], &new_env);
            }

            // Bind rest parameter to remaining args as a list
            if (has_rest and args.items.len > min_args) {
                var rest_list: list.List = .empty;
                errdefer rest_list.deinit(arena_alloc);
                var k: usize = min_args;
                while (k < args.items.len) : (k += 1) {
                    try rest_list.append(arena_alloc, try args.items[k].clone(arena_alloc));
                }
                try new_env.put(arity.rest_name.?, Value.listValue(rest_list));
            } else if (has_rest) {
                // No extra args: bind empty list to rest parameter
                try new_env.put(arity.rest_name.?, Value.listValue(.empty));
            }

            // Evaluate the function body
            return try evalRec(allocator, arena_alloc, Value.listValue(arity.body), &new_env, depth);
        },
        .builtin_fn => {
            var op_mut = op;
            return op_mut.builtin_fn_val(&op_mut, args, env);
        },
        .set => {
            // Set as function: returns the element if found, nil otherwise
            if (args.items.len != 1) return error.ArityError;
            for (op.set_val.items) |item| {
                if (item.equals(args.items[0])) {
                    return try item.clone(arena_alloc);
                }
            }
            return Value.nilValue();
        },
        .map => {
            // Map as function: returns value for key, or not-found if provided
            if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
            const key = args.items[0];
            for (op.map_val.items) |entry| {
                if (entry.key.equals(key)) {
                    return try entry.value.clone(arena_alloc);
                }
            }
            // Return not-found value if provided
            if (args.items.len == 2) {
                return try args.items[1].clone(arena_alloc);
            }
            return Value.nilValue();
        },
        .lazy_seq => {
            // Force evaluation of lazy sequence
            if (args.items.len != 0) return error.ArityError;
            return try forceLazySeq(allocator, arena_alloc, op, env, depth);
        },
        else => return error.NotCallable,
    }
}

// Force evaluation of a lazy sequence, returning the resulting list
fn forceLazySeq(allocator: Allocator, arena_alloc: Allocator, lazy: Value, env: *Env, depth: usize) anyerror!Value {
    _ = env;
    // Evaluate the thunk
    if (lazy.lazy_seq_val.thunk) |thunk| {
        // Clone thunk data for evaluation — don't free the thunk itself
        // since the original Value (e.g. stored in env) still holds the pointer.
        // The thunk will be properly freed when the original Value is deinited.
        var cloned_params = try thunk.params.clone(arena_alloc);
        var cloned_body = try thunk.body.clone(arena_alloc);
        var thunk_env = try thunk.env.clone(arena_alloc);
        defer {
            cloned_params.deinit(arena_alloc);
            cloned_body.deinit(arena_alloc);
            thunk_env.deinit(arena_alloc);
        }

        // Evaluate the body to get the result
        var result = try evalRec(allocator, arena_alloc, Value.listValue(cloned_body), &thunk_env, depth);

        // The result should be a list/vector (the sequence)
        // Convert to list if needed
        var final_list: list.List = .empty;
        errdefer final_list.deinit(arena_alloc);

        switch (result.type) {
            .list => {
                for (result.list_val.items) |item| {
                    try final_list.append(arena_alloc, try item.clone(arena_alloc));
                }
            },
            .vector => {
                for (result.vec_val.items) |item| {
                    try final_list.append(arena_alloc, try item.clone(arena_alloc));
                }
            },
            .nil => {}, // empty sequence
            else => {
                try final_list.append(arena_alloc, result);
            },
        }

        result.deinit(arena_alloc);
        return Value.listValue(final_list);
    }

    return Value.listValue(list.empty());
}

// Bind a parameter to an argument, supporting destructuring
// e.g., param=[a b], arg=[1 2] => binds a=1, b=2
fn bindParam(allocator: Allocator, arena_alloc: Allocator, param: Value, arg: Value, env: *Env) anyerror!void {
    switch (param.type) {
        .symbol => {
            try env.put(param.sym_val, try arg.clone(arena_alloc));
        },
        .vector => {
            // Destructure: param is [x y z], arg should be a collection
            var arg_items: []const Value = undefined;
            switch (arg.type) {
                .list => arg_items = arg.list_val.items,
                .vector => arg_items = arg.vec_val.items,
                else => return error.TypeError,
            }
            if (param.vec_val.items.len != arg_items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.vec_val.items.len) : (i += 1) {
                try bindParam(allocator, arena_alloc, param.vec_val.items[i], arg_items[i], env);
            }
        },
        .list => {
            // Same as vector but from a list
            if (param.list_val.items.len != arg.list_val.items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.list_val.items.len) : (i += 1) {
                try bindParam(allocator, arena_alloc, param.list_val.items[i], arg.list_val.items[i], env);
            }
        },
        else => {}, // Ignore other param types
    }
}

// Check if a form looks like a parameter list (vector/list of symbols, possibly with & rest)
fn looksLikeParamList(form: Value) bool {
    const items = switch (form.type) {
        .vector => form.vec_val.items,
        .list => form.list_val.items,
        else => return false,
    };
    if (items.len == 0) return false;
    var found_amp = false;
    for (items) |item| {
        if (item.type == .symbol and std.mem.eql(u8, item.sym_val, "&")) {
            if (found_amp) return false; // duplicate &
            found_amp = true;
            continue;
        }
        if (!found_amp and item.type != .symbol) return false;
        if (found_amp and item.type != .symbol) return false;
    }
    return true;
}

// case - multi-way constant dispatch
// (case expr test1 result1 test2 result2 ... :else default)
fn evalCase(allocator: Allocator, arena_alloc: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len < 1) return error.ArityError;

    var expr_val = try evalRec(allocator, arena_alloc, forms[0], env, depth);
    defer expr_val.deinit(arena_alloc);

    var i: usize = 1;
    while (i < forms.len) : (i += 2) {
        const test_form = forms[i];
        if (test_form.type == .keyword and std.mem.eql(u8, test_form.kw_val, "else")) {
            if (i + 1 >= forms.len) return error.ArityError;
            return try evalRec(allocator, arena_alloc, forms[i + 1], env, depth);
        }

        var test_val = try evalRec(allocator, arena_alloc, test_form, env, depth);
        defer test_val.deinit(arena_alloc);

        if (expr_val.equals(test_val)) {
            if (i + 1 >= forms.len) return error.ArityError;
            return try evalRec(allocator, arena_alloc, forms[i + 1], env, depth);
        }
    }

    return Value.nilValue();
}
