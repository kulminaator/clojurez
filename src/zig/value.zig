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
    map,
    set,
    queue,
    function,
    builtin_fn,
    lazy_seq,
    atom,
};

pub const MapEntry = struct {
    key: Self,
    value: Self,
};

pub const Map = std.ArrayListUnmanaged(MapEntry);

pub const Set = std.ArrayListUnmanaged(Self);

pub const Queue = std.ArrayListUnmanaged(Self);

pub const LazySeq = struct {
    thunk: ?*LazySeqThunk = null,
    // Note: no cache field to avoid circular dependency with Self
    // Once forced, the result is returned as a list and the lazy_seq is consumed
};

pub const LazySeqThunk = struct {
    params: list.List,
    body: list.List,
    env: Env,
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
map_val: Map = .empty,
set_val: Set = .empty,
queue_val: Queue = .empty,
fn_val: FnData = .{ .params = list.List.empty, .body = list.List.empty, .env = undefined, .rest_name = null },
builtin_fn_val: BuiltinFn = undefined,
lazy_seq_val: LazySeq = .{},
atom_val: ?*Self = null,

pub const FnData = struct {
    params: list.List,
    body: list.List,
    env: Env,
    rest_name: ?[]const u8 = null, // variadic rest parameter name (e.g., & args)
    is_macro: bool = false, // true if this is a macro (args passed unevaluated)
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
        // First ensure the put will succeed (may grow the hash map)
        // Then deinit the old value to avoid memory leaks
        errdefer {
            // If put fails after deinit, we can't recover the old value.
            // This is an OOM situation anyway.
        }
        const old_ptr = self.entries.getPtr(name);
        if (old_ptr) |old_val| {
            old_val.deinit(allocator);
        }
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
    // Validate UTF-8 encoding
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUTF8;
    const duped = try allocator.dupe(u8, s);
    return .{ .type = .string, .str_val = duped };
}

/// Count the number of Unicode code points in a UTF-8 string.
pub fn utf8CodepointCount(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        count += 1;
        i += len - 1;
    }
    return count;
}

/// Get the byte offset of the nth Unicode code point in a UTF-8 string.
/// Returns null if n is out of range.
pub fn utf8CodepointByteOffset(s: []const u8, n: usize) ?usize {
    var idx: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (idx == n) return i;
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        idx += 1;
        i += len - 1;
    }
    return null;
}

/// Extract a single code point as a string starting at byte index `start`.
pub fn utf8CodepointAt(s: []const u8, n: usize) ?[]const u8 {
    const start = utf8CodepointByteOffset(s, n) orelse return null;
    const seq_len = std.unicode.utf8ByteSequenceLength(s[start]) catch return null;
    if (start + seq_len > s.len) return null;
    return s[start .. start + seq_len];
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

pub fn mapValue(m: Map) Self {
    return .{ .type = .map, .map_val = m };
}

pub fn setValue(s: Set) Self {
    return .{ .type = .set, .set_val = s };
}

pub fn queueValue(q: Queue) Self {
    return .{ .type = .queue, .queue_val = q };
}

pub fn atomValue(allocator: Allocator, initial: Self) anyerror!Self {
    const val = try allocator.create(Self);
    val.* = try initial.clone(allocator);
    return .{ .type = .atom, .atom_val = val };
}

pub fn atomValueShared(ptr: *Self) Self {
    return .{ .type = .atom, .atom_val = ptr };
}

pub fn lazySeqValue(thunk: ?*LazySeqThunk) Self {
    return .{ .type = .lazy_seq, .lazy_seq_val = .{ .thunk = thunk } };
}

pub fn fnValue(params: list.List, body: list.List, env: Env, rest_name: ?[]const u8, is_macro: bool) Self {
    return .{ .type = .function, .fn_val = .{ .params = params, .body = body, .env = env, .rest_name = rest_name, .is_macro = is_macro } };
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
        .map => {
            for (self.map_val.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(self.map_val.items);
        },
        .set => {
            for (self.set_val.items) |*item| {
                item.deinit(allocator);
            }
            allocator.free(self.set_val.items);
        },
        .queue => {
            for (self.queue_val.items) |*item| {
                item.deinit(allocator);
            }
            allocator.free(self.queue_val.items);
        },
        .lazy_seq => {
            if (self.lazy_seq_val.thunk) |thunk| {
                thunk.params.deinit(allocator);
                thunk.body.deinit(allocator);
                thunk.env.deinit(allocator);
                allocator.destroy(thunk);
            }
        },
        .function => {
            self.fn_val.params.deinit(allocator);
            self.fn_val.body.deinit(allocator);
            self.fn_val.env.deinit(allocator);
            if (self.fn_val.rest_name) |rn| {
                allocator.free(rn);
            }
        },
        .builtin_fn => {},
        .atom => {
            // Don't deinit inner value — atoms share pointers via clone.
            // The arena allocator in main will clean up everything.
            // Only destroy the pointer itself if this is the owner.
            _ = self.atom_val;
        },
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
        .map => {
            var new_map: Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(new_map.items);
            }
            try new_map.ensureTotalCapacity(allocator, self.map_val.items.len);
            for (self.map_val.items) |entry| {
                try new_map.append(allocator, .{
                    .key = try entry.key.clone(allocator),
                    .value = try entry.value.clone(allocator),
                });
            }
            return mapValue(new_map);
        },
        .set => {
            var new_set: Set = .empty;
            errdefer {
                for (new_set.items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(new_set.items);
            }
            try new_set.ensureTotalCapacity(allocator, self.set_val.items.len);
            for (self.set_val.items) |item| {
                try new_set.append(allocator, try item.clone(allocator));
            }
            return setValue(new_set);
        },
        .queue => {
            var new_queue: Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(new_queue.items);
            }
            try new_queue.ensureTotalCapacity(allocator, self.queue_val.items.len);
            for (self.queue_val.items) |item| {
                try new_queue.append(allocator, try item.clone(allocator));
            }
            return queueValue(new_queue);
        },
        .lazy_seq => {
            var new_lazy: LazySeq = .{};
            if (self.lazy_seq_val.thunk) |thunk| {
                const new_thunk = try allocator.create(LazySeqThunk);
                new_thunk.* = .{
                    .params = try thunk.params.clone(allocator),
                    .body = try thunk.body.clone(allocator),
                    .env = try thunk.env.clone(allocator),
                };
                new_lazy.thunk = new_thunk;
            }
            return lazySeqValue(new_lazy.thunk);
        },
        .atom => {
            // Clone atom by sharing the same pointer (atoms are identity-based)
            if (self.atom_val) |val| {
                return atomValueShared(val);
            }
            return nilValue();
        },
        .function => {
            const fnv = self.fn_val;
            var cloned_rest: ?[]const u8 = null;
            if (fnv.rest_name) |rn| {
                cloned_rest = try allocator.dupe(u8, rn);
            }
            return fnValue(
                try fnv.params.clone(allocator),
                try fnv.body.clone(allocator),
                try fnv.env.clone(allocator),
                cloned_rest,
                fnv.is_macro,
            );
        },
        .builtin_fn => return builtinFnValue(self.builtin_fn_val),
    }
}

pub fn isTruthy(self: Self) bool {
    return switch (self.type) {
        .nil => false,
        .bool => self.bool_val,
        .atom => {
            if (self.atom_val) |val| return val.isTruthy();
            return false;
        },
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
        .map => {
            if (self.map_val.items.len != other.map_val.items.len) return false;
            for (self.map_val.items, 0..) |entry, i| {
                const other_entry = other.map_val.items[i];
                if (!entry.key.equals(other_entry.key) or !entry.value.equals(other_entry.value)) return false;
            }
            return true;
        },
        .set => {
            if (self.set_val.items.len != other.set_val.items.len) return false;
            for (self.set_val.items) |item| {
                var found = false;
                for (other.set_val.items) |other_item| {
                    if (item.equals(other_item)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
        .queue => {
            if (self.queue_val.items.len != other.queue_val.items.len) return false;
            for (self.queue_val.items, 0..) |item, i| {
                if (!item.equals(other.queue_val.items[i])) return false;
            }
            return true;
        },
        .atom => {
            // Atoms are never equal by identity
            return false;
        },
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
        .map => try mapFmt(self.map_val, allocator),
        .set => try setFmt(self.set_val, allocator),
        .queue => try queueFmt(self.queue_val, allocator),
        .function => allocator.dupe(u8, "#function"),
        .builtin_fn => allocator.dupe(u8, "#builtin"),
        .lazy_seq => allocator.dupe(u8, "#lazy-seq"),
        .atom => {
            if (self.atom_val) |val| {
                const inner_str = try val.fmt(allocator);
                defer allocator.free(inner_str);
                return try std.fmt.allocPrint(allocator, "#atom({s})", .{inner_str});
            }
            return allocator.dupe(u8, "#atom(nil)");
        },
    };
}

pub fn setFmt(s: Set, allocator: Allocator) anyerror![]const u8 {
    if (s.items.len == 0) return allocator.dupe(u8, "#{}");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '#');
    try buf.append(allocator, '{');
    for (s.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const s_str = try item.fmt(allocator);
        defer allocator.free(s_str);
        try buf.appendSlice(allocator, s_str);
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

pub fn queueFmt(q: Queue, allocator: Allocator) anyerror![]const u8 {
    if (q.items.len == 0) return allocator.dupe(u8, "#queue()");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "#queue(");
    for (q.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const s_str = try item.fmt(allocator);
        defer allocator.free(s_str);
        try buf.appendSlice(allocator, s_str);
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

pub fn mapFmt(m: Map, allocator: Allocator) anyerror![]const u8 {
    if (m.items.len == 0) return allocator.dupe(u8, "{}");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    for (m.items, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const key_s = try entry.key.fmt(allocator);
        defer allocator.free(key_s);
        const val_s = try entry.value.fmt(allocator);
        defer allocator.free(val_s);
        try buf.appendSlice(allocator, key_s);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, val_s);
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}
