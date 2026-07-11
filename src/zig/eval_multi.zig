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

/// (defmulti name dispatch-fn & options) — Create a multimethod.
/// Options: :default value (default dispatch value)
pub fn evalDefmulti(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval.EvalResult {
    if (l.items.len < 3) return error.ArityError;

    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const sym_name = sym.symbol;

    // Evaluate dispatch function
    const dispatch_fn_ptr = try eval.evalRecV(allocator, &l.items[2], frame, depth + 1);
    defer vm.valueDeinit(dispatch_fn_ptr, allocator);

    // Create multimethod value
    var mm_val = try vm.multimethodValue(allocator, dispatch_fn_ptr.*);

    // Parse optional options (starting from index 3)
    var i: usize = 3;
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

    return .{ .value = try vm.cloneGC(&sym, allocator) };
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

    return .{ .value = try vm.cloneGC(&mm_sym, allocator) };
}

/// Invoke a multimethod with the given arguments.
/// Called from eval when a multimethod value is used as a function.
pub fn invokeMultimethod(allocator: Allocator, mm_val: Value, args: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval.EvalResult {
    if (std.meta.activeTag(mm_val) != .multimethod) return error.TypeError;
    const mm_data = mm_val.multimethod;

    // Build call list: (dispatch-fn arg1 arg2 ...)
    var dispatch_call: list.List = .empty;
    defer dispatch_call.deinit(allocator);
    try dispatch_call.append(allocator, try vm.clone(&mm_data.dispatch_fn, allocator));
    for (args.items) |arg| {
        try dispatch_call.append(allocator, try vm.clone(&arg, allocator));
    }

    const dispatch_call_list = try vm.listValue(allocator, dispatch_call);
    const dispatch_call_ptr = try eval.allocValue(allocator, dispatch_call_list);
    const dispatch_result_ptr = try eval.evalRecV(allocator, dispatch_call_ptr, frame, depth + 1);
    const dispatch_val = try vm.clone(&dispatch_result_ptr.*, allocator);
    vm.valueDeinit(dispatch_result_ptr, allocator);
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

// ============================================================
// Registration
// ============================================================

pub fn registerMultimethodFunctions(env: *Env) anyerror!void {
    try env.put("get-method", vm.builtinFnValue(core_get_method));
    try env.put("methods", vm.builtinFnValue(core_methods));
    try env.put("dispatch-fn", vm.builtinFnValue(core_dispatch_fn));
}
