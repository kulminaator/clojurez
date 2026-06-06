const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig");

pub const List = std.ArrayListUnmanaged(Value);

pub fn empty() List {
    return .empty;
}

pub fn clone(self: *const List, allocator: Allocator) anyerror!List {
    var result: List = .{};
    try result.ensureTotalCapacity(allocator, self.items.len);
    for (self.items) |item| {
        try result.append(allocator, try item.clone(allocator));
    }
    return result;
}

pub fn deinit(self: *List, allocator: Allocator) void {
    for (self.items) |*item| {
        item.deinit(allocator);
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
        const s = try item.fmt(allocator);
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
    _ = l.append(a, Value.intValue(1)) catch unreachable;
    _ = l.append(a, Value.intValue(2)) catch unreachable;
    _ = l.append(a, Value.intValue(3)) catch unreachable;
    const s = try fmt(l, a);
    defer l.deinit(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "(1 2 3)"));
}

test "list::clone: round-trip" {
    const a = std.heap.page_allocator;
    var l: List = .empty;
    _ = l.append(a, Value.intValue(1)) catch unreachable;
    _ = l.append(a, Value.intValue(2)) catch unreachable;
    var cloned = try l.clone(a);
    defer l.deinit(a);
    defer cloned.deinit(a);
    try std.testing.expect(cloned.items.len == 2);
    try std.testing.expect(cloned.items[0].int_val == 1);
    try std.testing.expect(cloned.items[1].int_val == 2);
}
