// Metadata operations: alter-meta! special form.
// Stores and retrieves metadata for symbols in namespace environments.
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const phm = @import("persistent_hash_map.zig");
const eval = @import("eval.zig");
const Allocator = std.mem.Allocator;

/// (alter-meta! var f & args) — alter the metadata of a var.
/// var: a symbol naming a var in the current namespace.
/// f: a function to apply to the current metadata map.
/// args: additional arguments to pass to f.
/// Returns the var (symbol).
pub fn evalAlterMetaBang(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval.EvalResult {
    if (l.items.len < 3) return error.ArityError;

    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const sym_name = sym.symbol;

    // Evaluate the function f
    const fn_ptr = try eval.evalRecV(allocator, &l.items[2], frame, depth + 1);
    defer vm.valueDeinit(fn_ptr, allocator);

    // Get current metadata from namespace (or empty map if none)
    var current_meta: Value = try vm.mapValue(allocator, std.ArrayListUnmanaged(vm.MapEntry).empty);
    errdefer vm.valueDeinit(&current_meta, allocator);

    // Look up metadata in the namespace chain
    if (findNsMeta(frame.root_env, sym_name)) |existing| {
        vm.valueDeinit(&current_meta, allocator);
        current_meta = try vm.shallowClone(&existing, allocator);
    }

    // Apply f to current_meta with additional args
    var call_args: list.List = .empty;
    errdefer call_args.deinit(allocator);
    try call_args.append(allocator, try vm.shallowClone(&fn_ptr.*, allocator));
    try call_args.append(allocator, try vm.shallowClone(&current_meta, allocator));
    var i: usize = 3;
    while (i < l.items.len) : (i += 1) {
        const arg_ptr = try eval.evalRecV(allocator, &l.items[i], frame, depth + 1);
        try call_args.append(allocator, try vm.shallowClone(&arg_ptr.*, allocator));
        vm.valueDeinit(arg_ptr, allocator);
    }

    const call_list = try vm.listValue(allocator, call_args);
    const call_list_ptr = try eval.allocValue(allocator, call_list);
    const result_ptr = try eval.evalRecV(allocator, call_list_ptr, frame, depth + 1);
    const new_meta = try vm.shallowClone(&result_ptr.*, allocator);
    vm.valueDeinit(result_ptr, allocator);
    vm.valueDeinit(&current_meta, allocator);

    // Store new metadata in the namespace
    try putNsMeta(frame.root_env, sym_name, new_meta);

    // Return the symbol
    return .{ .value = try vm.cloneGC(&sym, allocator) };
}

/// Find metadata for a symbol in the namespace chain.
fn findNsMeta(env: *vm.Env, name: []const u8) ?Value {
    var current: ?*vm.Env = env;
    while (current) |e| {
        if (e.getMeta(name)) |m| return m;
        current = e.parent;
    }
    return null;
}

/// Store metadata for a symbol in the current namespace.
fn putNsMeta(env: *vm.Env, name: []const u8, meta: Value) anyerror!void {
    if (eval.findNsManager(env)) |ns_mgr| {
        const current_ns = ns_mgr.getCurrentNamespace();
        const ns_env = ns_mgr.getNamespace(current_ns) orelse env;
        try ns_env.putMeta(name, meta);
    } else {
        try env.putMeta(name, meta);
    }
}
