const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = vm.Env;
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

/// Allocate a Value on the GC heap and initialize it from a stack Value.
/// Used for Values constructed directly (not cloned), e.g. vm.nilValue(), vm.listValue(...).
pub fn allocValue(allocator: Allocator, val: Value) anyerror!*Value {
    const ptr = try allocator.create(Value);
    ptr.* = val;
    return ptr;
}

/// Dereference and deinit a *Value, used for intermediate results that won't be returned.
pub fn deallocValue(allocator: Allocator, ptr: *Value) void {
    ptr.*.deinit(allocator);
    // Don't destroy - GC manages the memory
}

/// Unified special form handler signature.
const SpecialFormFn = *const fn (Allocator, *const list.List, *Env, usize) anyerror!*Value;

/// Dispatch table: static array of special form names → handler functions.
/// Linear search over ~42 entries is trivial and avoids any allocation.
const special_forms = [_]struct { name: []const u8, fn_ptr: SpecialFormFn }{
    .{ .name = "quit", .fn_ptr = evalQuit },
    .{ .name = "exit", .fn_ptr = evalQuit },
    .{ .name = "quote", .fn_ptr = evalQuote },
    .{ .name = "quasiquote", .fn_ptr = evalQuasiquote },
    .{ .name = "def", .fn_ptr = evalDef },
    .{ .name = "let", .fn_ptr = evalLet },
    .{ .name = "letfn", .fn_ptr = evalLetFn },
    .{ .name = "if", .fn_ptr = evalIf },
    .{ .name = "when", .fn_ptr = evalWhen },
    .{ .name = "cond", .fn_ptr = evalCond },
    .{ .name = "defn", .fn_ptr = evalDefn },
    .{ .name = "defn-", .fn_ptr = evalDefn },
    .{ .name = "fn", .fn_ptr = evalFn },
    .{ .name = "defmacro", .fn_ptr = evalDefmacro },
    .{ .name = "do", .fn_ptr = evalDo },
    .{ .name = "set!", .fn_ptr = evalSetBang },
    .{ .name = "recur", .fn_ptr = evalRecur },
    .{ .name = "loop", .fn_ptr = evalLoop },
    .{ .name = "var", .fn_ptr = evalVar },
    .{ .name = "deref", .fn_ptr = evalDeref },
    .{ .name = "@", .fn_ptr = evalDeref },
    .{ .name = "or", .fn_ptr = evalOr },
    .{ .name = "and", .fn_ptr = evalAnd },
    .{ .name = "binding", .fn_ptr = evalBinding },
    .{ .name = "lazy-seq", .fn_ptr = evalLazySeq },
    .{ .name = "dorun", .fn_ptr = evalDorun },
    .{ .name = "doall", .fn_ptr = evalDoall },
    .{ .name = "extend", .fn_ptr = evalExtend },
    .{ .name = "ns", .fn_ptr = evalNsForm },
    .{ .name = "in-ns", .fn_ptr = evalInNsForm },
    .{ .name = "defprotocol", .fn_ptr = evalDefprotocolForm },
    .{ .name = "extend-type", .fn_ptr = evalExtendTypeForm },
    .{ .name = "extend-protocol", .fn_ptr = evalExtendProtocolForm },
    .{ .name = "defrecord", .fn_ptr = evalDefrecordForm },
    .{ .name = "->>", .fn_ptr = evalThreadLastForm },
    .{ .name = "->", .fn_ptr = evalThreadFirstForm },
    .{ .name = "cond->", .fn_ptr = evalCondThreadFirstForm },
    .{ .name = "cond->>", .fn_ptr = evalCondThreadLastForm },
    .{ .name = "case", .fn_ptr = evalCaseForm },
};

/// Look up a special form handler by name. Returns null if not a special form.
fn findSpecialForm(name: []const u8) ?SpecialFormFn {
    for (special_forms) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.fn_ptr;
        }
    }
    return null;
}

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
pub fn eval(allocator: Allocator, form: Value, env: *Env) anyerror!*Value {
    return evalRec(allocator, &form, env, 0);
}

pub fn evalRec(allocator: Allocator, form: *const Value, env: *Env, depth: usize) anyerror!*Value {
    if (depth > MAX_RECURSION) return error.RecursionLimit;

    switch (form.*.type) {
        .nil, .bool, .integer, .float, .bigint, .ratio, .decimal, .string, .regex, .character, .keyword, .set, .queue, .atom, .reduced, .wrapped, .record => {
            return try form.*.cloneGC(allocator);
        },
        .symbol => {
            if (std.mem.eql(u8, form.*.sym_val, "quote") or
                std.mem.eql(u8, form.*.sym_val, "quasiquote") or
                std.mem.eql(u8, form.*.sym_val, "unquote") or
                std.mem.eql(u8, form.*.sym_val, "unquote-splicing"))
            {
                return try form.*.cloneGC(allocator);
            }
            // Handle qualified symbols: alias/name or namespace/name
            if (std.mem.indexOfScalar(u8, form.*.sym_val, '/')) |slash_idx| {
                const alias = form.*.sym_val[0..slash_idx];
                const name = form.*.sym_val[slash_idx + 1 ..];
                // Resolve through namespace manager
                const ns_mgr = findNsManager(env) orelse {
                    const val2 = env.get(form.*.sym_val);
                    if (val2) |v| return try v.cloneGC(allocator);
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.*.sym_val});
                    return error.UndefinedSymbol;
                };
                // Look up alias in current namespace, or use the part before '/' as a direct namespace name
                const current_ns = ns_mgr.getCurrentNamespace();
                const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
                // Get target namespace's env and look up the name
                const target_env = ns_mgr.getNamespace(target_ns) orelse {
                    // Target namespace doesn't exist, try direct lookup
                    const val3 = env.get(form.*.sym_val);
                    if (val3) |v| return try v.cloneGC(allocator);
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.*.sym_val});
                    return error.UndefinedSymbol;
                };
                const val4 = target_env.get(name);
                if (val4) |v| return try v.cloneGC(allocator);
                std.debug.print("Undefined symbol: '{s}'\n", .{form.*.sym_val});
                return error.UndefinedSymbol;
            }
            const val = env.get(form.*.sym_val);
            if (val) |v| return try v.cloneGC(allocator);
            std.debug.print("Undefined symbol: '{s}'\n", .{form.*.sym_val});
            return error.UndefinedSymbol;
        },
        .list => {
            return try evalList(allocator, &form.*.list_val, env, depth);
        },
        .vector => {
            return try evalVector(allocator, form, env, depth);
        },
        .map => {
            return try evalMap(allocator, form, env, depth);
        },
        .function, .builtin_fn => return try form.*.cloneGC(allocator),
        .lazy_seq => return try form.*.cloneGC(allocator),
        .cons => {
            return try evalCons(allocator, form, env, depth);
        },
    }
    unreachable;
}

// Parse ([params] body...)+ pairs from a list slice.
// Returns an ArrayListUnmanaged(vm.Arity) and updates *idx to point past the last consumed item.
// Handles both flattened form: (fn [x] body) and wrapped form: (fn ([x] body))
fn parseArityForms(allocator: Allocator, items: []const Value, end: usize, idx: *usize) anyerror!std.ArrayListUnmanaged(vm.Arity) {
    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
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

        if (std.meta.activeTag(form) == .vector) {
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
        } else if (std.meta.activeTag(form) == .list) {
            // Wrapped form: (fn ([x] body1 body2) ([y] body3))
            // Or: (fn (x y) body) from macro-generated code where (list x y) creates (x y)
            // Extract params and body from within the list
            if (form.list_val.items.len == 0) return error.TypeError;
            const inner_first = form.list_val.items[0];
            if (std.meta.activeTag(inner_first) == .vector) {
                // Standard: (fn ([x] body))
                params_list = try helpers.listFromVector(allocator, inner_first.vec_val);
                body_forms = form.list_val.items[1..];
            } else if (std.meta.activeTag(inner_first) == .list) {
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
        try body_list.append(allocator, try vm.symValue(allocator, "do"));
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
        try arities.append(allocator, vm.Arity{
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
        if (!found_amp and std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.sym_val, "&")) {
            found_amp = true;
            continue;
        }
        if (found_amp) {
            // The symbol after & is the rest parameter name
            if (std.meta.activeTag(item) != .symbol) return error.TypeError;
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

fn evalList(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len == 0) return try allocValue(allocator, vm.listValue(list.empty()));

    const first = l.items[0];

    // Self-evaluating symbols (special forms) — dispatch via lookup table
    if (std.meta.activeTag(first) == .symbol) {
        if (findSpecialForm(first.sym_val)) |fn_ptr| {
            return fn_ptr(allocator, l, env, depth);
        }
    }

    // Non-special-form: evaluate as function call
    return try evalFunctionCall(allocator, l, env, depth + 1);
}

/// Evaluate a vector element-wise.
/// Extracted from evalRec to isolate its stack frame.
fn evalVector(allocator: Allocator, form: *const Value, env: *Env, depth: usize) anyerror!*Value {
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(allocator);
    for (form.*.vec_val.items) |item| {
        const ptr = try evalRec(allocator, &item, env, depth + 1);
        try new_vec.append(allocator, ptr.*);
    }
    return try allocValue(allocator, vm.vectorValue(new_vec));
}

/// Evaluate a map key-value pairs element-wise.
/// Extracted from evalRec to isolate its stack frame.
fn evalMap(allocator: Allocator, form: *const Value, env: *Env, depth: usize) anyerror!*Value {
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_map.items);
    }
    for (form.*.map_val.items) |entry| {
        const key_ptr = try evalRec(allocator, &entry.key, env, depth + 1);
        const val_ptr = try evalRec(allocator, &entry.value, env, depth + 1);
        try new_map.append(allocator, .{
            .key = key_ptr.*,
            .value = val_ptr.*,
        });
    }
    return try allocValue(allocator, vm.mapValue(new_map));
}

/// Evaluate a cons cell as a form: convert cons chain to list, then evaluate.
/// Extracted from evalRec to isolate its stack frame (cons evaluation needs a Value copy).
fn evalCons(allocator: Allocator, form: *const Value, env: *Env, depth: usize) anyerror!*Value {
    var new_list: list.List = .empty;
    errdefer new_list.deinit(allocator);
    var current_val = form.*;
    while (std.meta.activeTag(current_val) == .cons) {
        const cdata = current_val.cons_val orelse break;
        try new_list.append(allocator, try cdata.head.clone(allocator));
        current_val = cdata.tail;
    }
    // If tail is a list, splice in its elements
    if (std.meta.activeTag(current_val) == .list) {
        for (current_val.list_val.items) |item| {
            try new_list.append(allocator, try item.clone(allocator));
        }
    } else if (std.meta.activeTag(current_val) != .nil) {
        // Improper list - append the tail as a final element
        try new_list.append(allocator, try current_val.clone(allocator));
    }
    return try evalList(allocator, &new_list, env, depth);
}

fn evalFunctionCall(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    // Evaluate the operator
    const op_ptr = try evalRec(allocator, &l.items[0], env, depth);
    defer op_ptr.*.deinit(allocator);

    // Check if operator is a macro
    if (std.meta.activeTag(op_ptr) == .function and op_ptr.fn_val.?.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        defer macro_args.deinit(allocator);
        for (l.items[1..]) |arg| {
            try macro_args.append(allocator, try arg.clone(allocator));
        }
        // Call the macro with unevaluated args — returns Value by value
        var expanded = try call(allocator, op_ptr, &macro_args, env, depth);
        // Evaluate the expanded form
        const result = try evalRec(allocator, &expanded, env, depth);
        expanded.deinit(allocator);
        return result;
    }

    // Evaluate all arguments
    var args: list.List = .empty;
    defer args.deinit(allocator);
    for (l.items[1..]) |arg| {
        const ptr = try evalRec(allocator, &arg, env, depth);
        try args.append(allocator, ptr.*);
    }

    // Call the function — returns Value by value, allocate once for return
    const result = try call(allocator, op_ptr, &args, env, depth);
    return try allocValue(allocator, result);
}

fn evalLet(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2) return error.ArityError;
    const bindings = &l.items[1];
    if (std.meta.activeTag(bindings) != .list and std.meta.activeTag(bindings) != .vector) return error.TypeError;
    const body = l.items[2..];

    // Heap-allocate Env to reduce C stack pressure during deep recursion.
    // Env is ~416 bytes; keeping it on the stack in debug mode causes overflow.
    const new_env = try allocator.create(Env);
    errdefer allocator.destroy(new_env);
    new_env.* = try env.clone(allocator);
    defer new_env.deinit(allocator);
    defer pushEnvTempRoot(new_env).deinit();
    defer allocator.destroy(new_env);

    const items = switch (std.meta.activeTag(bindings)) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => unreachable,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const sym = &items[i];
        // Evaluate binding value in new_env so later bindings can reference earlier ones
        const val_ptr = try evalRec(allocator, &items[i + 1], new_env, depth);
        // Bind using destructuring if sym is a vector pattern
        try bindPattern(allocator, sym.*, val_ptr.*, new_env, depth);
    }

    // Evaluate body forms, returning the last result.
    // Keep a *Value pointer instead of copying Value onto the stack.
    var last_ptr: ?*Value = null;
    errdefer {
        if (last_ptr) |p| {
            p.*.deinit(allocator);
            allocator.destroy(p);
        }
    }
    for (body) |form| {
        if (last_ptr) |p| {
            p.*.deinit(allocator);
            allocator.destroy(p);
        }
        last_ptr = try evalRec(allocator, &form, new_env, depth);
    }
    if (last_ptr) |p| {
        const result = p.*;
        allocator.destroy(p);
        return try allocValue(allocator, result);
    }
    return try allocValue(allocator, vm.nilValue());
}

fn evalLetFn(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2) return error.ArityError;
    const bindings = l.items[1];
    if (std.meta.activeTag(bindings) != .list and std.meta.activeTag(bindings) != .vector) return error.TypeError;
    const body_forms = l.items[2..];
    const bind_items = switch (std.meta.activeTag(bindings)) {
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
        if (std.meta.activeTag(binding) != .list or binding.list_val.items.len < 3) return error.TypeError;
        const b = binding.list_val;

        // First element is the function name
        const fname = b.items[0];
        if (std.meta.activeTag(fname) != .symbol) return error.TypeError;

        // Second element is the parameter list
        const params_form = b.items[1];
        if (std.meta.activeTag(params_form) != .list and std.meta.activeTag(params_form) != .vector) return error.TypeError;
        const params_list = if (std.meta.activeTag(params_form) == .vector)
            try helpers.listFromVector(allocator, params_form.vec_val)
        else
            params_form.list_val;

        // Remaining elements are the body
        var body_list: list.List = .empty;
        errdefer body_list.deinit(allocator);
        try body_list.append(allocator, try vm.symValue(allocator, "do"));
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
        var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
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
        try arities.append(allocator, vm.Arity{
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
        var fn_val = try vm.fnValue(allocator, arities, fn_env, false);
        const persistent_fn = try fn_val.clone(allocator);
        fn_val.deinit(allocator);

        // Bind in new_env
        try new_env.put(fname.sym_val, persistent_fn);
    }

    var do_result: Value = vm.nilValue();
    errdefer do_result.deinit(allocator);
    for (body_forms) |form| {
        const result_ptr = try evalRec(allocator, &form, &new_env, depth);
        do_result.deinit(allocator);
        do_result = result_ptr.*;
    }
    return try allocValue(allocator, do_result);
}

/// Bind a value to a pattern. Supports simple symbols and vector destructuring with & rest.
fn bindPattern(allocator: Allocator, pattern: Value, val: Value, env: *vm.Env, depth: usize) anyerror!void {
    switch (std.meta.activeTag(pattern)) {
        .symbol => {
            try env.put(pattern.sym_val, try val.clone(allocator));
        },
        .vector => {
            // Vector destructuring: [a b & rest] matches elements of val
            const vitems = switch (std.meta.activeTag(val)) {
                .list => val.list_val.items,
                .vector => val.vec_val.items,
                else => return error.TypeError,
            };
            var j: usize = 0;
            while (j < pattern.vec_val.items.len) : (j += 1) {
                const pat_item = pattern.vec_val.items[j];
                // Handle & rest (& is parsed as a symbol)
                if (std.meta.activeTag(pat_item) == .symbol and std.mem.eql(u8, pat_item.sym_val, "&")) {
                    if (j + 1 < pattern.vec_val.items.len) {
                        const rest_sym = pattern.vec_val.items[j + 1];
                        // Collect remaining items into a list (starting from current position j)
                        var rest_list: list.List = .empty;
                        errdefer rest_list.deinit(allocator);
                        var k: usize = j;
                        while (k < vitems.len) : (k += 1) {
                            try rest_list.append(allocator, try vitems[k].clone(allocator));
                        }
                        if (std.meta.activeTag(rest_sym) == .symbol) {
                            try env.put(rest_sym.sym_val, vm.listValue(rest_list));
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

fn evalCond(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2) return error.ArityError;
    const clauses = l.items[1..];
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const cond = clauses[i];
        // Handle :else clause
        if (std.meta.activeTag(cond) == .keyword and std.mem.eql(u8, cond.kw_val, "else")) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, &clauses[i + 1], env, depth);
        }

        const result_ptr = try evalRec(allocator, &cond, env, depth);
        if (result_ptr.isTruthy()) {
            if (i + 1 >= clauses.len) return error.ArityError;
            result_ptr.*.deinit(allocator);
            return try evalRec(allocator, &clauses[i + 1], env, depth);
        }
        result_ptr.*.deinit(allocator);
    }
    return try allocValue(allocator, vm.nilValue());
}

fn evalLoop(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2) return error.ArityError;
    const bindings = l.items[1];
    if (std.meta.activeTag(bindings) != .list and std.meta.activeTag(bindings) != .vector) return error.TypeError;
    const body = l.items[2..];

    const bind_items = switch (std.meta.activeTag(bindings)) {
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
        if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
        try bind_names.append(allocator, try allocator.dupe(u8, sym.sym_val));
    }

    // Initialize environment with initial binding values
    var new_env = try env.clone(allocator);
    defer new_env.deinit(allocator);
    defer pushEnvTempRoot(&new_env).deinit();

    i = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        const val_ptr = try evalRec(allocator, &bind_items[i + 1], env, depth);
        try new_env.put(sym.sym_val, val_ptr.*);
    }

    // Loop: evaluate body, check for recur marker, rebind and repeat
    var loop_depth: usize = depth;
    while (true) {
        if (loop_depth > MAX_RECURSION) return error.RecursionLimit;

        var result: Value = vm.nilValue();
        errdefer result.deinit(allocator);
        for (body) |form| {
            const result_ptr = try evalRec(allocator, &form, &new_env, loop_depth);
            result.deinit(allocator);
            result = result_ptr.*;
        }

        // Check for recur marker: list starting with __recur__ symbol
        if (std.meta.activeTag(result) == .list and result.list_val.items.len > 0 and
            std.meta.activeTag(result.list_val.items[0]) == .symbol and
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

        return try allocValue(allocator, result);
    }
}

pub fn call(allocator: Allocator, op: *const Value, args_list: *const list.List, env: *Env, depth: usize) anyerror!Value {
    switch (std.meta.activeTag(op)) {
        .function => return callFunction(allocator, op, args_list, env, depth),
        .builtin_fn => return callBuiltinFn(allocator, op, args_list, env),
        .set => return callSet(allocator, op, args_list),
        .keyword => return callKeyword(allocator, op, args_list),
        .map => return callMap(allocator, op, args_list),
        .record => return callRecord(allocator, op, args_list),
        .lazy_seq => return callLazySeq(allocator, op, env, depth),
        else => {
            std.debug.print("NotCallable: tried to call value of type {s}\n", .{@tagName(std.meta.activeTag(op))});
            return error.NotCallable;
        }
    }
}

/// Call a user-defined function: match arity, bind params, evaluate body.
fn callFunction(allocator: Allocator, op: *const Value, args: *const list.List, env: *Env, depth: usize) anyerror!Value {
    _ = env;
    const fn_data = op.fn_val orelse return error.TypeError;
    const arity = try matchArity(fn_data, args.items.len);

    // Heap-allocate Env to reduce C stack pressure during deep recursion.
    // Env is ~416 bytes; keeping it on the stack in debug mode causes overflow.
    const new_env = try allocator.create(Env);
    errdefer allocator.destroy(new_env);
    new_env.* = try cloneFnEnv(allocator, fn_data.env);
    defer new_env.deinit(allocator);
    defer pushEnvTempRoot(new_env).deinit();
    defer allocator.destroy(new_env);

    // Bind function name for self-reference (e.g., (fn self [x] (self (dec x))))
    if (fn_data.name) |fn_name| {
        const fn_clone = try op.clone(allocator);
        try new_env.put(fn_name, fn_clone);
    }

    // Bind parameters (regular + rest) to arguments
    try bindArityParams(allocator, arity, args, new_env);

    // Check for protocol dispatch marker
    if (arity.body.items.len >= 1 and
        std.meta.activeTag(arity.body.items[0]) == .symbol and
        std.mem.eql(u8, arity.body.items[0].sym_val, "__protocol_dispatch__"))
    {
        return try protocols.dispatchProtocolMethod(allocator, args.*, new_env, depth);
    }

    // Evaluate the function body — take ownership from evalRec's *Value
    const body_val = vm.listValue(arity.body);
    const result_ptr = try evalRec(allocator, &body_val, new_env, depth);
    const result = result_ptr.*;
    allocator.destroy(result_ptr);
    return result;
}

/// Find the matching arity for a given argument count.
fn matchArity(fn_data: *const vm.FnData, arg_count: usize) anyerror!*const vm.Arity {
    var i: usize = 0;
    while (i < fn_data.arities.items.len) : (i += 1) {
        const arity = &fn_data.arities.items[i];
        const min_args = arity.params.items.len;
        const has_rest = arity.rest_name != null;
        if (has_rest) {
            if (arg_count >= min_args) return arity;
        } else {
            if (arg_count == min_args) return arity;
        }
    }
    return error.ArityError;
}

/// Clone a function's closure env, skipping the clone if the env has no local entries.
fn cloneFnEnv(allocator: Allocator, src: *const Env) anyerror!Env {
    if (!src.entries.isEmpty()) {
        return try src.clone(allocator);
    }
    return .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = src.parent,
        .ns_manager = null,
    };
}

/// Bind arity parameters (regular + rest) to arguments in the call env.
fn bindArityParams(allocator: Allocator, arity: *const vm.Arity, args: *const list.List, new_env: *Env) anyerror!void {
    const min_args = arity.params.items.len;
    const has_rest = arity.rest_name != null;

    // Bind regular parameters to arguments (with destructuring support)
    var j: usize = 0;
    while (j < arity.params.items.len) : (j += 1) {
        const param = arity.params.items[j];
        try bindParam(allocator, param, args.items[j], new_env);
    }

    // Bind rest parameter to remaining args as a list
    if (has_rest) {
        if (args.items.len > min_args) {
            var rest_list: list.List = .empty;
            errdefer rest_list.deinit(allocator);
            var k: usize = min_args;
            while (k < args.items.len) : (k += 1) {
                try rest_list.append(allocator, try args.items[k].clone(allocator));
            }
            try new_env.put(arity.rest_name.?, vm.listValue(rest_list));
        } else {
            // No extra args: bind empty list to rest parameter
            try new_env.put(arity.rest_name.?, vm.listValue(.empty));
        }
    }
}

/// Call a built-in function registered with the VM.
fn callBuiltinFn(_: Allocator, op: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    // Use cast to avoid copying the large Value struct onto the stack
    const op_mut = @constCast(op);
    return op_mut.builtin_fn_val(op_mut, args, env);
}

/// Call a set as a function: returns the element if found, nil otherwise.
fn callSet(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    for (op.set_val.items) |item| {
        if (item.equals(args.items[0])) {
            return try item.clone(allocator);
        }
    }
    return vm.nilValue();
}

/// Call a keyword as a function: looks up the keyword in a map or record.
fn callKeyword(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    if (std.meta.activeTag(coll) == .map) {
        for (coll.map_val.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.kw_val, op.kw_val)) {
                return try entry.value.clone(allocator);
            }
        }
    } else if (std.meta.activeTag(coll) == .record) {
        for (coll.record_val.?.fields.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.kw_val, op.kw_val)) {
                return try entry.value.clone(allocator);
            }
        }
        for (coll.record_val.?.extmap.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.kw_val, op.kw_val)) {
                return try entry.value.clone(allocator);
            }
        }
    }
    return vm.nilValue();
}

/// Call a map as a function: returns value for key, or not-found if provided.
fn callMap(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
    const key = args.items[0];
    for (op.map_val.items) |entry| {
        if (entry.key.equals(key)) {
            return try entry.value.clone(allocator);
        }
    }
    if (args.items.len == 2) {
        return try args.items[1].clone(allocator);
    }
    return vm.nilValue();
}

/// Call a record as a function: returns value for key (fields first, then extmap).
fn callRecord(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
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
    if (args.items.len == 2) {
        return try args.items[1].clone(allocator);
    }
    return vm.nilValue();
}

/// Call a lazy-seq as a function: forces its evaluation (no args allowed).
fn callLazySeq(allocator: Allocator, op: *const Value, env: *Env, depth: usize) anyerror!Value {
    const result_ptr = try forceLazySeq(allocator, op.*, env, depth);
    const result = result_ptr.*;
    allocator.destroy(result_ptr);
    return result;
}

// Flatten a cons chain into a list for doall/dorun.
// Recursively forces any nested lazy_seqs.
fn flattenConsForDoall(allocator: Allocator, val: Value, env: *Env, depth: usize, target: *list.List) anyerror!void {
    var current = val;
    errdefer current.deinit(allocator);

    while (true) {
        switch (std.meta.activeTag(current)) {
            .cons => {
                // Force the head if it's a lazy_seq
                const cdata = current.cons_val.?;
                const head = cdata.head;
                if (std.meta.activeTag(head) == .lazy_seq) {
                    const head_forced_ptr = try forceLazySeq(allocator, try head.clone(allocator), env, depth + 1);
                    if (std.meta.activeTag(head_forced_ptr) == .list) {
                        for (head_forced_ptr.list_val.items) |fi| {
                            try target.append(allocator, try fi.clone(allocator));
                        }
                    } else {
                        try target.append(allocator, head_forced_ptr.*);
                    }
                    head_forced_ptr.*.deinit(allocator);
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
                    if (std.meta.activeTag(item) == .lazy_seq) {
                        const forced_ptr = try forceLazySeq(allocator, item, env, depth + 1);
                        if (std.meta.activeTag(forced_ptr) == .list) {
                            for (forced_ptr.list_val.items) |fi| {
                                try target.append(allocator, try fi.clone(allocator));
                            }
                        }
                        forced_ptr.*.deinit(allocator);
                    } else {
                        try target.append(allocator, try item.clone(allocator));
                    }
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                // Force the lazy_seq and flatten
                const forced_ptr = try forceLazySeq(allocator, current, env, depth + 1);
                if (std.meta.activeTag(forced_ptr) == .list) {
                    for (forced_ptr.list_val.items) |fi| {
                        try target.append(allocator, try fi.clone(allocator));
                    }
                }
                forced_ptr.*.deinit(allocator);
                break;
            },
            else => {
                try target.append(allocator, current);
                current = vm.nilValue();
                break;
            },
        }
    }
    current.deinit(allocator);
}

// Force evaluation of a lazy sequence, returning the resulting list
fn forceLazySeq(allocator: Allocator, lazy: Value, env: *Env, depth: usize) anyerror!*Value {
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
        const body_val = vm.listValue(cloned_body);
        const result_ptr = try evalRec(allocator, &body_val, &thunk_env, depth);

        // The result should be a list/vector (the sequence)
        // Convert to list if needed
        var final_list: list.List = .empty;
        errdefer final_list.deinit(allocator);

        switch (std.meta.activeTag(result_ptr)) {
            .list => {
                // Handle cons cell pattern: [head, lazy_seq_tail]
                if (result_ptr.list_val.items.len == 2 and std.meta.activeTag(result_ptr.list_val.items[1]) == .lazy_seq) {
                    const head_item = result_ptr.list_val.items[0];
                    if (std.meta.activeTag(head_item) == .lazy_seq) {
                        const head_forced_ptr = try forceLazySeq(allocator, head_item, env, depth + 1);
                        try final_list.append(allocator, head_forced_ptr.*);
                        head_forced_ptr.*.deinit(allocator);
                    } else {
                        try final_list.append(allocator, try head_item.clone(allocator));
                    }
                    const tail_forced_ptr = try forceLazySeq(allocator, result_ptr.list_val.items[1], env, depth + 1);
                    if (std.meta.activeTag(tail_forced_ptr) == .list) {
                        for (tail_forced_ptr.list_val.items) |fi| {
                            try final_list.append(allocator, try fi.clone(allocator));
                        }
                    }
                    tail_forced_ptr.*.deinit(allocator);
                } else {
                    for (result_ptr.list_val.items) |item| {
                        // Recursively force nested lazy_seqs for doall/dorun
                        if (std.meta.activeTag(item) == .lazy_seq) {
                            const forced_ptr = try forceLazySeq(allocator, item, env, depth + 1);
                            if (std.meta.activeTag(forced_ptr) == .list) {
                                for (forced_ptr.list_val.items) |fi| {
                                    try final_list.append(allocator, try fi.clone(allocator));
                                }
                            }
                            forced_ptr.*.deinit(allocator);
                        } else {
                            try final_list.append(allocator, try item.clone(allocator));
                        }
                    }
                }
            },
            .vector => {
                for (result_ptr.vec_val.items) |item| {
                    if (std.meta.activeTag(item) == .lazy_seq) {
                        const forced_ptr = try forceLazySeq(allocator, item, env, depth + 1);
                        if (std.meta.activeTag(forced_ptr) == .list) {
                            for (forced_ptr.list_val.items) |fi| {
                                try final_list.append(allocator, try fi.clone(allocator));
                            }
                        }
                        forced_ptr.*.deinit(allocator);
                    } else {
                        try final_list.append(allocator, try item.clone(allocator));
                    }
                }
            },
            .nil => {}, // empty sequence
            .lazy_seq => {
                // Recursively force for doall/dorun
                const forced_ptr = try forceLazySeq(allocator, result_ptr.*, env, depth + 1);
                if (std.meta.activeTag(forced_ptr) == .list) {
                    for (forced_ptr.list_val.items) |fi| {
                        try final_list.append(allocator, try fi.clone(allocator));
                    }
                }
                forced_ptr.*.deinit(allocator);
            },
            .cons => {
                // Walk the cons chain and flatten into the list
                try flattenConsForDoall(allocator, result_ptr.*, env, depth + 1, &final_list);
            },
            else => {
                try final_list.append(allocator, result_ptr.*);
            },
        }

        result_ptr.*.deinit(allocator);
        return try allocValue(allocator, vm.listValue(final_list));
    }

    return try allocValue(allocator, vm.listValue(list.empty()));
}

// Bind a parameter to an argument, supporting destructuring
// e.g., param=[a b], arg=[1 2] => binds a=1, b=2
fn bindParam(allocator: Allocator, param: Value, arg: Value, env: *Env) anyerror!void {
    switch (std.meta.activeTag(param)) {
        .symbol => {
            try env.put(param.sym_val, try arg.clone(allocator));
        },
        .vector => {
            // Destructure: param is [x y z], arg should be a collection
            var arg_items: []const Value = undefined;
            switch (std.meta.activeTag(arg)) {
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
    const items = switch (std.meta.activeTag(form)) {
        .vector => form.vec_val.items,
        .list => form.list_val.items,
        else => return false,
    };
    if (items.len == 0) return false;
    var found_amp = false;
    for (items) |item| {
        if (std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.sym_val, "&")) {
            if (found_amp) return false; // duplicate &
            found_amp = true;
            continue;
        }
        if (!found_amp and std.meta.activeTag(item) != .symbol) return false;
        if (found_amp and std.meta.activeTag(item) != .symbol) return false;
    }
    return true;
}

// case - multi-way constant dispatch
// (case expr test1 result1 test2 result2 ... :else default)
fn evalCase(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!*Value {
    if (forms.len < 1) return error.ArityError;

    const expr_val_ptr = try evalRec(allocator, &forms[0], env, depth);
    defer expr_val_ptr.*.deinit(allocator);

    var i: usize = 1;
    while (i < forms.len) : (i += 2) {
        const test_form = forms[i];
        if (std.meta.activeTag(test_form) == .keyword and std.mem.eql(u8, test_form.kw_val, "else")) {
            if (i + 1 >= forms.len) return error.ArityError;
            return try evalRec(allocator, &forms[i + 1], env, depth);
        }

        const test_val_ptr = try evalRec(allocator, &test_form, env, depth);
        defer test_val_ptr.*.deinit(allocator);

        if (expr_val_ptr.equals(test_val_ptr.*)) {
            if (i + 1 >= forms.len) return error.ArityError;
            return try evalRec(allocator, &forms[i + 1], env, depth);
        }
    }

    return try allocValue(allocator, vm.nilValue());
}

// ============================================================================
// Extracted special form evaluators
// These were inline in evalList. Extracting them reduces evalList's stack
// frame from ~48 KB to a thin dispatcher. Each handler has its own smaller
// frame allocated only when that specific form is evaluated.
// ============================================================================

/// (quote form) — return form unevaluated
fn evalQuote(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    _ = env;
    _ = depth;
    if (l.items.len != 2) return error.ArityError;
    return try l.items[1].cloneGC(allocator);
}

/// (quit) / (exit) — signal REPL to exit
fn evalQuit(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    _ = allocator;
    _ = l;
    _ = env;
    _ = depth;
    return error.ReplExit;
}

/// (quasiquote form) — template with unquote
fn evalQuasiquote(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len != 2) return error.ArityError;
    const result = try eval_macro.unquoteProcess(allocator, l.items[1], env, depth + 1);
    return try allocValue(allocator, result);
}

/// (def name value?) — define in current namespace
fn evalDef(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const eval_idx: usize = if (l.items.len >= 3) 2 else 1;
    const val_ptr = try evalRec(allocator, &l.items[eval_idx], env, depth + 1);
    const persistent_val = try val_ptr.*.clone(allocator);
    try bindInCurrentNamespace(env, sym.sym_val, persistent_val);
    return try sym.cloneGC(allocator);
}

/// (if test then else?) — conditional
fn evalIf(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2 or l.items.len > 4) return error.ArityError;
    const cond_ptr = try evalRec(allocator, &l.items[1], env, depth + 1);
    const truthy = cond_ptr.isTruthy();
    cond_ptr.*.deinit(allocator);
    if (truthy) {
        if (l.items.len >= 3) return try evalRec(allocator, &l.items[2], env, depth + 1);
        return try allocValue(allocator, vm.nilValue());
    } else {
        if (l.items.len >= 4) return try evalRec(allocator, &l.items[3], env, depth + 1);
        return try allocValue(allocator, vm.nilValue());
    }
}

/// (when test body...) — if with implicit do
fn evalWhen(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2) return error.ArityError;
    const cond_ptr = try evalRec(allocator, &l.items[1], env, depth + 1);
    const truthy = cond_ptr.isTruthy();
    cond_ptr.*.deinit(allocator);
    if (truthy) {
        var do_result: Value = vm.nilValue();
        errdefer do_result.deinit(allocator);
        for (l.items[2..]) |form| {
            const result_ptr = try evalRec(allocator, &form, env, depth + 1);
            do_result.deinit(allocator);
            do_result = result_ptr.*;
        }
        return try allocValue(allocator, do_result);
    }
    return try allocValue(allocator, vm.nilValue());
}

/// (do body...) — evaluate a sequence of forms
fn evalDo(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    var last_ptr: ?*Value = null;
    errdefer {
        if (last_ptr) |p| {
            p.*.deinit(allocator);
            allocator.destroy(p);
        }
    }
    for (l.items[1..]) |form| {
        if (last_ptr) |p| {
            p.*.deinit(allocator);
            allocator.destroy(p);
        }
        last_ptr = try evalRec(allocator, &form, env, depth + 1);
    }
    if (last_ptr) |p| {
        const result = p.*;
        allocator.destroy(p);
        return try allocValue(allocator, result);
    }
    return try allocValue(allocator, vm.nilValue());
}

/// (defn name docstring? ([params] body...)+) — define named function
fn evalDefn(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    _ = depth;
    if (l.items.len < 3) return error.ArityError;
    const fname = l.items[1];
    if (std.meta.activeTag(fname) != .symbol) return error.TypeError;
    var idx: usize = 2;
    if (idx < l.items.len and std.meta.activeTag(l.items[idx]) == .string) {
        idx += 1;
    }
    if (idx >= l.items.len) return error.ArityError;

    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
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
    var fn_val = try vm.fnValue(allocator, arities, fn_env, false);
    const persistent_fn = try fn_val.clone(allocator);
    fn_val.deinit(allocator);
    try bindInCurrentNamespace(env, fname.sym_val, persistent_fn);
    return try fname.cloneGC(allocator);
}

/// (fn name? ([params] body...)+) — anonymous function
fn evalFn(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    _ = depth;
    if (l.items.len < 2) return error.ArityError;
    var idx: usize = 1;
    var fn_name: ?Value = null;
    if (std.meta.activeTag(l.items[idx]) == .symbol) {
        fn_name = l.items[idx];
        idx += 1;
    }
    if (idx >= l.items.len) return error.ArityError;

    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }

    arities = try parseArityForms(allocator, l.items, l.items.len, &idx);

    const fn_env = try env.clone(allocator);

    var fn_name_str: ?[]const u8 = null;
    if (fn_name) |name_sym| {
        fn_name_str = try allocator.dupe(u8, name_sym.sym_val);
    }

    const fn_val = try vm.fnValueNamed(allocator, arities, fn_env, false, fn_name_str);
    return try allocValue(allocator, fn_val);
}

/// (defmacro name docstring? ([params] body...)+) — define a macro
fn evalDefmacro(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    _ = depth;
    if (l.items.len < 3) return error.ArityError;
    const macro_name = l.items[1];
    if (std.meta.activeTag(macro_name) != .symbol) return error.TypeError;
    var idx: usize = 2;
    if (idx < l.items.len and std.meta.activeTag(l.items[idx]) == .string) {
        idx += 1;
    }
    if (idx >= l.items.len) return error.ArityError;

    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
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
    var macro_fn = try vm.fnValue(allocator, arities, fn_env, true);
    const persistent_macro = try macro_fn.clone(allocator);
    macro_fn.deinit(allocator);
    try bindInCurrentNamespace(env, macro_name.sym_val, persistent_macro);
    return try macro_name.cloneGC(allocator);
}

/// (set! name value) — modify a variable
fn evalSetBang(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len != 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const val_ptr = try evalRec(allocator, &l.items[2], env, depth + 1);
    const persistent_val = try val_ptr.*.clone(allocator);
    try env.put(sym.sym_val, persistent_val);
    return val_ptr;
}

/// (recur new-arg*) — tail recursion signal
fn evalRecur(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2) return error.ArityError;
    var results: list.List = .empty;
    errdefer results.deinit(allocator);
    try results.append(allocator, try vm.symValue(allocator, "__recur__"));
    for (l.items[1..]) |arg| {
        const ptr = try evalRec(allocator, &arg, env, depth + 1);
        try results.append(allocator, ptr.*);
    }
    return try allocValue(allocator, vm.listValue(results));
}

/// (var name value?) — create a mutable var
fn evalVar(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const val_ptr = if (l.items.len >= 3)
        try evalRec(allocator, &l.items[2], env, depth + 1)
    else
        try allocValue(allocator, vm.nilValue());
    const persistent_val = try val_ptr.*.clone(allocator);
    try env.put(sym.sym_val, persistent_val);
    return try sym.cloneGC(allocator);
}

/// (deref form) / (@ form) — get value from atom/var/reduced
fn evalDeref(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len != 2) return error.ArityError;
    const arg_ptr = try evalRec(allocator, &l.items[1], env, depth + 1);
    if (std.meta.activeTag(arg_ptr) == .atom) {
        if (arg_ptr.atom_val) |data| {
            const val = try data.value.clone(allocator);
            arg_ptr.*.deinit(allocator);
            return try allocValue(allocator, val);
        }
        arg_ptr.*.deinit(allocator);
        return try allocValue(allocator, vm.nilValue());
    }
    if (std.meta.activeTag(arg_ptr) == .reduced) {
        if (arg_ptr.reduced_val) |data| {
            const val = try data.clone(allocator);
            arg_ptr.*.deinit(allocator);
            return try allocValue(allocator, val);
        }
        arg_ptr.*.deinit(allocator);
        return try allocValue(allocator, vm.nilValue());
    }
    return arg_ptr;
}

/// (or form*) — short-circuit or
fn evalOr(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    var last_ptr: ?*Value = null;
    errdefer {
        if (last_ptr) |p| {
            p.*.deinit(allocator);
            allocator.destroy(p);
        }
    }
    for (l.items[1..]) |form_item| {
        const val_ptr = try evalRec(allocator, &form_item, env, depth + 1);
        if (val_ptr.isTruthy()) {
            if (last_ptr) |p| {
                p.*.deinit(allocator);
                allocator.destroy(p);
            }
            return val_ptr;
        }
        if (last_ptr) |p| {
            p.*.deinit(allocator);
            allocator.destroy(p);
        }
        last_ptr = val_ptr;
    }
    if (last_ptr) |p| {
        const result = p.*;
        allocator.destroy(p);
        return try allocValue(allocator, result);
    }
    return try allocValue(allocator, vm.nilValue());
}

/// (and form*) — short-circuit and
fn evalAnd(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    for (l.items[1..]) |form_item| {
        const val_ptr = try evalRec(allocator, &form_item, env, depth + 1);
        if (!val_ptr.isTruthy()) return val_ptr;
        val_ptr.*.deinit(allocator);
    }
    return try allocValue(allocator, vm.boolValue(true));
}

/// (binding [var1 val1 ...] body...) — dynamic variable binding
fn evalBinding(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 3) return error.ArityError;
    const bindings = l.items[1];
    if (std.meta.activeTag(bindings) != .vector) return error.TypeError;
    var new_env = try env.clone(allocator);
    defer new_env.deinit(allocator);
    defer pushEnvTempRoot(&new_env).deinit();

    var i: usize = 0;
    while (i < bindings.vec_val.items.len) : (i += 2) {
        const sym = bindings.vec_val.items[i];
        if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
        const val_ptr = try evalRec(allocator, &bindings.vec_val.items[i + 1], env, depth + 1);
        try new_env.put(sym.sym_val, val_ptr.*);
    }
    var do_result: Value = vm.nilValue();
    errdefer do_result.deinit(allocator);
    for (l.items[2..]) |form| {
        const result_ptr = try evalRec(allocator, &form, &new_env, depth + 1);
        do_result.deinit(allocator);
        do_result = result_ptr.*;
    }
    return try allocValue(allocator, do_result);
}

/// (lazy-seq body...) — create a lazy sequence
fn evalLazySeq(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    _ = depth;
    if (l.items.len < 2) return error.ArityError;
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "do"));
    for (l.items[1..]) |form| {
        try body.append(allocator, try form.clone(allocator));
    }
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = body,
        .env = try env.clone(allocator),
    };
    return try allocValue(allocator, vm.lazySeqValue(thunk));
}

/// (dorun n? coll) — realize sequence for side effects, return nil
fn evalDorun(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const dorun_args = l.items[1..];
    var n: ?usize = null;
    var coll_form: Value = undefined;
    if (dorun_args.len == 2) {
        const n_val_ptr = try evalRec(allocator, &dorun_args[0], env, depth + 1);
        defer n_val_ptr.*.deinit(allocator);
        const n_int: i64 = switch (std.meta.activeTag(n_val_ptr)) {
            .integer => n_val_ptr.int_val,
            .float => @as(i64, @intFromFloat(n_val_ptr.float_val)),
            else => return error.TypeError,
        };
        n = @as(usize, @intCast(n_int));
        coll_form = dorun_args[1];
    } else {
        coll_form = dorun_args[0];
    }
    const coll_ptr = try evalRec(allocator, &coll_form, env, depth + 1);
    defer coll_ptr.*.deinit(allocator);

    var coll = coll_ptr.*;
    if (std.meta.activeTag(coll) == .lazy_seq) {
        const forced = try sequences.forceLazySeqHelper(allocator, coll);
        coll.deinit(allocator);
        coll = forced;
    }
    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        .set => items = coll.set_val.items,
        .queue => items = coll.queue_val.items,
        else => return try allocValue(allocator, vm.nilValue()),
    }
    var count: usize = 0;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        if (n) |limit| {
            if (count >= limit) break;
        }
        const item = items[i];
        if (std.meta.activeTag(item) == .lazy_seq) {
            _ = try sequences.forceLazySeqHelper(allocator, item);
        }
        count += 1;
    }
    return try allocValue(allocator, vm.nilValue());
}

/// (doall coll) — realize lazy sequences and return result
fn evalDoall(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len != 2) return error.ArityError;
    const coll_ptr = try evalRec(allocator, &l.items[1], env, depth + 1);
    if (std.meta.activeTag(coll_ptr) == .lazy_seq) {
        const forced = try sequences.forceLazySeqHelper(allocator, coll_ptr.*);
        coll_ptr.*.deinit(allocator);
        return try forced.cloneGC(allocator);
    }
    if (std.meta.activeTag(coll_ptr) == .nil) {
        coll_ptr.*.deinit(allocator);
        return try allocValue(allocator, vm.listValue(list.empty()));
    }
    return try coll_ptr.*.cloneGC(allocator);
}

/// (extend atype protocol mmap & more...) — add protocol implementations
fn evalExtend(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    if (l.items.len < 4) return error.ArityError;
    var ext_args: list.List = .empty;
    errdefer ext_args.deinit(allocator);
    try ext_args.append(allocator, try l.items[1].clone(allocator));
    var ei: usize = 2;
    while (ei < l.items.len) : (ei += 1) {
        const ptr = try evalRec(allocator, &l.items[ei], env, depth + 1);
        try ext_args.append(allocator, ptr.*);
    }
    const result = try protocols.evalExtend(allocator, ext_args, env, depth + 1);
    return try allocValue(allocator, result);
}

// ============================================================================
// Wrapper functions for external module handlers
// These adapt the unified SpecialFormFn signature to external module APIs.
// ============================================================================

fn evalNsForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try eval_ns.evalNs(allocator, l.*, env, depth);
    return try allocValue(allocator, result);
}

fn evalInNsForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try eval_ns.evalInNs(allocator, l.*, env, depth);
    return try allocValue(allocator, result);
}

fn evalDefprotocolForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try protocols.evalDefProtocol(allocator, l.*, env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalExtendTypeForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try protocols.evalExtendType(allocator, l.*, env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalExtendProtocolForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try protocols.evalExtendProtocol(allocator, l.*, env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalDefrecordForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try records.evalDefRecord(allocator, l.*, env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalThreadLastForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try eval_thread.evalThreadLast(allocator, l.items[1..], env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalThreadFirstForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try eval_thread.evalThreadFirst(allocator, l.items[1..], env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalCondThreadFirstForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try eval_thread.evalCondThreadFirst(allocator, l.items[1..], env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalCondThreadLastForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const result = try eval_thread.evalCondThreadLast(allocator, l.items[1..], env, depth + 1);
    return try allocValue(allocator, result);
}

fn evalCaseForm(allocator: Allocator, l: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    return try evalCase(allocator, l.items[1..], env, depth + 1);
}
