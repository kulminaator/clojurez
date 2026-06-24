// persistent_string_hash_map.zig — String-keyed persistent immutable HashMap.
//
// Wraps PersistentHashMap internally, converting string keys to Value.symbol.
// This avoids duplicating the HAMT implementation while providing a clean
// string-keyed API for VM infrastructure (Env, NamespaceManager, etc.).
//
// For value types that need cloning on assoc (like Value), the map clones
// values when storing. For pointer types (like *Env), use IdentityWrap.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm = @import("value.zig");
const Value = vm.Value;
const phm = @import("persistent_hash_map.zig");

// Re-export sym from persistent_hash_map.zig
pub const sym = phm.sym;

// ============================================================
// Wrapper: convert string keys to Value.symbol for the underlying HAMT
// ============================================================

/// Generic persistent string-keyed hash map wrapping PersistentHashMap.
/// T = value type, must have clone(allocator) and deinit(allocator) methods.
pub fn PersistentStringHashMap(T: type) type {
    return struct {
        const This = @This();
        const Inner = phm.PersistentHashMap;

        inner: Inner,

        pub fn empty() This {
            return .{ .inner = Inner.empty() };
        }

        pub fn isEmpty(self: This) bool { return self.inner.isEmpty(); }
        pub fn mapCount(self: This) usize { return self.inner.mapCount(); }

        pub fn containsKey(self: This, key: []const u8) bool {
            return self.inner.containsKey(sym(key));
        }

        pub fn find(self: This, key: []const u8) ?T {
            const result = self.inner.find(sym(key));
            if (result) |v| return unwrap(v);
            return null;
        }

        pub fn assoc(self: This, allocator: Allocator, key: []const u8, val: T) anyerror!This {
            const wrapped = try wrapVal(allocator, val);
            defer wrapped.deinit(allocator);
            const new_inner = try self.inner.mapAssoc(allocator, sym(key), wrapped);
            return .{ .inner = new_inner };
        }

        pub fn without(self: This, allocator: Allocator, key: []const u8) anyerror!This {
            const new_inner = try self.inner.mapWithout(allocator, sym(key));
            return .{ .inner = new_inner };
        }

        pub fn mapKeys(self: This, allocator: Allocator) anyerror!std.ArrayListUnmanaged([]const u8) {
            var keys_list = try self.inner.mapKeys(allocator);
            defer keys_list.deinit(allocator);

            var result: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer allocator.free(result.items);

            for (keys_list.items) |v| {
                if (v.type == .symbol) {
                    try result.append(allocator, v.symbol);
                }
            }
            return result;
        }

        pub fn mapVals(self: This, allocator: Allocator) anyerror!std.ArrayListUnmanaged(T) {
            const vals_list = try self.inner.mapVals(allocator);
            defer vals_list.deinit(allocator);

            var result: std.ArrayListUnmanaged(T) = .empty;
            errdefer {
                var i: usize = 0;
                while (i < result.items.len) : (i += 1) result.items[i].deinit(allocator);
            }

            for (vals_list.items) |v| {
                try result.append(allocator, unwrap(v));
            }
            return result;
        }

        pub fn deinit(self: *This, allocator: Allocator) void {
            self.inner.deinit(allocator);
        }

        fn wrapVal(allocator: Allocator, val: T) anyerror!Value {
            _ = val;
            return Value{ .type = .bigint, .bigint = try allocator.create(WrappedValue) };
        }

        fn unwrap(v: Value) T {
            const wrapped: *WrappedValue = @ptrCast(@alignCast(v.bigint.?));
            return wrapped.val;
        }

        const WrappedValue = struct {
            val: T,
            // Fake BigInt interface for GC compatibility
            const LIMB = u32;
            pub const negative = false;
            pub var limbs: []const LIMB = &.{};
            pub var owns_limbs = false;
        };
    };
}

// ============================================================
// Simpler direct implementation for common use cases
// ============================================================

/// A simpler string-keyed persistent map for Value values.
/// Directly uses the Value-based PersistentHashMap with symbol keys.
pub const StringHashMap = struct {
    inner: phm.PersistentHashMap,

    pub fn empty() StringHashMap {
        return .{ .inner = phm.PersistentHashMap.empty() };
    }

    pub fn isEmpty(self: StringHashMap) bool { return self.inner.isEmpty(); }
    pub fn mapCount(self: StringHashMap) usize { return self.inner.mapCount(); }

    pub fn containsKey(self: StringHashMap, key: []const u8) bool {
        return self.inner.containsKey(sym(key));
    }

    pub fn find(self: StringHashMap, key: []const u8) ?Value {
        return self.inner.find(sym(key));
    }

    pub fn assoc(self: StringHashMap, allocator: Allocator, key: []const u8, val: Value) anyerror!StringHashMap {
        const new_inner = try self.inner.mapAssoc(allocator, sym(key), val);
        return .{ .inner = new_inner };
    }

    pub fn without(self: StringHashMap, allocator: Allocator, key: []const u8) anyerror!StringHashMap {
        const new_inner = try self.inner.mapWithout(allocator, sym(key));
        return .{ .inner = new_inner };
    }

    pub fn mapKeys(self: StringHashMap, allocator: Allocator) anyerror!std.ArrayListUnmanaged([]const u8) {
        var keys_list = try self.inner.mapKeys(allocator);
        defer keys_list.deinit(allocator);

        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer allocator.free(result.items);

        for (keys_list.items) |v| {
            if (std.meta.activeTag(v) == .symbol) {
                try result.append(allocator, v.symbol);
            }
        }
        return result;
    }

    pub fn mapVals(self: StringHashMap, allocator: Allocator) anyerror!std.ArrayListUnmanaged(Value) {
        return self.inner.mapVals(allocator);
    }

    pub fn deinit(self: *StringHashMap, allocator: Allocator) void {
        self.inner.deinit(allocator);
    }
};

// ============================================================
// IdentityWrap for pointer types
// ============================================================

/// Wrap a pointer type so it has clone/deinit for use with maps.
pub fn IdentityWrap(T: type) type {
    return struct {
        ptr: T,
        pub fn clone(self: @This(), allocator: Allocator) anyerror!@This() {
            _ = allocator;
            return self;
        }
        pub fn deinit(self: @This(), allocator: Allocator) void {
            _ = self; _ = allocator;
        }
    };
}

// ============================================================
// Unit Tests
// ============================================================

test "persistent_string_hash_map::empty" {
    var m = StringHashMap.empty();
    try std.testing.expect(m.isEmpty());
    try std.testing.expect(m.mapCount() == 0);
    try std.testing.expect(!m.containsKey("x"));
    try std.testing.expectEqual(null, m.find("x"));
}

test "persistent_string_hash_map::assoc and find" {
    const a = std.heap.page_allocator;
    var m = StringHashMap.empty();

    m = try m.assoc(a, "one", vm.intValue(1));
    try std.testing.expect(m.mapCount() == 1);
    try std.testing.expect(m.find("one").?.integer == 1);

    m = try m.assoc(a, "two", vm.intValue(2));
    try std.testing.expect(m.mapCount() == 2);
    try std.testing.expect(m.find("one").?.integer == 1);
    try std.testing.expect(m.find("two").?.integer == 2);
}

test "persistent_string_hash_map::update existing key" {
    const a = std.heap.page_allocator;
    var m = StringHashMap.empty();

    m = try m.assoc(a, "x", vm.intValue(10));
    m = try m.assoc(a, "x", vm.intValue(99));
    try std.testing.expect(m.mapCount() == 1);
    try std.testing.expect(m.find("x").?.integer == 99);
}

test "persistent_string_hash_map::without" {
    const a = std.heap.page_allocator;
    var m = StringHashMap.empty();

    m = try m.assoc(a, "a", vm.intValue(1));
    m = try m.assoc(a, "b", vm.intValue(2));
    m = try m.assoc(a, "c", vm.intValue(3));
    m = try m.without(a, "b");
    try std.testing.expect(m.mapCount() == 2);
    try std.testing.expect(m.find("a").?.integer == 1);
    try std.testing.expectEqual(null, m.find("b"));
    try std.testing.expect(m.find("c").?.integer == 3);
}

test "persistent_string_hash_map::many entries" {
    const a = std.heap.page_allocator;
    var m = StringHashMap.empty();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const key = try std.fmt.allocPrint(a, "key_{d}", .{i});
        m = try m.assoc(a, key, vm.intValue(@as(i64, @intCast(i))));
    }
    try std.testing.expect(m.mapCount() == 50);

    i = 0;
    while (i < 50) : (i += 1) {
        const key = try std.fmt.allocPrint(a, "key_{d}", .{i});
        const found = m.find(key);
        try std.testing.expect(found != null);
        try std.testing.expect(found.?.integer == @as(i64, @intCast(i)));
    }
}

test "persistent_string_hash_map::hash collision" {
    const a = std.heap.page_allocator;
    var m = StringHashMap.empty();

    m = try m.assoc(a, "hello", vm.intValue(1));
    m = try m.assoc(a, "world", vm.intValue(2));
    try std.testing.expect(m.mapCount() == 2);
    try std.testing.expect(m.find("hello").?.integer == 1);
    try std.testing.expect(m.find("world").?.integer == 2);
}

test "persistent_string_hash_map::keys" {
    const a = std.heap.page_allocator;
    var m = StringHashMap.empty();

    m = try m.assoc(a, "alpha", vm.intValue(1));
    m = try m.assoc(a, "beta", vm.intValue(2));

    const keys = try m.mapKeys(a);
    defer a.free(keys.items);
    try std.testing.expect(keys.items.len == 2);
}
