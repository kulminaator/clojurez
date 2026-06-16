// Core built-in functions coordinator
// Imports from domain modules and provides higher-order functions (apply, partial, comp, fnil, juxt, etc.)
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = Value.Env;
const eval_ns = @import("../../eval_ns.zig");

// Domain modules
const arithmetic = @import("arithmetic.zig");
const comparison = @import("comparison.zig");
const type_predicates = @import("type_predicates.zig");
const strings = @import("strings.zig");
const sequences = @import("sequences.zig");
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

const Allocator = std.mem.Allocator;

// ---- Collection predicates (empty?, not-empty, seq) ----

pub fn core_empty_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (coll.type) {
        .list => coll.list_val.items.len,
        .vector => coll.vec_val.items.len,
        .map => coll.map_val.items.len,
        .set => coll.set_val.items.len,
        .queue => coll.queue_val.items.len,
        .string => coll.str_val.len,
        else => return error.TypeError,
    };
    return Value.boolValue(len == 0);
}

pub fn core_not_empty(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (coll.type) {
        .list => coll.list_val.items.len,
        .vector => coll.vec_val.items.len,
        .map => coll.map_val.items.len,
        .set => coll.set_val.items.len,
        .queue => coll.queue_val.items.len,
        else => return Value.nilValue(),
    };
    if (len == 0) return Value.nilValue();
    return try coll.clone(env_env.allocator);
}

// ---- Higher-order functions ----

// apply - apply function to a collection of arguments
pub fn core_apply(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];

    var call_args: list.List = .empty;
    errdefer call_args.deinit(env_env.allocator);

    var i: usize = 1;
    while (i < args.items.len - 1) : (i += 1) {
        try call_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }

    const coll = args.items[args.items.len - 1];
    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }
    for (items) |item| {
        try call_args.append(env_env.allocator, try item.clone(env_env.allocator));
    }

    return try eval_helpers.callBuiltin(env_env.allocator, f, call_args, env_env);
}

// trampoline - calls f, if result is a fn calls it, repeats until non-fn result
pub fn core_trampoline(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len < 1) return error.ArityError;

    // Clone to main allocator — args may be on arena
    var current = try args.items[0].clone(allocator);
    if (args.items.len > 1) {
        var call_args: list.List = .empty;
        errdefer call_args.deinit(allocator);
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            try call_args.append(allocator, try args.items[i].clone(allocator));
        }
        current = try eval_helpers.callBuiltin(allocator, current, call_args, env_env);
    }

    var max_iterations: usize = 10000;
    while (max_iterations > 0) : (max_iterations -= 1) {
        if (current.type != .function and current.type != .builtin_fn) {
            return current;
        }
        const empty_args: list.List = .empty;
        const result = try eval_helpers.callBuiltin(allocator, current, empty_args, env_env);
        current.deinit(allocator);
        current = result;
    }
    current.deinit(allocator);
    return error.StackOverflow;
}

// if-not - if test is false, evaluate then, else evaluate else (if provided)
pub fn core_if_not(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    const cond = args.items[0];
    if (!cond.isTruthy()) {
        return try args.items[1].clone(env_env.allocator);
    }
    if (args.items.len == 3) {
        return try args.items[2].clone(env_env.allocator);
    }
    return Value.nilValue();
}

// partial - return a function that is a partial application of f
pub fn core_partial(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    try fn_env.put("__partial_fn", try f.clone(env_env.allocator));
    var partial_args: list.List = .empty;
    errdefer partial_args.deinit(env_env.allocator);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        try partial_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }
    try fn_env.put("__partial_args", Value.listValue(partial_args));

    var params_list: list.List = .empty;
    errdefer params_list.deinit(env_env.allocator);
    try params_list.append(env_env.allocator, try Value.symValue(env_env.allocator, "args"));

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "apply"));
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "__partial_fn"));
    var concat_call: list.List = .empty;
    errdefer concat_call.deinit(env_env.allocator);
    try concat_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "concat"));
    try concat_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "__partial_args"));
    try concat_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "args"));
    try body.append(env_env.allocator, Value.listValue(concat_call));

    const cloned_params = try params_list.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    var final_env = try env_env.clone(env_env.allocator);
    try final_env.put("__partial_fn", try f.clone(env_env.allocator));
    var stored_args: list.List = .empty;
    errdefer stored_args.deinit(env_env.allocator);
    i = 1;
    while (i < args.items.len) : (i += 1) {
        try stored_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }
    try final_env.put("__partial_args", Value.listValue(stored_args));

    return try Value.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// comp - compose functions (right to left)
pub fn core_comp(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;

    if (args.items.len == 1) return try args.items[0].clone(env_env.allocator);

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__comp_fn_{d}", .{i});
        try fn_env.put(key, try args.items[i].clone(env_env.allocator));
    }

    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    try params.append(env_env.allocator, try Value.symValue(env_env.allocator, "x"));

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "do"));

    var current: Value = try Value.symValue(env_env.allocator, "x");
    var j: usize = args.items.len;
    while (j > 0) {
        j -= 1;
        const key = try std.fmt.allocPrint(env_env.allocator, "__comp_fn_{d}", .{j});
        var call: list.List = .empty;
        errdefer call.deinit(env_env.allocator);
        try call.append(env_env.allocator, try Value.symValue(env_env.allocator, key));
        try call.append(env_env.allocator, current);
        current = Value.listValue(call);
    }

    try body.append(env_env.allocator, current);

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return try Value.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// fnil - provide default values for nil arguments
pub fn core_fnil(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];
    const defaults_count = args.items.len - 1;

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    try fn_env.put("__fnil_fn", try f.clone(env_env.allocator));

    var d: usize = 0;
    while (d < defaults_count) : (d += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__fnil_default_{d}", .{d});
        try fn_env.put(key, try args.items[d + 1].clone(env_env.allocator));
    }

    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    d = 0;
    while (d < defaults_count) : (d += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "a{d}", .{d});
        try params.append(env_env.allocator, try Value.symValue(env_env.allocator, key));
    }

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "apply"));
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "__fnil_fn"));

    var list_call: list.List = .empty;
    errdefer list_call.deinit(env_env.allocator);
    try list_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "list"));
    d = 0;
    while (d < defaults_count) : (d += 1) {
        const param_key = try std.fmt.allocPrint(env_env.allocator, "a{d}", .{d});
        const default_key = try std.fmt.allocPrint(env_env.allocator, "__fnil_default_{d}", .{d});

        var if_call: list.List = .empty;
        errdefer if_call.deinit(env_env.allocator);
        try if_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "if"));

        var nil_q_call: list.List = .empty;
        errdefer nil_q_call.deinit(env_env.allocator);
        try nil_q_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "nil?"));
        try nil_q_call.append(env_env.allocator, try Value.symValue(env_env.allocator, param_key));
        try if_call.append(env_env.allocator, Value.listValue(nil_q_call));
        try if_call.append(env_env.allocator, try Value.symValue(env_env.allocator, default_key));
        try if_call.append(env_env.allocator, try Value.symValue(env_env.allocator, param_key));

        try list_call.append(env_env.allocator, Value.listValue(if_call));
    }
    try body.append(env_env.allocator, Value.listValue(list_call));

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return try Value.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// juxt - juxtaposition of functions
pub fn core_juxt(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__juxt_fn_{d}", .{i});
        try fn_env.put(key, try args.items[i].clone(env_env.allocator));
    }

    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    try params.append(env_env.allocator, try Value.symValue(env_env.allocator, "x"));

    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "do"));

    var vec_call: list.List = .empty;
    errdefer vec_call.deinit(env_env.allocator);
    try vec_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "vec"));
    i = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__juxt_fn_{d}", .{i});
        var call: list.List = .empty;
        errdefer call.deinit(env_env.allocator);
        try call.append(env_env.allocator, try Value.symValue(env_env.allocator, key));
        try call.append(env_env.allocator, try Value.symValue(env_env.allocator, "x"));
        try vec_call.append(env_env.allocator, Value.listValue(call));
    }
    try body.append(env_env.allocator, Value.listValue(vec_call));

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return try Value.fnValueSingle(env_env.allocator, cloned_params, cloned_body, final_env, null, false);
}

// ---- Namespace introspection functions ----

/// Build a namespace map {:name sym, :interns map, :refers map, :aliases map}
fn buildNsMap(allocator: Allocator, ns_name: []const u8, ns_env: *Env, ns_mgr: *Value.NamespaceManager) anyerror!Value {
    var result_map: Value.Map = .empty;
    errdefer {
        for (result_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(result_map.items);
    }

    // :name → symbol
    try result_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "name"),
        .value = try Value.symValue(allocator, ns_name),
    });

    // :interns → map of owned symbols (not referred)
    var interns_map: Value.Map = .empty;
    errdefer {
        for (interns_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(interns_map.items);
    }
    var it = ns_env.entries.entryIterator();
    while (it.next()) |entry| {
        const sym_name = if (entry.key.type == .symbol) entry.key.sym_val else continue;
        // Skip referred names — interns are only owned vars
        if (eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        try interns_map.append(allocator, .{
            .key = try Value.symValue(allocator, sym_name),
            .value = try entry.val.clone(allocator),
        });
    }
    try result_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "interns"),
        .value = Value.mapValue(interns_map),
    });

    // :refers → map of referred symbols
    var refers_map: Value.Map = .empty;
    errdefer {
        for (refers_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(refers_map.items);
    }
    var it2 = ns_env.entries.entryIterator();
    while (it2.next()) |entry| {
        const sym_name = if (entry.key.type == .symbol) entry.key.sym_val else continue;
        // Only include referred names
        if (!eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        try refers_map.append(allocator, .{
            .key = try Value.symValue(allocator, sym_name),
            .value = try entry.val.clone(allocator),
        });
    }
    try result_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "refers"),
        .value = Value.mapValue(refers_map),
    });

    // :aliases → map of alias symbol → target namespace symbol
    var aliases_map: Value.Map = .empty;
    errdefer {
        for (aliases_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(aliases_map.items);
    }
    var it3 = ns_mgr.aliases.entryIterator();
    while (it3.next()) |entry| {
        const composite_key = if (entry.key.type == .symbol) entry.key.sym_val else continue;
        // Parse "ns_name/alias_name" composite key
        if (std.mem.indexOfScalar(u8, composite_key, '/')) |slash_idx| {
            const key_ns_name = composite_key[0..slash_idx];
            const alias_name = composite_key[slash_idx + 1 ..];
            if (std.mem.eql(u8, key_ns_name, ns_name)) {
                // This alias belongs to our namespace
                const target_ns = if (entry.val.type == .string) entry.val.str_val else continue;
                try aliases_map.append(allocator, .{
                    .key = try Value.symValue(allocator, alias_name),
                    .value = try Value.symValue(allocator, target_ns),
                });
            }
        }
    }
    try result_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "aliases"),
        .value = Value.mapValue(aliases_map),
    });

    return Value.mapValue(result_map);
}

/// find-ns: (find-ns sym-or-ns) → namespace-object or nil
/// Returns the namespace named by the symbol, or nil if it doesn't exist.
pub fn core_find_ns(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const arg = args.items[0];
    const ns_name: []const u8 = switch (arg.type) {
        .symbol => arg.sym_val,
        // If passed a map with :name, extract the namespace name from it
        .map => blk: {
            for (arg.map_val.items) |entry| {
                if (entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, "name")) {
                    if (entry.value.type == .symbol) break :blk entry.value.sym_val;
                    break :blk ""; // won't match any ns
                }
            }
            break :blk ""; // no :name key, won't match
        },
        else => return Value.nilValue(),
    };

    if (ns_name.len == 0) return Value.nilValue();

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return Value.nilValue();
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return Value.nilValue();

    return try buildNsMap(allocator, ns_name, ns_env, ns_mgr);
}

/// create-ns: (create-ns sym) → namespace-object
/// Creates a new namespace named by sym if one doesn't exist.
/// Returns the namespace object (new or existing).
pub fn core_create_ns(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const arg = args.items[0];
    if (arg.type != .symbol) return error.TypeError;
    const ns_name = arg.sym_val;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;

    // Create or get existing namespace
    const ns_env = try ns_mgr.createNamespace(ns_name);

    // Set parent to clojure.core if not already set (matching ns form behavior)
    if (ns_env.parent == null and !std.mem.eql(u8, ns_name, "clojure.core")) {
        const clojure_core = ns_mgr.getNamespace("clojure.core");
        if (clojure_core) |core_env| {
            ns_env.parent = core_env;
        }
    }

    return try buildNsMap(allocator, ns_name, ns_env, ns_mgr);
}

/// all-ns: (all-ns) → sequence-of-namespace-objects
/// Returns a sequence of all namespace maps.
pub fn core_all_ns(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = args;
    const allocator = env_env.allocator;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return Value.listValue(list.empty());

    var result_list: list.List = .empty;
    errdefer result_list.deinit(allocator);

    var it = ns_mgr.namespaces.entryIterator();
    while (it.next()) |entry| {
        const ns_name = if (entry.key.type == .symbol) entry.key.sym_val else continue;
        const ns_env = entry.val;
        if (ns_env.type != .wrapped) continue;
        const env_ptr: *Env = Value.unwrapPtr(*Env, ns_env);
        const ns_map = try buildNsMap(allocator, ns_name, env_ptr, ns_mgr);
        try result_list.append(allocator, ns_map);
    }

    return Value.listValue(result_list);
}

/// the-ns: (the-ns x) → namespace-object or error
/// Like find-ns but returns an error if not found.
pub fn core_the_ns(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const arg = args.items[0];
    const ns_name: []const u8 = switch (arg.type) {
        .symbol => arg.sym_val,
        .map => blk: {
            for (arg.map_val.items) |entry| {
                if (entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, "name")) {
                    if (entry.value.type == .symbol) break :blk entry.value.sym_val;
                    break :blk "";
                }
            }
            break :blk "";
        },
        else => return error.TypeError,
    };

    if (ns_name.len == 0) return error.UndefinedNamespace;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.UndefinedNamespace;
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return error.UndefinedNamespace;

    return try buildNsMap(allocator, ns_name, ns_env, ns_mgr);
}

// ---- Registration ----

pub fn registerCoreFunctions(env: *Env) anyerror!void {

    // Register all domain module functions
    try arithmetic.registerArithmeticFunctions(env);
    try comparison.registerComparisonFunctions(env);
    try type_predicates.registerTypePredicateFunctions(env);
    try strings.registerStringFunctions(env);
    try sequences.registerSequenceFunctions(env);
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

    // Collection predicates (kept here)
    try env.put("empty?", Value.builtinFnValue(core_empty_q));
    try env.put("not-empty", Value.builtinFnValue(core_not_empty));

    // Higher-order functions (kept here)
    try env.put("apply", Value.builtinFnValue(core_apply));
    try env.put("trampoline", Value.builtinFnValue(core_trampoline));
    try env.put("record-ctor", Value.builtinFnValue(records.core_record_ctor));
    try env.put("if-not", Value.builtinFnValue(core_if_not));
    try env.put("partial", Value.builtinFnValue(core_partial));
    try env.put("comp", Value.builtinFnValue(core_comp));
    try env.put("fnil", Value.builtinFnValue(core_fnil));
    try env.put("juxt", Value.builtinFnValue(core_juxt));

    // Clojure-style aliases (re-registered for convenience)
    try env.put("not", Value.builtinFnValue(comparison.core_not));
    try env.put("str", Value.builtinFnValue(strings.core_str));
    try env.put("count", Value.builtinFnValue(sequences.core_count));
    try env.put("first", Value.builtinFnValue(sequences.core_first));
    try env.put("rest", Value.builtinFnValue(sequences.core_rest));
    try env.put("nth", Value.builtinFnValue(sequences.core_nth));
    try env.put("concat", Value.builtinFnValue(sequences.core_concat));
    try env.put("list", Value.builtinFnValue(sequences.core_list));
    try env.put("vec", Value.builtinFnValue(sequences.core_vec));
    try env.put("subs", Value.builtinFnValue(strings.core_subs));
    try env.put("subvec", Value.builtinFnValue(sequences.core_subvec));

    // Metaprogramming
    try env.put("macroexpand-1", Value.builtinFnValue(eval_helpers.core_macroexpand_1));
    try env.put("macroexpand", Value.builtinFnValue(eval_helpers.core_macroexpand));

    // Namespace introspection
    try env.put("find-ns", Value.builtinFnValue(core_find_ns));
    try env.put("create-ns", Value.builtinFnValue(core_create_ns));
    try env.put("all-ns", Value.builtinFnValue(core_all_ns));
    try env.put("the-ns", Value.builtinFnValue(core_the_ns));

    // defn is handled as a special form alias in the evaluator
}

