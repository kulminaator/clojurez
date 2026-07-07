const std = @import("std");
const Allocator = std.mem.Allocator;
const vm = @import("value.zig");
const gc_mod = @import("gc.zig");
const Value = vm.Value;

pub const List = std.ArrayListUnmanaged(Value);

pub fn empty() List {
    return .empty;
}

pub fn clone(self: *const List, allocator: Allocator) anyerror!List {
    var result: List = .empty;
    defer {
        if (result.items.len > 0) {
            if (gc_mod.current_gc) |gc| {
                gc.setObjectType(@as(*anyopaque, @ptrCast(result.items.ptr)), gc_mod.GCObjectType.value_array);
            }
        }
    }
    try result.ensureTotalCapacity(allocator, self.items.len);
    for (self.items) |item| {
        try result.append(allocator, try vm.shallowClone(&item, allocator));
    }
    return result;
}

pub fn deinit(self: *List, allocator: Allocator) void {
    for (self.items) |*item| {
        vm.valueDeinit(item, allocator);
    }
    allocator.free(self.items);
    self.* = .{};
}

pub fn fmt(self: List, allocator: Allocator) anyerror![]const u8 {
    if (self.items.len == 0) return allocator.dupe(u8, "()");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '(');
    for (self.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const s = try vm.fmt(item, allocator);
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

// ===== Unit Tests =====

test "list::empty: creates empty list" {
    const l = empty();
    try std.testing.expect(l.items.len == 0);
}

test "list::fmt: empty list" {
    const a = std.heap.page_allocator;
    const s = try fmt(empty(), a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "()"));
}

test "list::fmt: list with integers" {
    const a = std.heap.page_allocator;
    var l: List = .empty;
    _ = l.append(a, vm.intValue(1)) catch unreachable;
    _ = l.append(a, vm.intValue(2)) catch unreachable;
    _ = l.append(a, vm.intValue(3)) catch unreachable;
    const s = try fmt(l, a);
    defer l.deinit(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "(1 2 3)"));
}

test "list::clone: round-trip" {
    const a = std.heap.page_allocator;
    var l: List = .empty;
    _ = l.append(a, vm.intValue(1)) catch unreachable;
    _ = l.append(a, vm.intValue(2)) catch unreachable;
    var cloned = try l.clone(a);
    defer l.deinit(a);
    defer cloned.deinit(a);
    try std.testing.expect(cloned.items.len == 2);
    try std.testing.expect(cloned.items[0].integer == 1);
    try std.testing.expect(cloned.items[1].integer == 2);
}
