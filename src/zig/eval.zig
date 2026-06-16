const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = Value.Env;
const phm = @import("persistent_hash_map.zig");
const parser = @import("parser.zig");
const eval_helpers = @import("namespaces/core/eval_helpers.zig");
const helpers = @import("namespaces/core/helpers.zig");
const sequences = @import("namespaces/core/sequences.zig");
const eval_thread = @import("eval_thread.zig");
const eval_macro = @import("eval_macro.zig");
const eval_ns = @import("eval_ns.zig");
const protocols = @import("namespaces/core/protocols.zig");
const records = @import("namespaces/core/records.zig");
const gc_mod = @import("gc.zig");

const Allocator = std.mem.Allocator;

/// Push the HAMT root from an Env as a temporary GC root.
/// Returns a Guard struct that pops the root on deinit (use `defer guard.deinit()`).
/// This protects HAMT nodes reachable from stack-allocated Env structs.
const TempRootGuard = struct {
    gc: ?*gc_mod.GC,

    pub fn deinit(self: TempRootGuard) void {
        if (self.gc) |gc_inst| {
            gc_inst.popTempRoot();
        }
    }
};

fn pushEnvTempRoot(env: *const Env) TempRootGuard {
    if (gc_mod.current_gc) |gc_inst| {
        if (env.entries.root) |root| {
            gc_inst.pushTempRoot(root);
            return TempRootGuard{ .gc = gc_inst };
        }
    }
    return TempRootGuard{ .gc = null };
}

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
pub fn eval(allocator: Allocator, form: Value, env: *Env) anyerror!Value {
    return evalRec(allocator, form, env, 0);
}

pub fn evalRec(allocator: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    if (depth > MAX_RECURSION) return error.RecursionLimit;

    switch (form.type) {
        .nil, .bool, .integer, .float, .bigint, .ratio, .decimal, .string, .regex, .character, .keyword, .set, .queue, .atom, .reduced, .wrapped, .record => {
            return try form.clone(allocator);
        },
        .symbol => {
            if (std.mem.eql(u8, form.sym_val, "quote") or
                std.mem.eql(u8, form.sym_val, "quasiquote") or
                std.mem.eql(u8, form.sym_val, "unquote") or
                std.mem.eql(u8, form.sym_val, "unquote-splicing"))
            {
                return try form.clone(allocator);
            }
            // Handle qualified symbols: alias/name or namespace/name
            if (std.mem.indexOfScalar(u8, form.sym_val, '/')) |slash_idx| {
                const alias = form.sym_val[0..slash_idx];
                const name = form.sym_val[slash_idx + 1 ..];
                // Resolve through namespace manager
                const ns_mgr = findNsManager(env) orelse {
                    const val2 = env.get(form.sym_val);
                    if (val2) |v| return try v.clone(allocator);
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
                    return error.UndefinedSymbol;
                };
                // Look up alias in current namespace, or use the part before '/' as a direct namespace name
                const current_ns = ns_mgr.getCurrentNamespace();
                const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
                // Get target namespace's env and look up the name
                const target_env = ns_mgr.getNamespace(target_ns) orelse {
                    // Target namespace doesn't exist, try direct lookup
                    const val3 = env.get(form.sym_val);
                    if (val3) |v| return try v.clone(allocator);
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
                    return error.UndefinedSymbol;
                };
                const val4 = target_env.get(name);
                if (val4) |v| return try v.clone(allocator);
                std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
                return error.UndefinedSymbol;
            }
            const val = env.get(form.sym_val);
            if (val) |v| return try v.clone(allocator);
            std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
            return error.UndefinedSymbol;
        },
        .list => {
            return try evalList(allocator, form.list_val, env, depth);
        },
        .vector => {
            // Vectors evaluate element-wise
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            for (form.vec_val.items) |item| {
                try new_vec.append(allocator, try evalRec(allocator, item, env, depth + 1));
            }
            return Value.vectorValue(new_vec);
        },
        .map => {
            // Maps evaluate key-value pairs element-wise
            var new_map: Value.Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(new_map.items);
            }
            for (form.map_val.items) |entry| {
                try new_map.append(allocator, .{
                    .key = try evalRec(allocator, entry.key, env, depth + 1),
                    .value = try evalRec(allocator, entry.value, env, depth + 1),
                });
            }
            return Value.mapValue(new_map);
        },
        .function, .builtin_fn => return try form.clone(allocator),
        .lazy_seq => return try form.clone(allocator),
        .cons => {
            // Evaluate cons cells as forms (like lists)
            // Convert cons chain to a list, then evaluate
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            var current = form;
            while (current.type == .cons) {
                const cdata = current.cons_val orelse break;
                try new_list.append(allocator, try cdata.head.clone(allocator));
                current = cdata.tail;
            }
            // If tail is a list, splice in its elements
            if (current.type == .list) {
                for (current.list_val.items) |item| {
                    try new_list.append(allocator, try item.clone(allocator));
                }
            } else if (current.type != .nil) {
                // Improper list - append the tail as a final element
                try new_list.append(allocator, try current.clone(allocator));
            }
            return try evalList(allocator, new_list, env, depth);
        },
    }
    unreachable;
}

// Parse ([params] body...)+ pairs from a list slice.
// Returns an ArrayListUnmanaged(Value.Arity) and updates *idx to point past the last consumed item.
// Handles both flattened form: (fn [x] body) and wrapped form: (fn ([x] body))
fn parseArityForms(allocator: Allocator, items: []const Value, end: usize, idx: *usize) anyerror!std.ArrayListUnmanaged(Value.Arity) {
    var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }

    while (idx.* < end) {
        const form = items[idx.*];
        idx.* += 1;

        var params_list: list.List = undefined;
        var body_forms: []const Value = undefined;

        if (form.type == .vector) {
            // Flattened form: (fn [x] body1 body2 [y] body3)
            // params = [x], body = body1 body2
            params_list = try helpers.listFromVector(allocator, form.vec_val);

            // Collect body forms until next [params] or end
            const body_start = idx.*;
            while (idx.* < end) {
                const next = items[idx.*];
                if (looksLikeParamList(next) and idx.* + 1 < end) {
                    break;
                }
                idx.* += 1;
            }
            body_forms = items[body_start..idx.*];
        } else if (form.type == .list) {
            // Wrapped form: (fn ([x] body1 body2) ([y] body3))
            // Or: (fn (x y) body) from macro-generated code where (list x y) creates (x y)
            // Extract params and body from within the list
            if (form.list_val.items.len == 0) return error.TypeError;
            const inner_first = form.list_val.items[0];
            if (inner_first.type == .vector) {
                // Standard: (fn ([x] body))
                params_list = try helpers.listFromVector(allocator, inner_first.vec_val);
                body_forms = form.list_val.items[1..];
            } else if (inner_first.type == .list) {
                // Nested list params: (fn ((x y) body)) - treat inner list as params
                params_list = inner_first.list_val;
                body_forms = form.list_val.items[1..];
            } else {
                // Macro-generated: (fn (x) body) where (list x) created (x)
                // The entire list is the params form: (x) means params = [x]
                // Body forms come from the parent list after this form
                params_list = form.list_val;

                // Collect body forms from the parent list
                const body_start = idx.*;
                while (idx.* < end) {
                    const next = items[idx.*];
                    if (looksLikeParamList(next) and idx.* + 1 < end) {
                        break;
                    }
                    idx.* += 1;
                }
                body_forms = items[body_start..idx.*];
            }
        } else {
            return error.TypeError;
        }

        // Wrap body in a do block
        var body_list: list.List = .empty;
        errdefer body_list.deinit(allocator);
        try body_list.append(allocator, try Value.symValue(allocator, "do"));
        for (body_forms) |form_item| {
            try body_list.append(allocator, try form_item.clone(allocator));
        }

        // Parse params for variadic support (& rest)
        var parsed = try parseParams(allocator, params_list);
        defer {
            parsed.params.deinit(allocator);
            if (parsed.rest_name) |rn| allocator.free(rn);
        }

        const cloned_params = try list.clone(&parsed.params, allocator);
        const cloned_body = try list.clone(&body_list, allocator);
        const cloned_rest = if (parsed.rest_name) |rn| try allocator.dupe(u8, rn) else null;
        try arities.append(allocator, Value.Arity{
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
fn parseParams(allocator: Allocator, params: list.List) anyerror!ParsedParams {
    var regular_params: list.List = .empty;
    errdefer regular_params.deinit(allocator);
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
            rest_name = try allocator.dupe(u8, item.sym_val);
            // No more params expected after rest
            break;
        } else {
            try regular_params.append(allocator, try item.clone(allocator));
        }
    }

    return ParsedParams{
        .params = regular_params,
        .rest_name = rest_name,
    };
}

fn evalList(allocator: Allocator, l: list.List, env: *Env, depth: usize) anyerror!Value {
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
            return try eval_ns.evalNs(allocator, l, env, depth);
        }

        // in-ns - create/find namespace and set as current
        // (in-ns namespace-name)
        if (std.mem.eql(u8, name, "in-ns")) {
            return try eval_ns.evalInNs(allocator, l, env, depth);
        }

        if (std.mem.eql(u8, name, "quote")) {
            if (l.items.len != 2) return error.ArityError;
            return try l.items[1].clone(allocator);
        }

        if (std.mem.eql(u8, name, "quasiquote")) {
            if (l.items.len != 2) return error.ArityError;
            return try eval_macro.unquoteProcess(allocator, l.items[1], env, depth + 1);
        }

        // def - define in current namespace
        if (std.mem.eql(u8, name, "def")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            // (def name value) — always evaluate item[2] (or item[1] if only 2 items)
            // Docstrings are handled via metadata: (def ^{:doc "..."} name value)
            const eval_idx: usize = if (l.items.len >= 3) 2 else 1;
            var val = try evalRec(allocator, l.items[eval_idx], env, depth + 1);
            // Clone to main allocator before storing in persistent env
            const persistent_val = try val.clone(allocator);
            val.deinit(allocator);
            // Bind in current namespace's env if namespace manager is available
            try bindInCurrentNamespace(env, sym.sym_val, persistent_val);
            return try sym.clone(allocator);
        }

        // let - local bindings
        if (std.mem.eql(u8, name, "let")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLet(allocator, bindings, l.items[2..], env, depth + 1);
        }

        // letfn - define mutually recursive functions
        // (letfn [(name [params] body...)+] body...)
        if (std.mem.eql(u8, name, "letfn")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLetFn(allocator, bindings, l.items[2..], env, depth + 1);
        }

        // if - conditional
        if (std.mem.eql(u8, name, "if")) {
            if (l.items.len < 2 or l.items.len > 4) return error.ArityError;
            var cond = try evalRec(allocator, l.items[1], env, depth + 1);
            const truthy = cond.isTruthy();
            cond.deinit(allocator);
            if (truthy) {
                if (l.items.len >= 3) return try evalRec(allocator, l.items[2], env, depth + 1);
                return Value.nilValue();
            } else {
                if (l.items.len >= 4) return try evalRec(allocator, l.items[3], env, depth + 1);
                return Value.nilValue();
            }
        }

        // when - (when test body...)
        if (std.mem.eql(u8, name, "when")) {
            if (l.items.len < 2) return error.ArityError;
            var cond = try evalRec(allocator, l.items[1], env, depth + 1);
            const truthy = cond.isTruthy();
            cond.deinit(allocator);
            if (truthy) {
                var do_result: Value = Value.nilValue();
                errdefer do_result.deinit(allocator);
                for (l.items[2..]) |form| {
                    do_result.deinit(allocator);
                    do_result = Value.nilValue();
                    do_result = try evalRec(allocator, form, env, depth + 1);
                }
                return do_result;
            }
            return Value.nilValue();
        }

        // cond - multi-way conditional
        if (std.mem.eql(u8, name, "cond")) {
            return try evalCond(allocator, l.items[1..], env, depth + 1);
        }

        // defn / defn- - define a named function (supports multi-arity)
        // (defn name docstring? ([params] body...)+)
        // defn- is an alias for defn (convention for private functions)
        if (std.mem.eql(u8, name, "defn") or std.mem.eql(u8, name, "defn-")) {
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
                    a.params.deinit(allocator);
                    a.body.deinit(allocator);
                    if (a.rest_name) |rn| allocator.free(rn);
                }
                allocator.free(arities.items);
            }

            arities = try parseArityForms(allocator, l.items, l.items.len, &idx);

            // Create fn_env with parent = env so it can see all global symbols
            // including the function itself (for recursion)
            const fn_env: Env = .{
                .allocator = allocator,
                .entries = phm.PersistentHashMap.empty(),
                .parent = env,
                .ns_manager = null,
            };
            var fn_val = try Value.fnValue(allocator, arities, fn_env, false);
            // Clone to main allocator before storing in persistent env
            const persistent_fn = try fn_val.clone(allocator);
            fn_val.deinit(allocator);
            // Bind in current namespace's env if namespace manager is available
            try bindInCurrentNamespace(env, fname.sym_val, persistent_fn);
            return try fname.clone(allocator);
        }

        // fn - define a function (supports multi-arity)
        // (fn name? ([params] body...)+)
        if (std.mem.eql(u8, name, "fn")) {
            if (l.items.len < 2) return error.ArityError;
            var idx: usize = 1;
            // Skip optional name (and store it for self-reference)
            var fn_name: ?Value = null;
            if (l.items[idx].type == .symbol) {
                fn_name = l.items[idx];
                idx += 1;
            }
            if (idx >= l.items.len) return error.ArityError;

            var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
            errdefer {
                for (arities.items) |*a| {
                    a.params.deinit(allocator);
                    a.body.deinit(allocator);
                    if (a.rest_name) |rn| allocator.free(rn);
                }
                allocator.free(arities.items);
            }

            arities = try parseArityForms(allocator, l.items, l.items.len, &idx);

            // Clone env so the fn captures a stable copy of the environment
            const fn_env = try env.clone(allocator);

            // Store optional name for self-reference (used by call to bind in call env)
            var fn_name_str: ?[]const u8 = null;
            if (fn_name) |name_sym| {
                fn_name_str = try allocator.dupe(u8, name_sym.sym_val);
            }

            const fn_val = try Value.fnValueNamed(allocator, arities, fn_env, false, fn_name_str);
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
                    a.params.deinit(allocator);
                    a.body.deinit(allocator);
                    if (a.rest_name) |rn| allocator.free(rn);
                }
                allocator.free(arities.items);
            }

            arities = try parseArityForms(allocator, l.items, l.items.len, &idx);

            const fn_env: Env = .{
                .allocator = allocator,
                .entries = phm.PersistentHashMap.empty(),
                .parent = env,
                .ns_manager = null,
            };
            var macro_fn = try Value.fnValue(allocator, arities, fn_env, true);
            // Clone to main allocator before storing in persistent env
            const persistent_macro = try macro_fn.clone(allocator);
            macro_fn.deinit(allocator);
            // Bind in current namespace's env if namespace manager is available
            try bindInCurrentNamespace(env, macro_name.sym_val, persistent_macro);
            return try macro_name.clone(allocator);
        }

        // defprotocol - define a protocol
        // (defprotocol name docstring? options? (method [params]... docstring?)+)
        if (std.mem.eql(u8, name, "defprotocol")) {
            return try protocols.evalDefProtocol(allocator, l, env, depth + 1);
        }

        // extend - add protocol implementations for a type
        // (extend atype protocol mmap & more...)
        // atype is unevaluated (a keyword like :string)
        // protocol and mmap are evaluated
        if (std.mem.eql(u8, name, "extend")) {
            if (l.items.len < 4) return error.ArityError;
            // Build evaluated arg list: atype (unevaluated), then evaluated pairs
            var ext_args: list.List = .empty;
            errdefer ext_args.deinit(allocator);
            try ext_args.append(allocator, try l.items[1].clone(allocator)); // atype (unevaluated)
            var ei: usize = 2;
            while (ei < l.items.len) : (ei += 1) {
                try ext_args.append(allocator, try evalRec(allocator, l.items[ei], env, depth + 1));
            }
            return try protocols.evalExtend(allocator, ext_args, env, depth + 1);
        }

        // extend-type - convenience form for extend with inline method definitions
        // (extend-type atype protocol (method [params] body...)+ & more...)
        if (std.mem.eql(u8, name, "extend-type")) {
            return try protocols.evalExtendType(allocator, l, env, depth + 1);
        }

        // extend-protocol - extend one protocol for multiple types at once
        // (extend-protocol protocol atype1 (method [params] body...)+ atype2 ...)
        if (std.mem.eql(u8, name, "extend-protocol")) {
            return try protocols.evalExtendProtocol(allocator, l, env, depth + 1);
        }

        // defrecord - define a record type with named fields
        // (defrecord name [fields*] options* specs*)
        if (std.mem.eql(u8, name, "defrecord")) {
            return try records.evalDefRecord(allocator, l, env, depth + 1);
        }

        // do - evaluate a sequence of forms
        if (std.mem.eql(u8, name, "do")) {
            var do_result: Value = Value.nilValue();
            errdefer do_result.deinit(allocator);
            for (l.items[1..]) |form| {
                do_result.deinit(allocator);
                do_result = Value.nilValue();
                do_result = try evalRec(allocator, form, env, depth + 1);
            }
            return do_result;
        }

        // set! - modify a var
        if (std.mem.eql(u8, name, "set!")) {
            if (l.items.len != 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            const val = try evalRec(allocator, l.items[2], env, depth + 1);
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
            errdefer results.deinit(allocator);
            try results.append(allocator, try Value.symValue(allocator, "__recur__"));
            for (l.items[1..]) |arg| {
                try results.append(allocator, try evalRec(allocator, arg, env, depth + 1));
            }
            return Value.listValue(results);
        }

        // loop - named recursion point
        if (std.mem.eql(u8, name, "loop")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLoop(allocator, bindings, l.items[2..], env, depth + 1);
        }

        // var - create a mutable var
        if (std.mem.eql(u8, name, "var")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            var val = if (l.items.len >= 3)
                try evalRec(allocator, l.items[2], env, depth + 1)
            else
                Value.nilValue();
            // Clone to main allocator for persistent env storage
            const persistent_val = try val.clone(allocator);
            val.deinit(allocator);
            try env.put(sym.sym_val, persistent_val);
            return try sym.clone(allocator);
        }

        // deref - get the value of a derefable object (atom, var, etc.)
        if (std.mem.eql(u8, name, "deref") or std.mem.eql(u8, name, "@")) {
            if (l.items.len != 2) return error.ArityError;
            var arg = try evalRec(allocator, l.items[1], env, depth + 1);
            // Extract value from atom
            if (arg.type == .atom) {
                if (arg.atom_val) |data| {
                    const val = try data.value.clone(allocator);
                    arg.deinit(allocator);
                    return val;
                }
                arg.deinit(allocator);
                return Value.nilValue();
            }
            // Extract value from reduced wrapper
            if (arg.type == .reduced) {
                if (arg.reduced_val) |data| {
                    const val = try data.clone(allocator);
                    arg.deinit(allocator);
                    return val;
                }
                arg.deinit(allocator);
                return Value.nilValue();
            }
            return arg;
        }

        // or - short-circuit or
        if (std.mem.eql(u8, name, "or")) {
            var last_val: Value = Value.nilValue();
            errdefer last_val.deinit(allocator);
            for (l.items[1..]) |form_item| {
                const val = try evalRec(allocator, form_item, env, depth + 1);
                if (val.isTruthy()) {
                    last_val.deinit(allocator);
                    return val;
                }
                last_val.deinit(allocator);
                last_val = val;
            }
            return last_val;
        }

        // and - short-circuit and
        if (std.mem.eql(u8, name, "and")) {
            for (l.items[1..]) |form_item| {
                var val = try evalRec(allocator, form_item, env, depth + 1);
                if (!val.isTruthy()) return val;
                val.deinit(allocator);
            }
            return Value.boolValue(true);
        }

        // binding - dynamic variable binding (simplified)
        // Matches Clojure syntax: (binding [var1 val1 var2 val2] body...)
        if (std.mem.eql(u8, name, "binding")) {
            if (l.items.len < 3) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .vector) return error.TypeError;
            var new_env = try env.clone(allocator);
            defer new_env.deinit(allocator);
            defer pushEnvTempRoot(&new_env).deinit();

            var i: usize = 0;
            while (i < bindings.vec_val.items.len) : (i += 2) {
                const sym = bindings.vec_val.items[i];
                if (sym.type != .symbol) return error.TypeError;
                const val = try evalRec(allocator, bindings.vec_val.items[i + 1], env, depth + 1);
                try new_env.put(sym.sym_val, val);
            }
            var do_result: Value = Value.nilValue();
            errdefer do_result.deinit(allocator);
            for (l.items[2..]) |form| {
                do_result.deinit(allocator);
                do_result = Value.nilValue();
                do_result = try evalRec(allocator, form, &new_env, depth + 1);
            }
            return do_result;
        }

        // ->> thread-last macro
        // (->> x (f 1) (g 2 3)) => (g (f x 1) 2 3)
        if (std.mem.eql(u8, name, "->>")) {
            return try eval_thread.evalThreadLast(allocator, l.items[1..], env, depth + 1);
        }

        // -> thread-first macro
        // (-> x (f 1) (g 2 3)) => (g (f 1 x) 2 3)
        if (std.mem.eql(u8, name, "->")) {
            return eval_thread.evalThreadFirst(allocator, l.items[1..], env, depth + 1);
        }

        // lazy-seq - create a lazy sequence
        if (std.mem.eql(u8, name, "lazy-seq")) {
            if (l.items.len < 2) return error.ArityError;
            // Build the thunk body as a list of forms to evaluate
            var body: list.List = .empty;
            errdefer body.deinit(allocator);
            try body.append(allocator, try Value.symValue(allocator, "do"));
            for (l.items[1..]) |form| {
                try body.append(allocator, try form.clone(allocator));
            }
            const thunk = try allocator.create(Value.LazySeqThunk);
            thunk.* = .{
                .params = list.empty(),
                .body = body,
                .env = try env.clone(allocator),
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
                var n_val = try evalRec(allocator, dorun_args[0], env, depth + 1);
                defer n_val.deinit(allocator);
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
            var coll = try evalRec(allocator, coll_form, env, depth + 1);
            defer coll.deinit(allocator);

            // Force lazy_seq if needed
            if (coll.type == .lazy_seq) {
                const forced = try sequences.forceLazySeqHelper(allocator, coll);
                coll.deinit(allocator);
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
                    _ = try sequences.forceLazySeqHelper(allocator, item);
                }
                count += 1;
            }
            return Value.nilValue();
        }

        // doall - realize lazy sequences and return the result
        if (std.mem.eql(u8, name, "doall")) {
            if (l.items.len != 2) return error.ArityError;
            var coll = try evalRec(allocator, l.items[1], env, depth + 1);
            // Handle lazy_seq: force and return
            if (coll.type == .lazy_seq) {
                const forced = try sequences.forceLazySeqHelper(allocator, coll);
                coll.deinit(allocator);
                // Clone to allocator for return
                return try forced.clone(allocator);
            }
            // Handle nil: return empty list (matching Clojure's seq semantics)
            if (coll.type == .nil) {
                coll.deinit(allocator);
                return Value.listValue(list.empty());
            }
            // For concrete collections, just return a clone
            return try coll.clone(allocator);
        }

        // cond-> - thread-first with conditions
        // (cond-> expr test1 step1 test2 step2 ...)
        if (std.mem.eql(u8, name, "cond->")) {
            return try eval_thread.evalCondThreadFirst(allocator, l.items[1..], env, depth + 1);
        }

        // cond->> - thread-last with conditions
        // (cond->> expr test1 step1 test2 step2 ...)
        if (std.mem.eql(u8, name, "cond->>")) {
            return try eval_thread.evalCondThreadLast(allocator, l.items[1..], env, depth + 1);
        }

        // case - multi-way constant dispatch
        // (case expr test1 result1 test2 result2 ... default)
        if (std.mem.eql(u8, name, "case")) {
            return try evalCase(allocator, l.items[1..], env, depth + 1);
        }
    }

    // Non-special-form: evaluate as function call
    return try evalFunctionCall(allocator, l, env, depth + 1);
}

fn evalFunctionCall(allocator: Allocator, l: list.List, env: *Env, depth: usize) anyerror!Value {
    // Evaluate the operator
    var op = try evalRec(allocator, l.items[0], env, depth);
    defer op.deinit(allocator);

    // Check if operator is a macro
    if (op.type == .function and op.fn_val.?.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        errdefer macro_args.deinit(allocator);
        for (l.items[1..]) |arg| {
            try macro_args.append(allocator, try arg.clone(allocator));
        }
        // Call the macro with unevaluated args
        var expanded = try call(allocator, op, macro_args, env, depth);
        // Evaluate the expanded form
        const result = try evalRec(allocator, expanded, env, depth);
        expanded.deinit(allocator);
        return result;
    }

    // Evaluate all arguments
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    for (l.items[1..]) |arg| {
        try args.append(allocator, try evalRec(allocator, arg, env, depth));
    }

    // Transfer ownership of args to call (call will deinit it).
    // Reset local copy to prevent double-free from errdefer.
    const transferred = args;
    args = list.List.empty;

    // Call the function
    return try call(allocator, op, transferred, env, depth);
}

fn evalLet(allocator: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (bindings.type != .list and bindings.type != .vector) return error.TypeError;

    // Heap-allocate Env to reduce C stack pressure during deep recursion.
    // Env is ~416 bytes; keeping it on the stack in debug mode causes overflow.
    const new_env = try allocator.create(Env);
    errdefer allocator.destroy(new_env);
    new_env.* = try env.clone(allocator);
    defer new_env.deinit(allocator);
    defer pushEnvTempRoot(new_env).deinit();
    defer allocator.destroy(new_env);

    const items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => unreachable,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const sym = items[i];
        // Evaluate binding value in new_env so later bindings can reference earlier ones
        const val = try evalRec(allocator, items[i + 1], new_env, depth);
        // Bind using destructuring if sym is a vector pattern
        try bindPattern(allocator, sym, val, new_env, depth);
    }

    var do_result: Value = Value.nilValue();
    errdefer do_result.deinit(allocator);
    for (body) |form| {
        do_result.deinit(allocator);
        do_result = Value.nilValue();
        do_result = try evalRec(allocator, form, new_env, depth);
    }
    return do_result;
}

fn evalLetFn(allocator: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    const bind_items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => return error.TypeError,
    };

    // Create new env first so all functions can reference each other
    var new_env: Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = env,
        .ns_manager = null,
    };
    defer new_env.deinit(allocator);
    defer pushEnvTempRoot(&new_env).deinit();

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
            try helpers.listFromVector(allocator, params_form.vec_val)
        else
            params_form.list_val;

        // Remaining elements are the body
        var body_list: list.List = .empty;
        errdefer body_list.deinit(allocator);
        try body_list.append(allocator, try Value.symValue(allocator, "do"));
        for (b.items[2..]) |form_item| {
            try body_list.append(allocator, try form_item.clone(allocator));
        }

        // Parse params for variadic support
        var parsed = try parseParams(allocator, params_list);
        defer {
            parsed.params.deinit(allocator);
            if (parsed.rest_name) |rn| allocator.free(rn);
        }

        // Build arity
        var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
        errdefer {
            for (arities.items) |*a| {
                a.params.deinit(allocator);
                a.body.deinit(allocator);
                if (a.rest_name) |rn| allocator.free(rn);
            }
            allocator.free(arities.items);
        }

        const cloned_params = try list.clone(&parsed.params, allocator);
        const cloned_body = try list.clone(&body_list, allocator);
        const cloned_rest = if (parsed.rest_name) |rn| try allocator.dupe(u8, rn) else null;
        try arities.append(allocator, Value.Arity{
            .params = cloned_params,
            .body = cloned_body,
            .rest_name = cloned_rest,
        });

        // Create fn with new_env as closure (for mutual recursion)
        const fn_env: Env = .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = &new_env,
            .ns_manager = null,
        };
        var fn_val = try Value.fnValue(allocator, arities, fn_env, false);
        const persistent_fn = try fn_val.clone(allocator);
        fn_val.deinit(allocator);

        // Bind in new_env
        try new_env.put(fname.sym_val, persistent_fn);
    }

    var do_result: Value = Value.nilValue();
    errdefer do_result.deinit(allocator);
    for (body) |form| {
        do_result.deinit(allocator);
        do_result = Value.nilValue();
        do_result = try evalRec(allocator, form, &new_env, depth);
    }
    return do_result;
}

/// Bind a value to a pattern. Supports simple symbols and vector destructuring with & rest.
fn bindPattern(allocator: Allocator, pattern: Value, val: Value, env: *Value.Env, depth: usize) anyerror!void {
    switch (pattern.type) {
        .symbol => {
            try env.put(pattern.sym_val, try val.clone(allocator));
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
                        errdefer rest_list.deinit(allocator);
                        var k: usize = j;
                        while (k < vitems.len) : (k += 1) {
                            try rest_list.append(allocator, try vitems[k].clone(allocator));
                        }
                        if (rest_sym.type == .symbol) {
                            try env.put(rest_sym.sym_val, Value.listValue(rest_list));
                        }
                        j += 1; // Skip the rest symbol
                    }
                    break;
                } else if (j < vitems.len) {
                    try bindPattern(allocator, pat_item, vitems[j], env, depth);
                }
            }
        },
        else => return error.TypeError,
    }
}

fn evalCond(allocator: Allocator, clauses: []const Value, env: *Env, depth: usize) anyerror!Value {
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const cond = clauses[i];
        // Handle :else clause
        if (cond.type == .keyword and std.mem.eql(u8, cond.kw_val, "else")) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, clauses[i + 1], env, depth);
        }

        var result = try evalRec(allocator, cond, env, depth);
        if (result.isTruthy()) {
            if (i + 1 >= clauses.len) return error.ArityError;
            result.deinit(allocator);
            return try evalRec(allocator, clauses[i + 1], env, depth);
        }
        result.deinit(allocator);
    }
    return Value.nilValue();
}

fn evalLoop(allocator: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (bindings.type != .list and bindings.type != .vector) return error.TypeError;

    const bind_items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => unreachable,
    };

    // Extract binding names
    var bind_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (bind_names.items) |name| allocator.free(name);
        allocator.free(bind_names.items);
    }
    var i: usize = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        if (sym.type != .symbol) return error.TypeError;
        try bind_names.append(allocator, try allocator.dupe(u8, sym.sym_val));
    }

    // Initialize environment with initial binding values
    var new_env = try env.clone(allocator);
    defer new_env.deinit(allocator);
    defer pushEnvTempRoot(&new_env).deinit();

    i = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        const val = try evalRec(allocator, bind_items[i + 1], env, depth);
        try new_env.put(sym.sym_val, val);
    }

    // Loop: evaluate body, check for recur marker, rebind and repeat
    var loop_depth: usize = depth;
    while (true) {
        if (loop_depth > MAX_RECURSION) return error.RecursionLimit;

        var result: Value = Value.nilValue();
        errdefer result.deinit(allocator);
        for (body) |form| {
            result.deinit(allocator);
            result = Value.nilValue();
            result = try evalRec(allocator, form, &new_env, loop_depth);
        }

        // Check for recur marker: list starting with __recur__ symbol
        if (result.type == .list and result.list_val.items.len > 0 and
            result.list_val.items[0].type == .symbol and
            std.mem.eql(u8, result.list_val.items[0].sym_val, "__recur__"))
        {
            const recur_vals = result.list_val.items[1..];
            if (recur_vals.len != bind_names.items.len) {
                result.deinit(allocator);
                return error.ArityError;
            }
            // Rebind loop variables with new values
            var j: usize = 0;
            while (j < recur_vals.len) : (j += 1) {
                const new_val = try recur_vals[j].clone(allocator);
                try new_env.put(bind_names.items[j], new_val);
            }
            result.deinit(allocator);
            loop_depth += 1;
            continue;
        }

        return result;
    }
}

pub fn call(allocator: Allocator, op: Value, args_list: list.List, env: *Env, depth: usize) anyerror!Value {
    var args = args_list;
    defer args.deinit(allocator);

    switch (op.type) {
        .function => {
            const fn_data = op.fn_val orelse return error.TypeError;
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

            // Heap-allocate Env to reduce C stack pressure during deep recursion.
            // Env is ~416 bytes; keeping it on the stack in debug mode causes overflow.
            const new_env = try allocator.create(Env);
            errdefer allocator.destroy(new_env);
            // Optimization: skip env clone if no local entries
            if (!fn_data.env.entries.isEmpty()) {
                new_env.* = try fn_data.env.clone(allocator);
            } else {
                new_env.* = .{
                    .allocator = allocator,
                    .entries = phm.PersistentHashMap.empty(),
                    .parent = fn_data.env.parent,
                    .ns_manager = null,
                };
            }
            defer new_env.deinit(allocator);
            defer pushEnvTempRoot(new_env).deinit();
            defer allocator.destroy(new_env);

            // Bind function name for self-reference (e.g., (fn self [x] (self (dec x))))
            if (fn_data.name) |fn_name| {
                const fn_clone = try op.clone(allocator);
                try new_env.put(fn_name, fn_clone);
            }

            const min_args = arity.params.items.len;
            const has_rest = arity.rest_name != null;

            // Bind regular parameters to arguments (with destructuring support)
            var j: usize = 0;
            while (j < arity.params.items.len) : (j += 1) {
                const param = arity.params.items[j];
                try bindParam(allocator, param, args.items[j], new_env);
            }

            // Bind rest parameter to remaining args as a list
            if (has_rest and args.items.len > min_args) {
                var rest_list: list.List = .empty;
                errdefer rest_list.deinit(allocator);
                var k: usize = min_args;
                while (k < args.items.len) : (k += 1) {
                    try rest_list.append(allocator, try args.items[k].clone(allocator));
                }
                try new_env.put(arity.rest_name.?, Value.listValue(rest_list));
            } else if (has_rest) {
                // No extra args: bind empty list to rest parameter
                try new_env.put(arity.rest_name.?, Value.listValue(.empty));
            }

            // Check for protocol dispatch marker
            if (arity.body.items.len >= 1 and
                arity.body.items[0].type == .symbol and
                std.mem.eql(u8, arity.body.items[0].sym_val, "__protocol_dispatch__"))
            {
                // Protocol dispatch: call the dispatcher with all args
                return try protocols.dispatchProtocolMethod(
                    allocator,
                    args,
                    new_env,
                    depth,
                );
            }

            // Evaluate the function body
            return try evalRec(allocator, Value.listValue(arity.body), new_env, depth);
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
                    return try item.clone(allocator);
                }
            }
            return Value.nilValue();
        },
        .keyword => {
            // Keyword as function: looks up the keyword in a map or record
            if (args.items.len != 1) return error.ArityError;
            const coll = args.items[0];
            if (coll.type == .map) {
                for (coll.map_val.items) |entry| {
                    if (entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, op.kw_val)) {
                        return try entry.value.clone(allocator);
                    }
                }
            } else if (coll.type == .record) {
                // Look up in fields first, then extmap
                for (coll.record_val.?.fields.items) |entry| {
                    if (entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, op.kw_val)) {
                        return try entry.value.clone(allocator);
                    }
                }
                for (coll.record_val.?.extmap.items) |entry| {
                    if (entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, op.kw_val)) {
                        return try entry.value.clone(allocator);
                    }
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
                    return try entry.value.clone(allocator);
                }
            }
            // Return not-found value if provided
            if (args.items.len == 2) {
                return try args.items[1].clone(allocator);
            }
            return Value.nilValue();
        },
        .record => {
            // Record as function: returns value for key (fields first, then extmap)
            if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
            const key = args.items[0];
            for (op.record_val.?.fields.items) |entry| {
                if (entry.key.equals(key)) {
                    return try entry.value.clone(allocator);
                }
            }
            for (op.record_val.?.extmap.items) |entry| {
                if (entry.key.equals(key)) {
                    return try entry.value.clone(allocator);
                }
            }
            // Return not-found value if provided
            if (args.items.len == 2) {
                return try args.items[1].clone(allocator);
            }
            return Value.nilValue();
        },
        .lazy_seq => {
            // Force evaluation of lazy sequence
            if (args.items.len != 0) return error.ArityError;
            return try forceLazySeq(allocator, op, env, depth);
        },
        else => {
            std.debug.print("NotCallable: tried to call value of type {s}\n", .{@tagName(op.type)});
            return error.NotCallable;
        }
    }
}

// Flatten a cons chain into a list for doall/dorun.
// Recursively forces any nested lazy_seqs.
fn flattenConsForDoall(allocator: Allocator, val: Value, env: *Env, depth: usize, target: *list.List) anyerror!void {
    var current = val;
    errdefer current.deinit(allocator);

    while (true) {
        switch (current.type) {
            .cons => {
                // Force the head if it's a lazy_seq
                const cdata = current.cons_val.?;
                const head = cdata.head;
                if (head.type == .lazy_seq) {
                    var head_forced = try forceLazySeq(allocator, try head.clone(allocator), env, depth + 1);
                    if (head_forced.type == .list) {
                        for (head_forced.list_val.items) |fi| {
                            try target.append(allocator, try fi.clone(allocator));
                        }
                    } else {
                        try target.append(allocator, head_forced);
                    }
                    head_forced.deinit(allocator);
                } else {
                    try target.append(allocator, try head.clone(allocator));
                }
                // Move to tail
                const tail = try cdata.tail.clone(allocator);
                current.deinit(cdata.allocator);
                current = tail;
            },
            .list => {
                for (current.list_val.items) |item| {
                    if (item.type == .lazy_seq) {
                        var forced = try forceLazySeq(allocator, item, env, depth + 1);
                        if (forced.type == .list) {
                            for (forced.list_val.items) |fi| {
                                try target.append(allocator, try fi.clone(allocator));
                            }
                        }
                        forced.deinit(allocator);
                    } else {
                        try target.append(allocator, try item.clone(allocator));
                    }
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                // Force the lazy_seq and flatten
                var forced = try forceLazySeq(allocator, current, env, depth + 1);
                if (forced.type == .list) {
                    for (forced.list_val.items) |fi| {
                        try target.append(allocator, try fi.clone(allocator));
                    }
                }
                forced.deinit(allocator);
                break;
            },
            else => {
                try target.append(allocator, current);
                current = Value.nilValue();
                break;
            },
        }
    }
    current.deinit(allocator);
}

// Force evaluation of a lazy sequence, returning the resulting list
fn forceLazySeq(allocator: Allocator, lazy: Value, env: *Env, depth: usize) anyerror!Value {
    // Evaluate the thunk
    if (lazy.lazy_seq_val.thunk) |thunk| {
        // Clone thunk data for evaluation — don't free the thunk itself
        // since the original Value (e.g. stored in env) still holds the pointer.
        // The thunk will be properly freed when the original Value is deinited.
        var cloned_params = try list.clone(&thunk.params, allocator);
        var cloned_body = try list.clone(&thunk.body, allocator);
        var thunk_env = try thunk.env.clone(allocator);
        // CRITICAL: Set thunk_env.allocator to persistent allocator
        thunk_env.allocator = allocator;
        defer {
            cloned_params.deinit(allocator);
            cloned_body.deinit(allocator);
            thunk_env.deinit(allocator);
        }

        // Evaluate the body to get the result
        var result = try evalRec(allocator, Value.listValue(cloned_body), &thunk_env, depth);

        // The result should be a list/vector (the sequence)
        // Convert to list if needed
        var final_list: list.List = .empty;
        errdefer final_list.deinit(allocator);

        switch (result.type) {
            .list => {
                // Handle cons cell pattern: [head, lazy_seq_tail]
                if (result.list_val.items.len == 2 and result.list_val.items[1].type == .lazy_seq) {
                    const head_item = result.list_val.items[0];
                    if (head_item.type == .lazy_seq) {
                        const head_forced = try forceLazySeq(allocator, head_item, env, depth + 1);
                        try final_list.append(allocator, head_forced);
                    } else {
                        try final_list.append(allocator, try head_item.clone(allocator));
                    }
                    var tail_forced = try forceLazySeq(allocator, result.list_val.items[1], env, depth + 1);
                    if (tail_forced.type == .list) {
                        for (tail_forced.list_val.items) |fi| {
                            try final_list.append(allocator, try fi.clone(allocator));
                        }
                    }
                    tail_forced.deinit(allocator);
                } else {
                    for (result.list_val.items) |item| {
                        // Recursively force nested lazy_seqs for doall/dorun
                        if (item.type == .lazy_seq) {
                            var forced = try forceLazySeq(allocator, item, env, depth + 1);
                            if (forced.type == .list) {
                                for (forced.list_val.items) |fi| {
                                    try final_list.append(allocator, try fi.clone(allocator));
                                }
                            }
                            forced.deinit(allocator);
                        } else {
                            try final_list.append(allocator, try item.clone(allocator));
                        }
                    }
                }
            },
            .vector => {
                for (result.vec_val.items) |item| {
                    if (item.type == .lazy_seq) {
                        var forced = try forceLazySeq(allocator, item, env, depth + 1);
                        if (forced.type == .list) {
                            for (forced.list_val.items) |fi| {
                                try final_list.append(allocator, try fi.clone(allocator));
                            }
                        }
                        forced.deinit(allocator);
                    } else {
                        try final_list.append(allocator, try item.clone(allocator));
                    }
                }
            },
            .nil => {}, // empty sequence
            .lazy_seq => {
                // Recursively force for doall/dorun
                var forced = try forceLazySeq(allocator, result, env, depth + 1);
                if (forced.type == .list) {
                    for (forced.list_val.items) |fi| {
                        try final_list.append(allocator, try fi.clone(allocator));
                    }
                }
                forced.deinit(allocator);
            },
            .cons => {
                // Walk the cons chain and flatten into the list
                try flattenConsForDoall(allocator, result, env, depth + 1, &final_list);
            },
            else => {
                try final_list.append(allocator, result);
            },
        }

        result.deinit(allocator);
        return Value.listValue(final_list);
    }

    return Value.listValue(list.empty());
}

// Bind a parameter to an argument, supporting destructuring
// e.g., param=[a b], arg=[1 2] => binds a=1, b=2
fn bindParam(allocator: Allocator, param: Value, arg: Value, env: *Env) anyerror!void {
    switch (param.type) {
        .symbol => {
            try env.put(param.sym_val, try arg.clone(allocator));
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
                try bindParam(allocator, param.vec_val.items[i], arg_items[i], env);
            }
        },
        .list => {
            // Same as vector but from a list
            if (param.list_val.items.len != arg.list_val.items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.list_val.items.len) : (i += 1) {
                try bindParam(allocator, param.list_val.items[i], arg.list_val.items[i], env);
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
fn evalCase(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len < 1) return error.ArityError;

    var expr_val = try evalRec(allocator, forms[0], env, depth);
    defer expr_val.deinit(allocator);

    var i: usize = 1;
    while (i < forms.len) : (i += 2) {
        const test_form = forms[i];
        if (test_form.type == .keyword and std.mem.eql(u8, test_form.kw_val, "else")) {
            if (i + 1 >= forms.len) return error.ArityError;
            return try evalRec(allocator, forms[i + 1], env, depth);
        }

        var test_val = try evalRec(allocator, test_form, env, depth);
        defer test_val.deinit(allocator);

        if (expr_val.equals(test_val)) {
            if (i + 1 >= forms.len) return error.ArityError;
            return try evalRec(allocator, forms[i + 1], env, depth);
        }
    }

    return Value.nilValue();
}
