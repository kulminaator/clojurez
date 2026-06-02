const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();
const list = @import("list.zig");
const vec = @import("vector.zig");

pub const Type = enum {
    nil,
    bool,
    integer,
    float,
    string,
    symbol,
    keyword,
    list,
    vector,
    function,
    builtin_fn,
};

pub const BuiltinFn = *const fn (self: *Self, args: list.List, env: *Env) anyerror!Self;

type: Type,

nil_val: void = {},
bool_val: bool = false,
int_val: i64 = 0,
float_val: f64 = 0.0,
str_val: []const u8 = "",
sym_val: []const u8 = "",
kw_val: []const u8 = "",
list_val: list.List = list.List.empty,
vec_val: vec.Vector = vec.Vector.empty,
fn_val: FnData = .{ .params = list.List.empty, .body = list.List.empty, .env = undefined },
builtin_fn_val: BuiltinFn = undefined,

pub const FnData = struct {
    params: list.List,
    body: list.List,
    env: Env,
};

pub const Env = struct {
    allocator: Allocator,
    entries: std.StringArrayHashMapUnmanaged(Self) = .empty,
    parent: ?*Env = null,

    pub fn init(allocator: Allocator) Env {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .parent = null,
        };
    }

    pub fn deinit(self: *Env, allocator: Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit(allocator);
        _ = self.parent; // Don't deinit parent here; it's managed separately
    }

    pub fn clone(self: *const Env, allocator: Allocator) anyerror!Env {
        var new_env: Env = .{
            .allocator = allocator,
            .entries = .empty,
            .parent = self.parent,
        };
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const cloned_val = try entry.value_ptr.clone(allocator);
            try new_env.entries.put(allocator, entry.key_ptr.*, cloned_val);
        }
        return new_env;
    }

    pub fn put(self: *Env, allocator: Allocator, name: []const u8, value: Self) anyerror!void {
        try self.entries.put(allocator, name, value);
    }

    pub fn get(self: *Env, name: []const u8) ?Self {
        var current: ?*Env = self;
        while (current) |env| {
            const found = env.entries.get(name);
            if (found) |val| return val;
            current = env.parent;
        }
        return null;
    }

    pub fn has(self: *Env, name: []const u8) bool {
        var current: ?*Env = self;
        while (current) |env| {
            if (env.entries.contains(name)) return true;
            current = env.parent;
        }
        return false;
    }
};

pub fn nilValue() Self {
    return .{ .type = .nil };
}

pub fn boolValue(b: bool) Self {
    return .{ .type = .bool, .bool_val = b };
}

pub fn intValue(i: i64) Self {
    return .{ .type = .integer, .int_val = i };
}

pub fn floatValue(f: f64) Self {
    return .{ .type = .float, .float_val = f };
}

pub fn stringValue(allocator: Allocator, s: []const u8) anyerror!Self {
    const duped = try allocator.dupe(u8, s);
    return .{ .type = .string, .str_val = duped };
}

pub fn symValue(allocator: Allocator, s: []const u8) anyerror!Self {
    const duped = try allocator.dupe(u8, s);
    return .{ .type = .symbol, .sym_val = duped };
}

pub fn keywordValue(allocator: Allocator, s: []const u8) anyerror!Self {
    const duped = try allocator.dupe(u8, s);
    return .{ .type = .keyword, .kw_val = duped };
}

pub fn listValue(l: list.List) Self {
    return .{ .type = .list, .list_val = l };
}

pub fn vectorValue(v: vec.Vector) Self {
    return .{ .type = .vector, .vec_val = v };
}

pub fn fnValue(params: list.List, body: list.List, env: Env) Self {
    return .{ .type = .function, .fn_val = .{ .params = params, .body = body, .env = env } };
}

pub fn builtinFnValue(fn_ptr: BuiltinFn) Self {
    return .{ .type = .builtin_fn, .builtin_fn_val = fn_ptr };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    switch (self.type) {
        .nil, .bool, .integer, .float => {},
        .string => allocator.free(self.str_val),
        .symbol => allocator.free(self.sym_val),
        .keyword => allocator.free(self.kw_val),
        .list => self.list_val.deinit(allocator),
        .vector => self.vec_val.deinit(allocator),
        .function => {
            self.fn_val.params.deinit(allocator);
            self.fn_val.body.deinit(allocator);
            self.fn_val.env.deinit(allocator);
        },
        .builtin_fn => {},
    }
}

pub fn clone(self: *const Self, allocator: Allocator) anyerror!Self {
    switch (self.type) {
        .nil => return nilValue(),
        .bool => return boolValue(self.bool_val),
        .integer => return intValue(self.int_val),
        .float => return floatValue(self.float_val),
        .string => return stringValue(allocator, self.str_val),
        .symbol => return symValue(allocator, self.sym_val),
        .keyword => return keywordValue(allocator, self.kw_val),
        .list => return listValue(try self.list_val.clone(allocator)),
        .vector => return vectorValue(try self.vec_val.clone(allocator)),
        .function => {
            const fnv = self.fn_val;
            return fnValue(
                try fnv.params.clone(allocator),
                try fnv.body.clone(allocator),
                try fnv.env.clone(allocator),
            );
        },
        .builtin_fn => return builtinFnValue(self.builtin_fn_val),
    }
}

pub fn isTruthy(self: Self) bool {
    return switch (self.type) {
        .nil => false,
        .bool => self.bool_val,
        else => true,
    };
}

pub fn equals(self: Self, other: Self) bool {
    if (self.type != other.type) return false;
    switch (self.type) {
        .nil => return true,
        .bool => return self.bool_val == other.bool_val,
        .integer => return self.int_val == other.int_val,
        .float => return self.float_val == other.float_val,
        .string => return std.mem.eql(u8, self.str_val, other.str_val),
        .symbol => return std.mem.eql(u8, self.sym_val, other.sym_val),
        .keyword => return std.mem.eql(u8, self.kw_val, other.kw_val),
        else => return false,
    }
}

pub fn fmt(self: Self, allocator: Allocator) anyerror![]const u8 {
    return switch (self.type) {
        .nil => allocator.dupe(u8, "nil"),
        .bool => if (self.bool_val) allocator.dupe(u8, "true") else allocator.dupe(u8, "false"),
        .integer => try std.fmt.allocPrint(allocator, "{d}", .{self.int_val}),
        .float => try std.fmt.allocPrint(allocator, "{d}", .{self.float_val}),
        .string => try std.fmt.allocPrint(allocator, "\"{s}\"", .{self.str_val}),
        .symbol => allocator.dupe(u8, self.sym_val),
        .keyword => try std.fmt.allocPrint(allocator, ":{s}", .{self.kw_val}),
        .list => try list.fmt(self.list_val, allocator),
        .vector => try vec.fmt(self.vec_val, allocator),
        .function => allocator.dupe(u8, "#function"),
        .builtin_fn => allocator.dupe(u8, "#builtin"),
    };
}
