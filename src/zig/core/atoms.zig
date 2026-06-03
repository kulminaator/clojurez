// Atom built-in functions: atom, swap!, reset!
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const Env = Value.Env;
const eval_helpers = @import("eval_helpers.zig");

pub fn core_atom(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return try Value.atomValue(env_env.allocator, args.items[0]);
}

pub fn core_swap_bang(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const atom = args.items[0];
    if (atom.type != .atom) return error.TypeError;
    if (atom.atom_val == null) return error.TypeError;

    const f = args.items[1];
    const data = atom.atom_val.?;

    var call_args: list.List = .empty;
    errdefer call_args.deinit(env_env.allocator);
    try call_args.append(env_env.allocator, try data.value.clone(env_env.allocator));
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        try call_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }

    const new_val = try eval_helpers.callBuiltin(env_env.allocator, f, call_args, env_env);

    data.value.deinit(env_env.allocator);
    data.value = new_val;

    return try new_val.clone(env_env.allocator);
}

pub fn core_reset_bang(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const atom = args.items[0];
    if (atom.type != .atom) return error.TypeError;
    if (atom.atom_val == null) return error.TypeError;

    const data = atom.atom_val.?;
    const new_val = try args.items[1].clone(env_env.allocator);
    data.value.deinit(env_env.allocator);
    data.value = new_val;

    return try new_val.clone(env_env.allocator);
}

pub fn registerAtomFunctions(env: *Env) anyerror!void {
    try env.put("atom", Value.builtinFnValue(core_atom));
    try env.put("swap!", Value.builtinFnValue(core_swap_bang));
    try env.put("reset!", Value.builtinFnValue(core_reset_bang));
}

