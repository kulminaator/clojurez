// Shared helper functions for core built-in modules
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");

const Allocator = std.mem.Allocator;

pub fn listFromVector(allocator: Allocator, v: vec.Vector) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    for (v.items) |item| {
        try result.append(allocator, try vm.shallowClone(&item, allocator));
    }
    return result;
}

pub fn listFromSlice(allocator: Allocator, items: []const Value) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    for (items) |item| {
        try result.append(allocator, try vm.shallowClone(&item, allocator));
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
    return switch (std.meta.activeTag(v)) {
        .integer => v.integer,
        .float => @as(i64, @intFromFloat(v.float)),
        else => return error.TypeError,
    };
}

pub fn toNum(v: Value) f64 {
    return switch (std.meta.activeTag(v)) {
        .integer => @as(f64, @floatFromInt(v.integer)),
        .float => v.float,
        else => 0,
    };
}

// ===== Unit Tests =====

test "helpers::isIntF64: exact integers return true" {
    try std.testing.expect(isIntF64(0.0));
    try std.testing.expect(isIntF64(1.0));
    try std.testing.expect(isIntF64(-5.0));
    try std.testing.expect(isIntF64(1000000.0));
}

test "helpers::isIntF64: non-integers return false" {
    try std.testing.expect(!isIntF64(1.5));
    try std.testing.expect(!isIntF64(-3.14));
    try std.testing.expect(!isIntF64(0.001));
}

test "helpers::isIntF64: nan and inf return false" {
    try std.testing.expect(!isIntF64(std.math.nan(f64)));
    try std.testing.expect(!isIntF64(std.math.inf(f64)));
    try std.testing.expect(!isIntF64(-std.math.inf(f64)));
}

test "helpers::isIntF64: out of i64 range returns false" {
    const huge: f64 = 1e20;
    try std.testing.expect(!isIntF64(huge));
}

test "helpers::toInt: integer value" {
    const v = vm.intValue(42);
    try std.testing.expect(try toInt(v) == 42);
}

test "helpers::toInt: float value" {
    const v = vm.floatValue(3.0);
    try std.testing.expect(try toInt(v) == 3);
}

test "helpers::toInt: non-numeric returns error" {
    const v = vm.nilValue();
    try std.testing.expectError(error.TypeError, toInt(v));
}

test "helpers::toNum: integer value" {
    const v = vm.intValue(42);
    try std.testing.expect(toNum(v) == 42.0);
}

test "helpers::toNum: float value" {
    const v = vm.floatValue(3.14);
    try std.testing.expect(toNum(v) == 3.14);
}

test "helpers::toNum: non-numeric returns 0" {
    const v = vm.nilValue();
    try std.testing.expect(toNum(v) == 0);
}
