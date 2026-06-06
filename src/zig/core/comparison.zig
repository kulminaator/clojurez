// Comparison and boolean built-in functions: =, !=, <, >, <=, >=, not
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const Env = Value.Env;
const helpers = @import("helpers.zig");

const toNum = helpers.toNum;

pub fn core_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (!args.items[0].equals(args.items[i])) {
            return Value.boolValue(false);
        }
    }
    return Value.boolValue(true);
}

pub fn core_not_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (args.items[0].equals(args.items[i])) {
            return Value.boolValue(false);
        }
    }
    return Value.boolValue(true);
}

pub fn core_less(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a >= b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_greater(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a <= b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_less_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a > b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_greater_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a < b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

// Boolean
pub fn core_not(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(!args.items[0].isTruthy());
}

// identical? - tests if 2 arguments are the same object (identity comparison)
// For atoms: compare atom_val pointers
// For other types: compare by value (our VM uses value semantics for immutable data)
pub fn core_identical_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const a = args.items[0];
    const b = args.items[1];

    // For atoms, compare by pointer identity
    if (a.type == .atom and b.type == .atom) {
        return Value.boolValue(a.atom_val == b.atom_val);
    }

    // For all other types, use value equality
    // (our VM uses value semantics for immutable data)
    return Value.boolValue(a.equals(b));
}

pub fn registerComparisonFunctions(env: *Env) anyerror!void {
    try env.put("eq", Value.builtinFnValue(core_eq));
    try env.put("not-eq", Value.builtinFnValue(core_not_eq));
    try env.put("<", Value.builtinFnValue(core_less));
    try env.put(">", Value.builtinFnValue(core_greater));
    try env.put("<=", Value.builtinFnValue(core_less_eq));
    try env.put(">=", Value.builtinFnValue(core_greater_eq));
    // Boolean
    try env.put("not", Value.builtinFnValue(core_not));
    // Identity comparison
    try env.put("identical?", Value.builtinFnValue(core_identical_q));
    // Clojure-style aliases
    try env.put("=", Value.builtinFnValue(core_eq));
    try env.put("!=", Value.builtinFnValue(core_not_eq));
    try env.put("not=", Value.builtinFnValue(core_not_eq));
}

// ===== Unit Tests =====

fn testEnv() Value.Env {
    return Value.Env.init(std.heap.page_allocator);
}

var _testSelf: Value = Value.nilValue();
fn testSelf() *Value {
    return &_testSelf;
}

fn makeArgs(args: []const Value) list.List {
    var result: list.List = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        _ = result.append(std.heap.page_allocator, args[i]) catch unreachable;
    }
    return result;
}

test "comparison::eq: equal integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(5), Value.intValue(5) });
    var result = core_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::eq: not equal integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(5), Value.intValue(6) });
    var result = core_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "comparison::eq: multiple args all equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(3), Value.intValue(3), Value.intValue(3) });
    var result = core_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::eq: less than 2 args returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1) });
    try std.testing.expectError(error.ArityError, core_eq(testSelf(), args, &a));
}

test "comparison::not_eq: different values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.intValue(2) });
    var result = core_not_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::less: ascending chain" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.intValue(2), Value.intValue(3) });
    var result = core_less(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::less: not ascending" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(3), Value.intValue(2) });
    var result = core_less(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "comparison::greater: descending chain" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(3), Value.intValue(2), Value.intValue(1) });
    var result = core_greater(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::less_eq: equal values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(5), Value.intValue(5) });
    var result = core_less_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::greater_eq: equal values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(5), Value.intValue(5) });
    var result = core_greater_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::not: truthy becomes false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_not(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "comparison::not: nil becomes true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_not(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::identical_q: same atoms" {
    const alloc = std.heap.page_allocator;
    var a = testEnv();
    defer a.deinit(alloc);
    const init = Value.intValue(42);
    var atom = try Value.atomValue(alloc, init);
    defer atom.deinit(alloc);
    const data = atom.atom_val.?;
    var atom2 = Value.atomValueShared(data);
    defer atom2.deinit(alloc);

    const args = makeArgs(&[_]Value{ atom, atom2 });
    var result = core_identical_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(alloc);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::identical_q: equal integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(5), Value.intValue(5) });
    var result = core_identical_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::identical_q: wrong arity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1) });
    try std.testing.expectError(error.ArityError, core_identical_q(testSelf(), args, &a));
}

