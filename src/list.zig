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
