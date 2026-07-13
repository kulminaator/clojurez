// Atom built-in functions: atom, swap!, reset!
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const eval_helpers = @import("eval_helpers.zig");
const test_utils = @import("test_utils.zig");

pub fn core_deref(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    // Extract value from atom
    if (std.meta.activeTag(arg) == .atom) {
        const data = arg.atom;
        return data.value;
    }
    // For non-atoms, return as-is
    return arg;
}

pub fn core_atom(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return try vm.atomValue(env_env.allocator, args.items[0]);
}

pub fn core_swap_bang(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const atom = args.items[0];
    if (std.meta.activeTag(atom) != .atom) return error.TypeError;
    const f = args.items[1];
    const data = atom.atom;

    var call_args: list.List = .empty;
    errdefer call_args.deinit(env_env.allocator);
    try call_args.append(env_env.allocator, data.value);
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        try call_args.append(env_env.allocator, args.items[i]);
    }

    const new_val_ptr = try eval_helpers.callBuiltin(env_env.allocator, &f, call_args.items, env_env);
    const new_val = new_val_ptr.*;
    env_env.allocator.destroy(new_val_ptr);

    vm.valueDeinit(&data.value, env_env.allocator);
    data.value = new_val;

    return new_val;
}

pub fn core_reset_bang(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const atom = args.items[0];
    if (std.meta.activeTag(atom) != .atom) return error.TypeError;
    const data = atom.atom;
    const new_val = args.items[1];
    vm.valueDeinit(&data.value, env_env.allocator);
    data.value = new_val;

    return new_val;
}

pub fn registerAtomFunctions(env: *Env) anyerror!void {
    try env.put("atom", vm.builtinFnValue(core_atom));
    try env.put("deref", vm.builtinFnValue(core_deref));
    try env.put("swap!", vm.builtinFnValue(core_swap_bang));
    try env.put("reset!", vm.builtinFnValue(core_reset_bang));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "atoms::atom: creates atom" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_atom(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .atom);
    try std.testing.expect(result.atom.value.integer == 42);
}

test "atoms::deref: gets atom value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var atom = try vm.atomValue(std.heap.page_allocator, vm.intValue(42));
    defer vm.valueDeinit(&atom, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ atom });
    var result = core_deref(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 42);
}

test "atoms::reset_bang: resets atom value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var atom = try vm.atomValue(std.heap.page_allocator, vm.intValue(42));
    defer vm.valueDeinit(&atom, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ atom, vm.intValue(99) });
    var result = core_reset_bang(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 99);
    // Atom should now hold 99
    try std.testing.expect(atom.atom.value.integer == 99);
}

test "atoms::reset_bang: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2) });
    try std.testing.expectError(error.TypeError, core_reset_bang(testSelf(), &args, &a));
}

test "atoms::atom: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_atom(testSelf(), &args, &a));
}

