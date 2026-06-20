// Atom built-in functions: atom, swap!, reset!
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const Env = Value.Env;
const eval_helpers = @import("eval_helpers.zig");
const test_utils = @import("test_utils.zig");

pub fn core_deref(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    // Extract value from atom
    if (arg.type == .atom) {
        if (arg.atom_val) |data| {
            return try data.value.clone(env_env.allocator);
        }
        return Value.nilValue();
    }
    // For non-atoms, return as-is
    return try arg.clone(env_env.allocator);
}

pub fn core_atom(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return try Value.atomValue(env_env.allocator, args.items[0]);
}

pub fn core_swap_bang(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
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

pub fn core_reset_bang(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
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
    try env.put("deref", Value.builtinFnValue(core_deref));
    try env.put("swap!", Value.builtinFnValue(core_swap_bang));
    try env.put("reset!", Value.builtinFnValue(core_reset_bang));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "atoms::atom: creates atom" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_atom(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .atom);
    try std.testing.expect(result.atom_val.?.value.int_val == 42);
}

test "atoms::deref: gets atom value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var atom = try Value.atomValue(std.heap.page_allocator, Value.intValue(42));
    defer atom.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ atom });
    var result = core_deref(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == 42);
}

test "atoms::reset_bang: resets atom value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var atom = try Value.atomValue(std.heap.page_allocator, Value.intValue(42));
    defer atom.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ atom, Value.intValue(99) });
    var result = core_reset_bang(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 99);
    // Atom should now hold 99
    try std.testing.expect(atom.atom_val.?.value.int_val == 99);
}

test "atoms::reset_bang: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.intValue(2) });
    try std.testing.expectError(error.TypeError, core_reset_bang(testSelf(), &args, &a));
}

test "atoms::atom: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_atom(testSelf(), &args, &a));
}

