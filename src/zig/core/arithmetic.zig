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
    const allocator = env.allocator;
    try env.put(allocator, "plus", Value.builtinFnValue(core_plus));
    try env.put(allocator, "minus", Value.builtinFnValue(core_minus));
    try env.put(allocator, "mult", Value.builtinFnValue(core_mult));
    try env.put(allocator, "div", Value.builtinFnValue(core_div));
    try env.put(allocator, "mod", Value.builtinFnValue(core_mod));
    // Clojure-style aliases
    try env.put(allocator, "+", Value.builtinFnValue(core_plus));
    try env.put(allocator, "-", Value.builtinFnValue(core_minus));
    try env.put(allocator, "*", Value.builtinFnValue(core_mult));
    try env.put(allocator, "/", Value.builtinFnValue(core_div));
    try env.put(allocator, "rem", Value.builtinFnValue(core_mod));
}

