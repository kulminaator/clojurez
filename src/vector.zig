const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig");

pub const Vector = std.ArrayListUnmanaged(Value);

pub fn empty() Vector {
    return .empty;
}

pub fn clone(self: *const Vector, allocator: Allocator) anyerror!Vector {
    var result: Vector = .{};
    try result.ensureTotalCapacity(allocator, self.items.len);
    for (self.items) |item| {
        try result.append(allocator, try item.clone(allocator));
    }
    return result;
}

pub fn deinit(self: *Vector, allocator: Allocator) void {
    for (self.items) |*item| {
        item.deinit(allocator);
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
        const s = try item.fmt(allocator);
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}
