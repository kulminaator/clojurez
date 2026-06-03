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

pub fn registerComparisonFunctions(env: *Env) anyerror!void {
    try env.put("eq", Value.builtinFnValue(core_eq));
    try env.put("not-eq", Value.builtinFnValue(core_not_eq));
    try env.put("<", Value.builtinFnValue(core_less));
    try env.put(">", Value.builtinFnValue(core_greater));
    try env.put("<=", Value.builtinFnValue(core_less_eq));
    try env.put(">=", Value.builtinFnValue(core_greater_eq));
    // Boolean
    try env.put("not", Value.builtinFnValue(core_not));
    // Clojure-style aliases
    try env.put("=", Value.builtinFnValue(core_eq));
    try env.put("!=", Value.builtinFnValue(core_not_eq));
}

