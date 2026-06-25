// Comparison and boolean built-in functions: =, !=, <, >, <=, >=, not
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const helpers = @import("helpers.zig");
const test_utils = @import("test_utils.zig");

const toNum = helpers.toNum;

pub fn core_eq(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (!vm.equals(args.items[0], args.items[i])) {
            return vm.boolValue(false);
        }
    }
    return vm.boolValue(true);
}

pub fn core_not_eq(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (vm.equals(args.items[0], args.items[i])) {
            return vm.boolValue(false);
        }
    }
    return vm.boolValue(true);
}

pub fn core_less(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a >= b) return vm.boolValue(false);
    }
    return vm.boolValue(true);
}

pub fn core_greater(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a <= b) return vm.boolValue(false);
    }
    return vm.boolValue(true);
}

pub fn core_less_eq(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a > b) return vm.boolValue(false);
    }
    return vm.boolValue(true);
}

pub fn core_greater_eq(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a < b) return vm.boolValue(false);
    }
    return vm.boolValue(true);
}

// Boolean
pub fn core_not(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(!vm.isTruthy(args.items[0]));
}

// identical? - tests if 2 arguments are the same object (identity comparison)
// For atoms: compare atom_val pointers
// For other types: compare by value (our VM uses value semantics for immutable data)
pub fn core_identical_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const a = args.items[0];
    const b = args.items[1];

    // For atoms, compare by pointer identity
    if (std.meta.activeTag(a) == .atom and std.meta.activeTag(b) == .atom) {
        return vm.boolValue(a.atom == b.atom);
    }

    // For all other types, use value equality
    // (our VM uses value semantics for immutable data)
    return vm.boolValue(vm.equals(a, b));
}

// compare - three-way comparison returning -1, 0, or 1
// For numbers: type-independent comparison
// For nil: nil is less than everything else
pub fn core_compare(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const a = args.items[0];
    const b = args.items[1];

    // nil handling: nil < everything else
    if (std.meta.activeTag(a) == .nil and std.meta.activeTag(b) == .nil) return vm.intValue(0);
    if (std.meta.activeTag(a) == .nil) return vm.intValue(-1);
    if (std.meta.activeTag(b) == .nil) return vm.intValue(1);

    // For numbers, use type-independent comparison via f64
    const is_a_num = isNumeric(std.meta.activeTag(a));
    const is_b_num = isNumeric(std.meta.activeTag(b));
    if (is_a_num and is_b_num) {
        const a_num = toNum(a);
        const b_num = toNum(b);
        if (a_num < b_num) return vm.intValue(-1);
        if (a_num > b_num) return vm.intValue(1);
        return vm.intValue(0);
    }

    // For same types, use value equality check
    if (std.meta.activeTag(a) == std.meta.activeTag(b)) {
        if (vm.equals(a, b)) return vm.intValue(0);
        // For strings, do lexicographic comparison
        if (std.meta.activeTag(a) == .string) {
            const cmp = compareStrings(a.string, b.string);
            return vm.intValue(cmp);
        }
        // Fallback: use equals and return 1 if not equal
        return vm.intValue(1);
    }

    // Different non-numeric types: compare by type order
    return vm.intValue(1);
}

fn isNumeric(t: vm.Type) bool {
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
pub fn core_double_eq(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return vm.boolValue(true);
    if (args.items.len == 1) return vm.boolValue(true);

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i - 1];
        const b = args.items[i];

        // If both are numeric, compare as f64
        if (isNumeric(std.meta.activeTag(a)) and isNumeric(std.meta.activeTag(b))) {
            const a_num = toNum(a);
            const b_num = toNum(b);
            if (a_num != b_num) return vm.boolValue(false);
        } else {
            // Non-numeric: use value equality
            if (!vm.equals(a, b)) return vm.boolValue(false);
        }
    }
    return vm.boolValue(true);
}

pub fn registerComparisonFunctions(env: *Env) anyerror!void {
    try env.put("eq", vm.builtinFnValue(core_eq));
    try env.put("not-eq", vm.builtinFnValue(core_not_eq));
    try env.put("<", vm.builtinFnValue(core_less));
    try env.put(">", vm.builtinFnValue(core_greater));
    try env.put("<=", vm.builtinFnValue(core_less_eq));
    try env.put(">=", vm.builtinFnValue(core_greater_eq));
    // Boolean
    try env.put("not", vm.builtinFnValue(core_not));
    // Identity comparison
    try env.put("identical?", vm.builtinFnValue(core_identical_q));
    // Three-way comparison
    try env.put("compare", vm.builtinFnValue(core_compare));
    // Numeric equality (type-independent)
    try env.put("==", vm.builtinFnValue(core_double_eq));
    // Clojure-style aliases
    try env.put("=", vm.builtinFnValue(core_eq));
    try env.put("!=", vm.builtinFnValue(core_not_eq));
    try env.put("not=", vm.builtinFnValue(core_not_eq));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const testSelf = test_utils.testSelf;
const makeArgs = test_utils.makeArgs;

test "comparison::eq: equal integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(5) });
    var result = core_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::eq: not equal integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(6) });
    var result = core_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "comparison::eq: multiple args all equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(3), vm.intValue(3), vm.intValue(3) });
    var result = core_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::eq: less than 2 args returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1) });
    try std.testing.expectError(error.ArityError, core_eq(testSelf(), &args, &a));
}

test "comparison::not_eq: different values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2) });
    var result = core_not_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::less: ascending chain" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2), vm.intValue(3) });
    var result = core_less(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::less: not ascending" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(3), vm.intValue(2) });
    var result = core_less(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "comparison::greater: descending chain" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(3), vm.intValue(2), vm.intValue(1) });
    var result = core_greater(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::less_eq: equal values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(5) });
    var result = core_less_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::greater_eq: equal values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(5) });
    var result = core_greater_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::not: truthy becomes false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_not(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "comparison::not: nil becomes true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue() });
    var result = core_not(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::identical_q: same atoms" {
    const alloc = std.heap.page_allocator;
    var a = testEnv();
    defer a.deinit(alloc);
    const init = vm.intValue(42);
    var atom = try vm.atomValue(alloc, init);
    defer vm.valueDeinit(&atom, alloc);
    const data = atom.atom;
    var atom2 = vm.atomValueShared(data);
    defer vm.valueDeinit(&atom2, alloc);

    const args = makeArgs(&[_]Value{ atom, atom2 });
    var result = core_identical_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, alloc);
    try std.testing.expect(result.bool == true);
}

test "comparison::identical_q: equal integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(5) });
    var result = core_identical_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::identical_q: wrong arity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1) });
    try std.testing.expectError(error.ArityError, core_identical_q(testSelf(), &args, &a));
}

test "comparison::compare: less than" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2) });
    var result = core_compare(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == -1);
}

test "comparison::compare: greater than" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(2), vm.intValue(1) });
    var result = core_compare(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 1);
}

test "comparison::compare: equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(1) });
    var result = core_compare(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 0);
}

test "comparison::compare: int float equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.floatValue(1.0) });
    var result = core_compare(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 0);
}

test "comparison::compare: nil less than int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue(), vm.intValue(1) });
    var result = core_compare(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == -1);
}

test "comparison::compare: nil equals nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue(), vm.nilValue() });
    var result = core_compare(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 0);
}

test "comparison::double_eq: int float equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.floatValue(1.0) });
    var result = core_double_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::double_eq: int int not equal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2) });
    var result = core_double_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "comparison::double_eq: zero args" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_double_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "comparison::double_eq: one arg" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5) });
    var result = core_double_eq(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

