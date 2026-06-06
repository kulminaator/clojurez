// Arithmetic built-in functions: +, -, *, /, rem
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const Env = Value.Env;
const helpers = @import("helpers.zig");

const isIntF64 = helpers.isIntF64;
const toInt = helpers.toInt;

pub fn core_plus(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    var sum: f64 = 0;
    for (args.items) |arg| {
        switch (arg.type) {
            .integer => sum += @as(f64, @floatFromInt(arg.int_val)),
            .float => sum += arg.float_val,
            else => return error.TypeError,
        }
    }
    if (isIntF64(sum)) {
        return Value.intValue(@as(i64, @intFromFloat(sum)));
    }
    return Value.floatValue(sum);
}

pub fn core_minus(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return error.ArityError;
    var result: f64 = undefined;
    switch (args.items[0].type) {
        .integer => result = @as(f64, @floatFromInt(args.items[0].int_val)),
        .float => result = args.items[0].float_val,
        else => return error.TypeError,
    }
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        var sub: f64 = undefined;
        switch (args.items[i].type) {
            .integer => sub = @as(f64, @floatFromInt(args.items[i].int_val)),
            .float => sub = args.items[i].float_val,
            else => return error.TypeError,
        }
        result -= sub;
    }
    if (isIntF64(result)) {
        return Value.intValue(@as(i64, @intFromFloat(result)));
    }
    return Value.floatValue(result);
}

pub fn core_mult(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    var product: f64 = 1;
    for (args.items) |arg| {
        switch (arg.type) {
            .integer => product *= @as(f64, @floatFromInt(arg.int_val)),
            .float => product *= arg.float_val,
            else => return error.TypeError,
        }
    }
    if (isIntF64(product)) {
        return Value.intValue(@as(i64, @intFromFloat(product)));
    }
    return Value.floatValue(product);
}

pub fn core_div(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return error.ArityError;
    var result: f64 = undefined;
    switch (args.items[0].type) {
        .integer => result = @as(f64, @floatFromInt(args.items[0].int_val)),
        .float => result = args.items[0].float_val,
        else => return error.TypeError,
    }
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        var divisor: f64 = undefined;
        switch (args.items[i].type) {
            .integer => divisor = @as(f64, @floatFromInt(args.items[i].int_val)),
            .float => divisor = args.items[i].float_val,
            else => return error.TypeError,
        }
        if (divisor == 0) return error.DivisionByZero;
        result /= divisor;
    }
    if (isIntF64(result)) {
        return Value.intValue(@as(i64, @intFromFloat(result)));
    }
    return Value.floatValue(result);
}

pub fn core_mod(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const a = try toInt(args.items[0]);
    const b = try toInt(args.items[1]);
    if (b == 0) return error.DivisionByZero;
    return Value.intValue(@rem(a, b));
}

pub fn registerArithmeticFunctions(env: *Env) anyerror!void {
    try env.put("plus", Value.builtinFnValue(core_plus));
    try env.put("minus", Value.builtinFnValue(core_minus));
    try env.put("mult", Value.builtinFnValue(core_mult));
    try env.put("div", Value.builtinFnValue(core_div));
    try env.put("mod", Value.builtinFnValue(core_mod));
    // Clojure-style aliases
    try env.put("+", Value.builtinFnValue(core_plus));
    try env.put("-", Value.builtinFnValue(core_minus));
    try env.put("*", Value.builtinFnValue(core_mult));
    try env.put("/", Value.builtinFnValue(core_div));
    try env.put("rem", Value.builtinFnValue(core_mod));
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

test "arithmetic::plus: two integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(2), Value.intValue(3) });
    var result = core_plus(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == 5);
}

test "arithmetic::plus: zero args returns 0" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_plus(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 0);
}

test "arithmetic::plus: mixed int and float" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(3), Value.floatValue(1.5) });
    var result = core_plus(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .float);
    try std.testing.expect(result.float_val == 4.5);
}

test "arithmetic::plus: type error on non-numeric" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.nilValue() });
    try std.testing.expectError(error.TypeError, core_plus(testSelf(), args, &a));
}

test "arithmetic::minus: single arg returns value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(5) });
    var result = core_minus(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    // Single arg: returns the value as-is (no negation in current impl)
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == 5);
}

test "arithmetic::minus: two args" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(10), Value.intValue(3) });
    var result = core_minus(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 7);
}

test "arithmetic::minus: zero args returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_minus(testSelf(), args, &a));
}

test "arithmetic::mult: two integers" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(6), Value.intValue(7) });
    var result = core_mult(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 42);
}

test "arithmetic::mult: zero args returns 1" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_mult(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 1);
}

test "arithmetic::div: integer division" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    // 10/3 = 3.333... which is not an integer, so returns float
    const args = makeArgs(&[_]Value{ Value.intValue(10), Value.intValue(3) });
    var result = core_div(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .float);
    try std.testing.expect(result.float_val > 3.33 and result.float_val < 3.34);
}

test "arithmetic::div: exact division" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    // 10/2 = 5.0 which is an integer
    const args = makeArgs(&[_]Value{ Value.intValue(10), Value.intValue(2) });
    var result = core_div(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == 5);
}

test "arithmetic::div: division by zero" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(10), Value.intValue(0) });
    try std.testing.expectError(error.DivisionByZero, core_div(testSelf(), args, &a));
}

test "arithmetic::div: zero args returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_div(testSelf(), args, &a));
}

test "arithmetic::mod: basic modulo" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(10), Value.intValue(3) });
    var result = core_mod(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 1);
}

test "arithmetic::mod: division by zero" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(10), Value.intValue(0) });
    try std.testing.expectError(error.DivisionByZero, core_mod(testSelf(), args, &a));
}

test "arithmetic::mod: wrong arity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(10) });
    try std.testing.expectError(error.ArityError, core_mod(testSelf(), args, &a));
}

