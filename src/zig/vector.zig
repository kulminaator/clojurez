const std = @import("std");
const Allocator = std.mem.Allocator;
const vm = @import("value.zig");
const Value = vm.Value;

pub const Vector = std.ArrayListUnmanaged(Value);

pub fn empty() Vector {
    return .empty;
}

pub fn clone(self: *const Vector, allocator: Allocator) anyerror!Vector {
    var result: Vector = .empty;
    try result.ensureTotalCapacity(allocator, self.items.len);
    for (self.items) |item| {
        try result.append(allocator, try vm.clone(&item, allocator));
    }
    return result;
}

pub fn deinit(self: *Vector, allocator: Allocator) void {
    for (self.items) |*item| {
        vm.valueDeinit(item, allocator);
    }
    allocator.free(self.items);
    self.* = .{};
}

pub fn fmt(self: Vector, allocator: Allocator) anyerror![]const u8 {
    if (self.items.len == 0) return allocator.dupe(u8, "[]");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (self.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const s = try vm.fmt(item, allocator);
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

// ===== Unit Tests =====

test "vector::empty: creates empty vector" {
    const v = empty();
    try std.testing.expect(v.items.len == 0);
}

test "vector::fmt: empty vector" {
    const a = std.heap.page_allocator;
    const s = try fmt(empty(), a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "[]"));
}

test "vector::fmt: vector with integers" {
    const a = std.heap.page_allocator;
    var v: Vector = .empty;
    _ = v.append(a, vm.intValue(1)) catch unreachable;
    _ = v.append(a, vm.intValue(2)) catch unreachable;
    const s = try fmt(v, a);
    defer v.deinit(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "[1 2]"));
}

test "vector::clone: round-trip" {
    const a = std.heap.page_allocator;
    var v: Vector = .empty;
    _ = v.append(a, vm.intValue(10)) catch unreachable;
    _ = v.append(a, vm.intValue(20)) catch unreachable;
    var cloned = try v.clone(a);
    defer v.deinit(a);
    defer cloned.deinit(a);
    try std.testing.expect(cloned.items.len == 2);
    try std.testing.expect(cloned.items[0].integer == 10);
    try std.testing.expect(cloned.items[1].integer == 20);
}
