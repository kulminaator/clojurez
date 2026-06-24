// Bitwise built-in functions: bit-not, bit-and, bit-or, bit-xor, bit-and-not,
// bit-clear, bit-set, bit-flip, bit-test, bit-shift-left, bit-shift-right,
// unsigned-bit-shift-right
//
// All bitwise operations work only on integer (i64) values.
// BigInt and float values are not supported (matching Clojure behavior).
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const test_utils = @import("test_utils.zig");

const Allocator = std.mem.Allocator;

// ============================================================
// Helper: extract i64 from a Value, error on non-integer types
// ============================================================

fn toI64(v: Value) anyerror!i64 {
    return switch (std.meta.activeTag(v)) {
        .integer => v.int_val,
        else => return error.TypeError,
    };
}

// ============================================================
// bit-not - Bitwise NOT (complement)
// ============================================================

pub fn core_bit_not(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const x = try toI64(args.items[0]);
    return vm.intValue(~x);
}

// ============================================================
// bit-and - Bitwise AND (n-ary)
// ============================================================

pub fn core_bit_and(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2) return error.ArityError;
    var result: i64 = try toI64(args.items[0]);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        result = result & try toI64(args.items[i]);
    }
    return vm.intValue(result);
}

// ============================================================
// bit-or - Bitwise OR (n-ary)
// ============================================================

pub fn core_bit_or(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2) return error.ArityError;
    var result: i64 = try toI64(args.items[0]);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        result = result | try toI64(args.items[i]);
    }
    return vm.intValue(result);
}

// ============================================================
// bit-xor - Bitwise XOR (n-ary)
// ============================================================

pub fn core_bit_xor(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2) return error.ArityError;
    var result: i64 = try toI64(args.items[0]);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        result = result ^ try toI64(args.items[i]);
    }
    return vm.intValue(result);
}

// ============================================================
// bit-and-not - Bitwise AND NOT (n-ary)
// bit-and-not x y = x & (~y)
// For n-ary: reduce left to right, (bit-and-not (bit-and-not x y1) y2) ...
// ============================================================

pub fn core_bit_and_not(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2) return error.ArityError;
    var result: i64 = try toI64(args.items[0]);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        result = result & (~try toI64(args.items[i]));
    }
    return vm.intValue(result);
}

// ============================================================
// bit-clear - Clear bit at position n
// ============================================================

pub fn core_bit_clear(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const x = try toI64(args.items[0]);
    const n = try toI64(args.items[1]);
    if (n < 0 or n >= 64) return error.IndexOutOfBounds;
    return vm.intValue(x & ~(@as(i64, 1) << @as(u6, @intCast(n))));
}

// ============================================================
// bit-set - Set bit at position n
// ============================================================

pub fn core_bit_set(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const x = try toI64(args.items[0]);
    const n = try toI64(args.items[1]);
    if (n < 0 or n >= 64) return error.IndexOutOfBounds;
    return vm.intValue(x | (@as(i64, 1) << @as(u6, @intCast(n))));
}

// ============================================================
// bit-flip - Flip bit at position n
// ============================================================

pub fn core_bit_flip(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const x = try toI64(args.items[0]);
    const n = try toI64(args.items[1]);
    if (n < 0 or n >= 64) return error.IndexOutOfBounds;
    return vm.intValue(x ^ (@as(i64, 1) << @as(u6, @intCast(n))));
}

// ============================================================
// bit-test - Test bit at position n (returns true/false)
// ============================================================

pub fn core_bit_test(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const x = try toI64(args.items[0]);
    const n = try toI64(args.items[1]);
    if (n < 0 or n >= 64) return error.IndexOutOfBounds;
    return vm.boolValue((x & (@as(i64, 1) << @as(u6, @intCast(n)))) != 0);
}

// ============================================================
// bit-shift-left - Bitwise shift left
// ============================================================

pub fn core_bit_shift_left(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const x = try toI64(args.items[0]);
    const n = try toI64(args.items[1]);
    if (n < 0) return error.InvalidArgument;
    if (n >= 64) return vm.intValue(0);
    return vm.intValue(x << @as(u6, @intCast(n)));
}

// ============================================================
// bit-shift-right - Bitwise shift right (signed / arithmetic)
// ============================================================

pub fn core_bit_shift_right(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const x = try toI64(args.items[0]);
    const n = try toI64(args.items[1]);
    if (n < 0) return error.InvalidArgument;
    if (n >= 64) {
        // Signed shift: if x is negative, result is -1; if non-negative, result is 0
        return vm.intValue(if (x < 0) -1 else 0);
    }
    return vm.intValue(x >> @as(u6, @intCast(n)));
}

// ============================================================
// unsigned-bit-shift-right - Bitwise shift right (unsigned / logical)
// ============================================================

pub fn core_unsigned_bit_shift_right(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const x = try toI64(args.items[0]);
    const n = try toI64(args.items[1]);
    if (n < 0) return error.InvalidArgument;
    if (n >= 64) return vm.intValue(0);
    // Treat x as unsigned for the shift
    const ux: u64 = @bitCast(x);
    const result: u64 = ux >> @as(u6, @intCast(n));
    return vm.intValue(@bitCast(result));
}

// ============================================================
// Registration
// ============================================================

pub fn registerBitwiseFunctions(env: *Env) anyerror!void {
    try env.put("bit-not", vm.builtinFnValue(core_bit_not));
    try env.put("bit-and", vm.builtinFnValue(core_bit_and));
    try env.put("bit-or", vm.builtinFnValue(core_bit_or));
    try env.put("bit-xor", vm.builtinFnValue(core_bit_xor));
    try env.put("bit-and-not", vm.builtinFnValue(core_bit_and_not));
    try env.put("bit-clear", vm.builtinFnValue(core_bit_clear));
    try env.put("bit-set", vm.builtinFnValue(core_bit_set));
    try env.put("bit-flip", vm.builtinFnValue(core_bit_flip));
    try env.put("bit-test", vm.builtinFnValue(core_bit_test));
    try env.put("bit-shift-left", vm.builtinFnValue(core_bit_shift_left));
    try env.put("bit-shift-right", vm.builtinFnValue(core_bit_shift_right));
    try env.put("unsigned-bit-shift-right", vm.builtinFnValue(core_unsigned_bit_shift_right));
}

// ============================================================
// Unit Tests
// ============================================================
const testEnv = test_utils.testEnv;
const testSelf = test_utils.testSelf;
const makeArgs = test_utils.makeArgs;

test "bitwise::bit-not: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5) });
    var result = core_bit_not(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == -6);
}

test "bitwise::bit-not: -1" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-1) });
    var result = core_bit_not(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 0);
}

test "bitwise::bit-and: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(12), vm.intValue(10) });
    var result = core_bit_and(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 8);
}

test "bitwise::bit-and: n-ary" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2), vm.intValue(4), vm.intValue(8) });
    var result = core_bit_and(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 0);
}

test "bitwise::bit-or: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(12), vm.intValue(10) });
    var result = core_bit_or(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 14);
}

test "bitwise::bit-or: n-ary" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2), vm.intValue(4), vm.intValue(8) });
    var result = core_bit_or(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 15);
}

test "bitwise::bit-xor: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(12), vm.intValue(10) });
    var result = core_bit_xor(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 6);
}

test "bitwise::bit-xor: n-ary" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2), vm.intValue(4), vm.intValue(8) });
    var result = core_bit_xor(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 15);
}

test "bitwise::bit-and-not: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(12), vm.intValue(10) });
    var result = core_bit_and_not(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 4);
}

test "bitwise::bit-and-not: n-ary" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(15), vm.intValue(1), vm.intValue(2), vm.intValue(4) });
    var result = core_bit_and_not(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 8);
}

test "bitwise::bit-clear: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(10), vm.intValue(1) });
    var result = core_bit_clear(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 8);
}

test "bitwise::bit-set: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(10), vm.intValue(1) });
    var result = core_bit_set(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 10);
}

test "bitwise::bit-flip: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(10), vm.intValue(1) });
    var result = core_bit_flip(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 8);
}

test "bitwise::bit-test: true" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(10), vm.intValue(1) });
    var result = core_bit_test(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bool);
    try std.testing.expect(result.bool_val == true);
}

test "bitwise::bit-test: false" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(10), vm.intValue(0) });
    var result = core_bit_test(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bool);
    try std.testing.expect(result.bool_val == false);
}

test "bitwise::bit-test: -1 bit 0" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-1), vm.intValue(0) });
    var result = core_bit_test(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bool);
    try std.testing.expect(result.bool_val == true);
}

test "bitwise::bit-shift-left: basic" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(2) });
    var result = core_bit_shift_left(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 20);
}

test "bitwise::bit-shift-right: signed negative" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-8), vm.intValue(2) });
    var result = core_bit_shift_right(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == -2);
}

test "bitwise::unsigned-bit-shift-right: negative value" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-8), vm.intValue(2) });
    var result = core_unsigned_bit_shift_right(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 4611686018427387902);
}

test "bitwise::bit-shift-right: shift >= 64" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-1), vm.intValue(64) });
    var result = core_bit_shift_right(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == -1);
}

test "bitwise::bit-shift-left: shift >= 64" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(64) });
    var result = core_bit_shift_left(testSelf(), &args, &env) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.int_val == 0);
}

test "bitwise::bit-not: type error on float" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.5) });
    const result = core_bit_not(testSelf(), &args, &env);
    try std.testing.expectError(error.TypeError, result);
}

test "bitwise::bit-and: type error on float" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.floatValue(2.0) });
    const result = core_bit_and(testSelf(), &args, &env);
    try std.testing.expectError(error.TypeError, result);
}

test "bitwise::bit-clear: negative position" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(10), vm.intValue(-1) });
    const result = core_bit_clear(testSelf(), &args, &env);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

test "bitwise::bit-clear: position >= 64" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(10), vm.intValue(64) });
    const result = core_bit_clear(testSelf(), &args, &env);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

test "bitwise::bit-shift-left: negative shift" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5), vm.intValue(-1) });
    const result = core_bit_shift_left(testSelf(), &args, &env);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "bitwise::bit-and: arity error" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1) });
    const result = core_bit_and(testSelf(), &args, &env);
    try std.testing.expectError(error.ArityError, result);
}

test "bitwise::bit-not: arity error" {
    var env = testEnv();
    defer env.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    const result = core_bit_not(testSelf(), &args, &env);
    try std.testing.expectError(error.ArityError, result);
}
