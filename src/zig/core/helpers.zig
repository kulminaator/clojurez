// Shared helper functions for core built-in modules
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");

const Allocator = std.mem.Allocator;

pub fn listFromVector(allocator: Allocator, v: vec.Vector) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    for (v.items) |item| {
        try result.append(allocator, try item.clone(allocator));
    }
    return result;
}

pub fn listFromSlice(allocator: Allocator, items: []const Value) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    for (items) |item| {
        try result.append(allocator, try item.clone(allocator));
    }
    return result;
}

pub fn isIntF64(f: f64) bool {
    if (std.math.isNan(f) or std.math.isInf(f)) return false;
    const min_f: f64 = @as(f64, @floatFromInt(std.math.minInt(i64)));
    const max_f: f64 = @as(f64, @floatFromInt(std.math.maxInt(i64)));
    if (f < min_f or f > max_f) return false;
    const i = @as(i64, @intFromFloat(f));
    return f == @as(f64, @floatFromInt(i));
}

pub fn toInt(v: Value) anyerror!i64 {
    return switch (v.type) {
        .integer => v.int_val,
        .float => @as(i64, @intFromFloat(v.float_val)),
        else => return error.TypeError,
    };
}

pub fn toNum(v: Value) f64 {
    return switch (v.type) {
        .integer => @as(f64, @floatFromInt(v.int_val)),
        .float => v.float_val,
        else => 0,
    };
}
