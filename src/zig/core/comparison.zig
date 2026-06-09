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

// compare - three-way comparison returning -1, 0, or 1
// For numbers: type-independent comparison
// For nil: nil is less than everything else
pub fn core_compare(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const a = args.items[0];
    const b = args.items[1];

    // nil handling: nil < everything else
    if (a.type == .nil and b.type == .nil) return Value.intValue(0);
    if (a.type == .nil) return Value.intValue(-1);
    if (b.type == .nil) return Value.intValue(1);

    // For numbers, use type-independent comparison via f64
    const is_a_num = isNumeric(a.type);
    const is_b_num = isNumeric(b.type);
    if (is_a_num and is_b_num) {
        const a_num = toNum(a);
        const b_num = toNum(b);
        if (a_num < b_num) return Value.intValue(-1);
        if (a_num > b_num) return Value.intValue(1);
        return Value.intValue(0);
    }

    // For same types, use value equality check
    if (a.type == b.type) {
        if (a.equals(b)) return Value.intValue(0);
        // For strings, do lexicographic comparison
        if (a.type == .string) {
            const cmp = compareStrings(a.str_val, b.str_val);
            return Value.intValue(cmp);
        }
        // Fallback: use equals and return 1 if not equal
        return Value.intValue(1);
    }

    // Different non-numeric types: compare by type order
    return Value.intValue(1);
}

fn isNumeric(t: Value.Type) bool {
    return switch (t) {
        .integer, .float, .bigint, .ratio, .decimal => true,
        else => false,
    };
}

/// Compare two strings lexicographically, returning -1, 0, or 1.
fn compareStrings(a: []const u8, b: []const u8) i64 {
    const len = if (a.len < b.len) a.len else b.len;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

// == - numeric equality (type-independent)
// (== 1 1.0) => true
pub fn core_double_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return Value.boolValue(true);
    if (args.items.len == 1) return Value.boolValue(true);

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i - 1];
        const b = args.items[i];

        // If both are numeric, compare as f64
        if (isNumeric(a.type) and isNumeric(b.type)) {
            const a_num = toNum(a);
            const b_num = toNum(b);
            if (a_num != b_num) return Value.boolValue(false);
        } else {
            // Non-numeric: use value equality
            if (!a.equals(b)) return Value.boolValue(false);
        }
    }
    return Value.boolValue(true);
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
    // Three-way comparison
    try env.put("compare", Value.builtinFnValue(core_compare));
    // Numeric equality (type-independent)
    try env.put("==", Value.builtinFnValue(core_double_eq));
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

test "comparison::compare: less than" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.intValue(2) });
    var result = core_compare(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == -1);
}

test "comparison::compare: greater than" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(2), Value.intValue(1) });
    var result = core_compare(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 1);
}

test "comparison::compare: equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.intValue(1) });
    var result = core_compare(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 0);
}

test "comparison::compare: int float equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.floatValue(1.0) });
    var result = core_compare(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 0);
}

test "comparison::compare: nil less than int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue(), Value.intValue(1) });
    var result = core_compare(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == -1);
}

test "comparison::compare: nil equals nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue(), Value.nilValue() });
    var result = core_compare(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 0);
}

test "comparison::double_eq: int float equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.floatValue(1.0) });
    var result = core_double_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::double_eq: int int not equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.intValue(2) });
    var result = core_double_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "comparison::double_eq: zero args" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_double_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "comparison::double_eq: one arg" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(5) });
    var result = core_double_eq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

