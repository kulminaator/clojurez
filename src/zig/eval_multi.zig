// eval_multi.zig — Multimethod implementation (defmulti, defmethod).
//
// Design:
// - defmulti creates a var holding a MultimethodData value
// - defmethod adds an entry to the method table
// - Calling a multimethod: dispatch → lookup → invoke
// - :default dispatch value fallback
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const Env = vm.Env;
const eval = @import("eval.zig");
const Allocator = std.mem.Allocator;

/// Look up a value in a method table (ArrayList of MapEntry).
fn findMethod(table: vm.Map, key: Value) ?Value {
    for (table.items) |entry| {
        if (vm.equals(entry.key, key)) return entry.value;
    }
    return null;
}

/// (defmulti name docstring? dispatch-fn & options) — Create a multimethod.
/// Options: :default value (default dispatch value)
pub fn evalDefmulti(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval.EvalResult {
    if (l.items.len < 3) return error.ArityError;

    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const sym_name = sym.symbol;

    // Determine if there's a docstring (string as second arg after name)
    // Signature: (defmulti name docstring? dispatch-fn & options)
    var dispatch_idx: usize = 2;
    if (std.meta.activeTag(l.items[2]) == .string) {
        dispatch_idx = 3;
    }
    if (dispatch_idx >= l.items.len) return error.ArityError;

    // Evaluate dispatch function
    const dispatch_fn_ptr = try eval.evalRecV(allocator, &l.items[dispatch_idx], frame, depth + 1);
    defer vm.valueDeinit(dispatch_fn_ptr, allocator);

    // If dispatch function is a keyword, wrap it in a function that looks it up in a map.
    // In Clojure, keywords are callable: (:key {:key :val}) => :val
    var dispatch_fn: Value = undefined;
    if (std.meta.activeTag(dispatch_fn_ptr.*) == .keyword) {
        const kw_name = dispatch_fn_ptr.*.keyword;
        // Create a function: (fn [m] (get m keyword))
        const kw_val = try vm.keywordValue(allocator, kw_name);
        var fn_body: list.List = .empty;
        errdefer fn_body.deinit(allocator);
        try fn_body.append(allocator, try vm.symValue(allocator, "get"));
        try fn_body.append(allocator, try vm.symValue(allocator, "m"));
        try fn_body.append(allocator, kw_val);
        var fn_params: list.List = .empty;
        errdefer fn_params.deinit(allocator);
        try fn_params.append(allocator, try vm.symValue(allocator, "m"));
        dispatch_fn = try vm.fnValueSingle(allocator, fn_params, fn_body, try frame.root_env.clone(allocator), null, false);
    } else {
        dispatch_fn = try vm.clone(dispatch_fn_ptr, allocator);
    }

    // Create multimethod value
    var mm_val = try vm.multimethodValue(allocator, dispatch_fn);

    // Parse optional options (after dispatch function)
    var i: usize = dispatch_idx + 1;
    while (i < l.items.len) : (i += 1) {
        const opt_key = l.items[i];
        if (std.meta.activeTag(opt_key) != .keyword) continue;
        if (std.mem.eql(u8, opt_key.keyword, "default") and i + 1 < l.items.len) {
            const default_val_ptr = try eval.evalRecV(allocator, &l.items[i + 1], frame, depth + 1);
            mm_val.multimethod.default_dispatch = try vm.clone(&default_val_ptr.*, allocator);
            vm.valueDeinit(default_val_ptr, allocator);
            i += 1;
        }
    }

    // Bind in current namespace
    try eval.bindInCurrentNamespace(frame.root_env, sym_name, mm_val);

    // Phase 1: cloneGC returns *Value, extract the Value
    const ptr = try vm.cloneGC(&sym, allocator);
    return .{ .value = ptr.* };
}

/// (defmethod mm dispatch-val [params] body) — Add a method to a multimethod.
pub fn evalDefmethod(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval.EvalResult {
    if (l.items.len < 4) return error.ArityError;

    const mm_sym = l.items[1];
    if (std.meta.activeTag(mm_sym) != .symbol) return error.TypeError;

    // Look up the multimethod (evaluate the symbol)
    const mm_sym_ptr = try eval.allocValue(allocator, mm_sym);
    const mm_val_ptr = try eval.evalRecV(allocator, mm_sym_ptr, frame, depth + 1);
    defer vm.valueDeinit(mm_val_ptr, allocator);
    if (std.meta.activeTag(mm_val_ptr.*) != .multimethod) return error.TypeError;
    const mm_data = mm_val_ptr.*.multimethod;

    // Evaluate dispatch value
    const dispatch_val_ptr = try eval.evalRecV(allocator, &l.items[2], frame, depth + 1);
    defer vm.valueDeinit(dispatch_val_ptr, allocator);

    // Parse parameters (should be a vector/list)
    const params_form = l.items[3];
    var params: list.List = .empty;
    errdefer params.deinit(allocator);

    switch (params_form) {
        .list => |data| {
            params = try list.clone(&data.items, allocator);
        },
        .vector => |data| {
            params = try list.clone(&data.items, allocator);
        },
        else => return error.TypeError,
    }

    // Build body from remaining items, wrapped in a do block
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "do"));
    var i: usize = 4;
    while (i < l.items.len) : (i += 1) {
        try body.append(allocator, try vm.clone(&l.items[i], allocator));
    }

    // Create the method function
    const method_fn = try vm.fnValueSingle(allocator, params, body, try frame.root_env.clone(allocator), null, false);

    // Add to method table
    const dispatch_key = try vm.clone(dispatch_val_ptr, allocator);
    try mm_data.method_table.append(allocator, .{ .key = dispatch_key, .value = method_fn });

    // Phase 1: cloneGC returns *Value, extract the Value
    const ptr = try vm.cloneGC(&mm_sym, allocator);
    return .{ .value = ptr.* };
}

/// Invoke a multimethod with the given arguments.
/// Called from eval when a multimethod value is used as a function.
pub fn invokeMultimethod(allocator: Allocator, mm_val: Value, args: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval.EvalResult {
    if (std.meta.activeTag(mm_val) != .multimethod) return error.TypeError;
    const mm_data = mm_val.multimethod;

    // Call dispatch function directly with already-evaluated args
    // (avoid evalFunctionCall which would re-evaluate list args as function calls)
    const dispatch_fn = mm_data.dispatch_fn;
    // Call dispatch function - disable trampolining so we get a value directly
    const saved_trampoline = eval.trampoline_allowed;
    eval.trampoline_allowed = false;
    defer eval.trampoline_allowed = saved_trampoline;

    const dispatch_result = try eval.callWithSrc(allocator, &dispatch_fn, args, frame, depth + 1, 0);
    const dispatch_val = switch (dispatch_result) {
        // Phase 1: .value is now Value by copy, pass &v to clone
        .value => |v| try vm.clone(&v, allocator),
        .trampoline => unreachable, // should not happen with trampoline_allowed = false
    };
    defer vm.valueDeinit(@constCast(&dispatch_val), allocator);

    // Look up method in method table
    const method_fn = findMethod(mm_data.method_table, dispatch_val);

    if (method_fn) |fn_val| {
        // Call the method function directly with the original args
        const result = try eval.callWithSrc(allocator, &fn_val, args, frame, depth + 1, 0);
        return result;
    }

    // Try default dispatch value (from :default option in defmulti)
    if (mm_data.default_dispatch) |default_val| {
        const default_method = findMethod(mm_data.method_table, default_val);
        if (default_method) |fn_val| {
            const result = try eval.callWithSrc(allocator, &fn_val, args, frame, depth + 1, 0);
            return result;
        }
    }

    // Also try :default as a dispatch value (Clojure convention)
    const default_kw = try vm.keywordValue(allocator, "default");
    const default_method = findMethod(mm_data.method_table, default_kw);
    if (default_method) |fn_val| {
        const result = try eval.callWithSrc(allocator, &fn_val, args, frame, depth + 1, 0);
        return result;
    }

    return error.NoMethod;
}

// ============================================================
// Clojure-level introspection functions
// ============================================================

/// (get-method mm dispatch-val) — Get the method function for a dispatch value.
pub fn core_get_method(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 2) return error.ArityError;
    const mm = args.items[0];
    if (std.meta.activeTag(mm) != .multimethod) return error.TypeError;
    const dispatch_val = args.items[1];
    return findMethod(mm.multimethod.method_table, dispatch_val) orelse vm.nilValue();
}

/// (methods mm) — Return the method table as a map.
pub fn core_methods(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const mm = args.items[0];
    if (std.meta.activeTag(mm) != .multimethod) return error.TypeError;
    return try vm.mapValue(allocator, try vm.cloneMap(allocator, mm.multimethod.method_table));
}

/// (dispatch-fn mm) — Return the dispatch function.
pub fn core_dispatch_fn(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const mm = args.items[0];
    if (std.meta.activeTag(mm) != .multimethod) return error.TypeError;
    return try vm.clone(&mm.multimethod.dispatch_fn, allocator);
}

/// (prefer-method mm preferred dispatch-val) — Add a preference pair.
pub fn core_prefer_method(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 3) return error.ArityError;
    const mm = args.items[0];
    if (std.meta.activeTag(mm) != .multimethod) return error.TypeError;

    const preferred = args.items[1];
    const dispatch_val = args.items[2];

    // Add preference pair to pref_table
    var pair: std.ArrayListUnmanaged(Value) = .empty;
    errdefer pair.deinit(allocator);
    try pair.append(allocator, try vm.clone(&preferred, allocator));
    try pair.append(allocator, try vm.clone(&dispatch_val, allocator));
    try mm.multimethod.pref_table.append(allocator, pair);

    return mm;
}

/// (preferences mm) — Return the preference map.
pub fn core_preferences(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const mm = args.items[0];
    if (std.meta.activeTag(mm) != .multimethod) return error.TypeError;

    // Group preference pairs by preferred dispatch value
    var groups: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty;
    defer {
        for (groups.items) |*grp| grp.deinit(allocator);
        groups.deinit(allocator);
    }

    for (mm.multimethod.pref_table.items) |pair| {
        if (pair.items.len < 2) continue;
        const preferred = pair.items[0];
        const less_preferred = pair.items[1];

        var found_idx: ?usize = null;
        for (groups.items, 0..) |grp, idx| {
            if (grp.items.len > 0 and vm.equals(grp.items[0], preferred)) {
                found_idx = idx;
                break;
            }
        }

        if (found_idx) |idx| {
            try groups.items[idx].append(allocator, try vm.clone(&less_preferred, allocator));
        } else {
            var grp: std.ArrayListUnmanaged(Value) = .empty;
            errdefer grp.deinit(allocator);
            try grp.append(allocator, try vm.clone(&preferred, allocator));
            try grp.append(allocator, try vm.clone(&less_preferred, allocator));
            try groups.append(allocator, grp);
        }
    }

    // Build result map using cloneMap pattern (same as core_methods)
    var result_entries: vm.Map = .empty;
    errdefer {
        for (result_entries.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(result_entries.items);
    }

    for (groups.items) |grp| {
        if (grp.items.len < 2) continue;
        const preferred = grp.items[0];

        // Build set from remaining items
        var set_items: std.ArrayListUnmanaged(Value) = .empty;
        errdefer set_items.deinit(allocator);
        var i: usize = 1;
        while (i < grp.items.len) : (i += 1) {
            try set_items.append(allocator, try vm.clone(&grp.items[i], allocator));
        }
        const new_set = try vm.setValue(allocator, set_items);

        // Clone the preferred value using clone (same as cloneMap does)
        const cloned_key = try vm.clone(&preferred, allocator);
        try result_entries.append(allocator, .{
            .key = cloned_key,
            .value = new_set,
        });
    }

    return try vm.mapValue(allocator, result_entries);
}

// ============================================================
// Registration
// ============================================================

pub fn registerMultimethodFunctions(env: *Env) anyerror!void {
    try env.put("get-method", vm.builtinFnValue(core_get_method));
    try env.put("methods", vm.builtinFnValue(core_methods));
    try env.put("dispatch-fn", vm.builtinFnValue(core_dispatch_fn));
    try env.put("prefer-method", vm.builtinFnValue(core_prefer_method));
    try env.put("preferences", vm.builtinFnValue(core_preferences));
}
