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

// Ref-counted atom data for proper shared ownership
pub const AtomData = struct {
    value: Self,
    ref_count: usize = 1,
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
fn_val: FnData = .{ .arities = .empty, .env = undefined },
builtin_fn_val: BuiltinFn = undefined,
lazy_seq_val: LazySeq = .{},
atom_val: ?*AtomData = null,

// Single arity: one [params] + body forms + optional rest param
pub const Arity = struct {
    params: list.List,
    body: list.List,
    rest_name: ?[]const u8 = null, // variadic rest parameter name (e.g., & args)
};

pub const FnData = struct {
    arities: std.ArrayListUnmanaged(Arity) = .empty, // multi-arity support
    env: Env,
    is_macro: bool = false, // true if this is a macro (args passed unevaluated)
};

/// Namespace manager: tracks all namespaces, current namespace, and aliases.
/// Only the root env holds a non-null pointer to this.
pub const NamespaceManager = struct {
    allocator: Allocator,
    /// Maps namespace name → Env pointer for that namespace
    namespaces: std.StringArrayHashMapUnmanaged(*Env) = .empty,
    /// Current namespace name (owned string)
    current_ns: []const u8 = "user",
    /// Maps namespace name → (alias name → target namespace name)
    aliases: std.StringArrayHashMapUnmanaged(NamespaceAliases) = .empty,
    /// Classpath directories for loading .clj files
    classpath: std.ArrayListUnmanaged([]const u8) = .empty,

    const NamespaceAliases = std.StringArrayHashMapUnmanaged([]const u8);

    pub fn init(allocator: Allocator) anyerror!*NamespaceManager {
        const mgr = try allocator.create(NamespaceManager);
        mgr.* = .{ .allocator = allocator };
        // Create default "user" namespace
        _ = try mgr.createNamespace("user");
        return mgr;
    }

    pub fn deinit(self: *NamespaceManager) void {
        const allocator = self.allocator;
        // Free namespace envs (but don't deinit their entries — they're managed by caller)
        self.namespaces.deinit(allocator);
        // Free alias maps
        var ait = self.aliases.iterator();
        while (ait.next()) |entry| {
            var nit = entry.value_ptr.iterator();
            while (nit.next()) |nentry| {
                allocator.free(nentry.key_ptr.*);
            }
            entry.value_ptr.deinit(allocator);
        }
        self.aliases.deinit(allocator);
        // Free classpath entries
        for (self.classpath.items) |dir| {
            allocator.free(dir);
        }
        allocator.free(self.classpath.items);
        allocator.free(self.current_ns);
        allocator.destroy(self);
    }

    /// Create a namespace (or return existing). Returns the namespace's Env.
    pub fn createNamespace(self: *NamespaceManager, name: []const u8) anyerror!*Env {
        // Check if already exists
        if (self.namespaces.get(name)) |existing| return existing;

        // Create new env with parent = null (will be set by caller to root env)
        const ns_env = try self.allocator.create(Env);
        ns_env.* = Env.init(self.allocator);
        // ns_env.parent is set by caller
        try self.namespaces.put(self.allocator, try self.allocator.dupe(u8, name), ns_env);
        return ns_env;
    }

    /// Get the Env for a namespace (must already exist).
    pub fn getNamespace(self: *NamespaceManager, name: []const u8) ?*Env {
        return self.namespaces.get(name);
    }

    /// Set the current namespace.
    pub fn setCurrentNamespace(self: *NamespaceManager, name: []const u8) anyerror!void {
        const new_ns = try self.allocator.dupe(u8, name);
        self.allocator.free(self.current_ns);
        self.current_ns = new_ns;
    }

    /// Get the current namespace name.
    pub fn getCurrentNamespace(self: *const NamespaceManager) []const u8 {
        return self.current_ns;
    }

    /// Register an alias in a namespace: alias_name → target_ns_name
    pub fn addAlias(self: *NamespaceManager, ns_name: []const u8, alias: []const u8, target: []const u8) anyerror!void {
        var alias_map = self.aliases.getPtr(ns_name);
        if (alias_map == null) {
            // Create a new alias map and store it
            var new_map: NamespaceAliases = .empty;
            try new_map.put(self.allocator, try self.allocator.dupe(u8, alias), try self.allocator.dupe(u8, target));
            try self.aliases.put(self.allocator, try self.allocator.dupe(u8, ns_name), new_map);
            return;
        }
        const owned_target = try self.allocator.dupe(u8, target);
        try alias_map.?.put(self.allocator, try self.allocator.dupe(u8, alias), owned_target);
    }

    /// Resolve an alias in a namespace. Returns the target namespace name, or null.
    pub fn resolveAlias(self: *const NamespaceManager, ns_name: []const u8, alias: []const u8) ?[]const u8 {
        const alias_map = self.aliases.get(ns_name) orelse return null;
        return alias_map.get(alias);
    }

    /// Add a directory to the classpath.
    pub fn addClasspath(self: *NamespaceManager, dir: []const u8) anyerror!void {
        const owned = try self.allocator.dupe(u8, dir);
        try self.classpath.append(self.allocator, owned);
    }

    /// Resolve a namespace name to a file path on the classpath.
    /// E.g., "hello.hello" → "hello/hello.clj"
    /// Searches each classpath directory and returns the first match.
    pub fn resolveNamespaceToPath(self: *const NamespaceManager, allocator: Allocator, ns_name: []const u8) anyerror!?[]const u8 {
        // Convert namespace name to file path: dots → slashes + ".clj"
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(allocator);
        for (ns_name) |c| {
            if (c == '.') {
                try path_buf.append(allocator, '/');
            } else {
                try path_buf.append(allocator, c);
            }
        }
        try path_buf.appendSlice(allocator, ".clj");
        const file_path = path_buf.items;

        // Search each classpath directory
        for (self.classpath.items) |cp_dir| {
            var full_path: std.ArrayList(u8) = .empty;
            errdefer full_path.deinit(allocator);
            try full_path.appendSlice(allocator, cp_dir);
            // Ensure trailing slash
            if (cp_dir.len > 0 and cp_dir[cp_dir.len - 1] != '/') {
                try full_path.append(allocator, '/');
            }
            try full_path.appendSlice(allocator, file_path);

            // Check if file exists
            const cwd = std.Io.Dir.cwd();
            const test_file = std.Io.Dir.openFile(cwd, std.Options.debug_io, full_path.items, .{}) catch continue;
            std.Io.File.close(test_file, std.Options.debug_io);
            const result: []const u8 = try full_path.toOwnedSlice(allocator);
            return result;
        }

        return null;
    }
};

pub const Env = struct {
    allocator: Allocator,
    entries: std.StringArrayHashMapUnmanaged(Self) = .empty,
    parent: ?*Env = null,
    /// Pointer to namespace manager (only set on root env, inherited via parent chain)
    ns_manager: ?*NamespaceManager = null,

    pub fn init(allocator: Allocator) Env {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .parent = null,
            .ns_manager = null,
        };
    }

    pub fn deinit(self: *Env, allocator: Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit(allocator);
        _ = self.parent; // Don't deinit parent here; it's managed separately
        _ = self.ns_manager; // Don't deinit ns_manager here
    }

    pub fn clone(self: *const Env, allocator: Allocator) anyerror!Env {
        var new_env: Env = .{
            .allocator = allocator,
            .entries = .empty,
            .parent = self.parent,
            .ns_manager = self.ns_manager,
        };
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const cloned_val = try entry.value_ptr.clone(allocator);
            try new_env.entries.put(allocator, entry.key_ptr.*, cloned_val);
        }
        return new_env;
    }

    pub fn put(self: *Env, name: []const u8, value: Self) anyerror!void {
        // Uses self.allocator for all allocations.
        // StringArrayHashMapUnmanaged stores key POINTERS (not copies),
        // so we must dupe the key to self.allocator to ensure it outlives
        // any temporary arena where the original may have been allocated.
        const allocator = self.allocator;

        // Deinit old value if key exists
        const existing = self.entries.getPtr(name);
        if (existing) |old_val| {
            old_val.deinit(allocator);
        }

        // Dupe key to main allocator (StringArrayHashMap stores pointers)
        const owned_key = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_key);

        if (existing) |_| {
            // Key exists: update value in-place, replace key pointer
            // Find the entry by iterating
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                    entry.key_ptr.* = owned_key;
                    entry.value_ptr.* = value;
                    return;
                }
            }
            // Should not reach here, but fall through to put as fallback
        }

        try self.entries.put(allocator, owned_key, value);
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
    const data = try allocator.create(AtomData);
    data.* = .{ .value = try initial.clone(allocator), .ref_count = 1 };
    return .{ .type = .atom, .atom_val = data };
}

pub fn atomValueShared(data: *AtomData) Self {
    data.ref_count += 1;
    return .{ .type = .atom, .atom_val = data };
}

pub fn lazySeqValue(thunk: ?*LazySeqThunk) Self {
    return .{ .type = .lazy_seq, .lazy_seq_val = .{ .thunk = thunk } };
}

pub fn fnValue(arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool) Self {
    return .{ .type = .function, .fn_val = .{ .arities = arities, .env = env, .is_macro = is_macro } };
}

/// Create a single-arity function (convenience wrapper)
pub fn fnValueSingle(allocator: Allocator, params: list.List, body: list.List, env: Env, rest_name: ?[]const u8, is_macro: bool) anyerror!Self {
    var arities: std.ArrayListUnmanaged(Arity) = .empty;
    errdefer allocator.free(arities.items);
    try arities.append(allocator, Arity{ .params = params, .body = body, .rest_name = rest_name });
    return fnValue(arities, env, is_macro);
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
                // Use the allocator from the thunk's environment to properly free
                // the thunk (which may have been allocated with a different allocator)
                const thunk_allocator = thunk.env.allocator;
                thunk.params.deinit(thunk_allocator);
                thunk.body.deinit(thunk_allocator);
                thunk.env.deinit(thunk_allocator);
                thunk_allocator.destroy(thunk);
            }
        },
        .function => {
            for (self.fn_val.arities.items) |*arity| {
                arity.params.deinit(allocator);
                arity.body.deinit(allocator);
                if (arity.rest_name) |rn| {
                    allocator.free(rn);
                }
            }
            allocator.free(self.fn_val.arities.items);
            self.fn_val.env.deinit(allocator);
        },
        .builtin_fn => {},
        .atom => {
            // Ref-counted: decrement and free when last reference is gone
            if (self.atom_val) |data| {
                data.ref_count -= 1;
                if (data.ref_count == 0) {
                    data.value.deinit(allocator);
                    allocator.destroy(data);
                }
            }
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
        .list => return listValue(try list.clone(&self.list_val, allocator)),
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
                    .params = try list.clone(&thunk.params, allocator),
                    .body = try list.clone(&thunk.body, allocator),
                    .env = try thunk.env.clone(allocator),
                };
                new_lazy.thunk = new_thunk;
            }
            return lazySeqValue(new_lazy.thunk);
        },
        .atom => {
            // Clone atom by sharing the same AtomData (atoms are identity-based)
            if (self.atom_val) |data| {
                return atomValueShared(data);
            }
            return nilValue();
        },
        .function => {
            const fnv = self.fn_val;
            var cloned_arities: std.ArrayListUnmanaged(Arity) = .empty;
            errdefer {
                for (cloned_arities.items) |*ca| {
                    ca.params.deinit(allocator);
                    ca.body.deinit(allocator);
                    if (ca.rest_name) |rn| allocator.free(rn);
                }
                allocator.free(cloned_arities.items);
            }
            try cloned_arities.ensureTotalCapacity(allocator, fnv.arities.items.len);
            for (fnv.arities.items) |arity| {
                var cloned_rest: ?[]const u8 = null;
                if (arity.rest_name) |rn| {
                    cloned_rest = try allocator.dupe(u8, rn);
                }
                try cloned_arities.append(allocator, Arity{
                    .params = try list.clone(&arity.params, allocator),
                    .body = try list.clone(&arity.body, allocator),
                    .rest_name = cloned_rest,
                });
            }
            return fnValue(cloned_arities, try fnv.env.clone(allocator), fnv.is_macro);
        },
        .builtin_fn => return builtinFnValue(self.builtin_fn_val),
    }
}

pub fn isTruthy(self: Self) bool {
    return switch (self.type) {
        .nil => false,
        .bool => self.bool_val,
        .atom => {
            if (self.atom_val) |data| return data.value.isTruthy();
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
            if (self.atom_val) |data| {
                const inner_str = try data.value.fmt(allocator);
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

// ===== Unit Tests =====

test "value::intValue: creates integer value" {
    const v = intValue(42);
    try std.testing.expect(v.type == .integer);
    try std.testing.expect(v.int_val == 42);
}

test "value::floatValue: creates float value" {
    const v = floatValue(3.14);
    try std.testing.expect(v.type == .float);
    try std.testing.expect(v.float_val == 3.14);
}

test "value::boolValue: true and false" {
    const t = boolValue(true);
    try std.testing.expect(t.type == .bool);
    try std.testing.expect(t.bool_val);
    const f = boolValue(false);
    try std.testing.expect(f.type == .bool);
    try std.testing.expect(!f.bool_val);
}

test "value::nilValue: creates nil" {
    const v = nilValue();
    try std.testing.expect(v.type == .nil);
}

test "value::stringValue: creates string" {
    const a = std.heap.page_allocator;
    var v = try stringValue(a, "hello");
    defer v.deinit(a);
    try std.testing.expect(v.type == .string);
    try std.testing.expect(std.mem.eql(u8, v.str_val, "hello"));
}

test "value::stringValue: rejects invalid UTF-8" {
    const a = std.heap.page_allocator;
    const invalid: []const u8 = &[_]u8{ 0xFF, 0xFF };
    try std.testing.expectError(error.InvalidUTF8, stringValue(a, invalid));
}

test "value::symValue: creates symbol" {
    const a = std.heap.page_allocator;
    var v = try symValue(a, "foo-bar");
    defer v.deinit(a);
    try std.testing.expect(v.type == .symbol);
    try std.testing.expect(std.mem.eql(u8, v.sym_val, "foo-bar"));
}

test "value::keywordValue: creates keyword" {
    const a = std.heap.page_allocator;
    var v = try keywordValue(a, "foo");
    defer v.deinit(a);
    try std.testing.expect(v.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, v.kw_val, "foo"));
}

test "value::isTruthy: nil is falsy" {
    try std.testing.expect(!nilValue().isTruthy());
}

test "value::isTruthy: false is falsy" {
    try std.testing.expect(!boolValue(false).isTruthy());
}

test "value::isTruthy: true is truthy" {
    try std.testing.expect(boolValue(true).isTruthy());
}

test "value::isTruthy: numbers are truthy" {
    try std.testing.expect(intValue(0).isTruthy());
    try std.testing.expect(intValue(42).isTruthy());
    try std.testing.expect(floatValue(0.0).isTruthy());
}

test "value::equals: integers" {
    try std.testing.expect(intValue(5).equals(intValue(5)));
    try std.testing.expect(!intValue(5).equals(intValue(6)));
    try std.testing.expect(!intValue(5).equals(floatValue(5.0)));
}

test "value::equals: booleans" {
    try std.testing.expect(boolValue(true).equals(boolValue(true)));
    try std.testing.expect(!boolValue(true).equals(boolValue(false)));
    try std.testing.expect(!boolValue(true).equals(nilValue()));
}

test "value::equals: nils" {
    try std.testing.expect(nilValue().equals(nilValue()));
}

test "value::equals: floats" {
    try std.testing.expect(floatValue(1.5).equals(floatValue(1.5)));
    try std.testing.expect(!floatValue(1.5).equals(floatValue(2.0)));
}

test "value::equals: sets (order independent)" {
    const a = std.heap.page_allocator;

    var s1: Set = .empty;
    try s1.append(a, intValue(1));
    try s1.append(a, intValue(2));
    var v1 = setValue(s1);

    var s2: Set = .empty;
    try s2.append(a, intValue(2));
    try s2.append(a, intValue(1));
    var v2 = setValue(s2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));
}

test "value::equals: maps (order dependent)" {
    const a = std.heap.page_allocator;

    var m1: Map = .empty;
    try m1.append(a, .{ .key = intValue(1), .value = intValue(10) });
    try m1.append(a, .{ .key = intValue(2), .value = intValue(20) });
    var v1 = mapValue(m1);

    var m2: Map = .empty;
    try m2.append(a, .{ .key = intValue(1), .value = intValue(10) });
    try m2.append(a, .{ .key = intValue(2), .value = intValue(20) });
    var v2 = mapValue(m2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));

    var m3: Map = .empty;
    try m3.append(a, .{ .key = intValue(1), .value = intValue(99) });
    var v3 = mapValue(m3);
    defer v3.deinit(a);

    try std.testing.expect(!v1.equals(v3));
}

test "value::equals: queues" {
    const a = std.heap.page_allocator;

    var q1: Queue = .empty;
    try q1.append(a, intValue(1));
    try q1.append(a, intValue(2));
    var v1 = queueValue(q1);

    var q2: Queue = .empty;
    try q2.append(a, intValue(1));
    try q2.append(a, intValue(2));
    var v2 = queueValue(q2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));

    var q3: Queue = .empty;
    try q3.append(a, intValue(2));
    try q3.append(a, intValue(1));
    var v3 = queueValue(q3);
    defer v3.deinit(a);

    try std.testing.expect(!v1.equals(v3));
}

test "value::utf8CodepointCount: ASCII" {
    try std.testing.expect(utf8CodepointCount("hello") == 5);
    try std.testing.expect(utf8CodepointCount("") == 0);
    try std.testing.expect(utf8CodepointCount("a") == 1);
}

test "value::utf8CodepointCount: multi-byte UTF-8" {
    try std.testing.expect(utf8CodepointCount("õäö") == 3);
    try std.testing.expect(utf8CodepointCount("😀") == 1);
    try std.testing.expect(utf8CodepointCount("古池や") == 3);
}

test "value::utf8CodepointByteOffset: ASCII" {
    try std.testing.expect(utf8CodepointByteOffset("hello", 0).? == 0);
    try std.testing.expect(utf8CodepointByteOffset("hello", 2).? == 2);
    try std.testing.expect(utf8CodepointByteOffset("hello", 4).? == 4);
    try std.testing.expect(utf8CodepointByteOffset("hello", 5) == null);
}

test "value::utf8CodepointByteOffset: multi-byte UTF-8" {
    try std.testing.expect(utf8CodepointByteOffset("õäö", 0).? == 0);
    try std.testing.expect(utf8CodepointByteOffset("õäö", 1).? == 2);
    try std.testing.expect(utf8CodepointByteOffset("õäö", 2).? == 4);
    try std.testing.expect(utf8CodepointByteOffset("õäö", 3) == null);
}

test "value::utf8CodepointAt: ASCII" {
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("hello", 0).?, "h"));
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("hello", 4).?, "o"));
    try std.testing.expect(utf8CodepointAt("hello", 5) == null);
}

test "value::utf8CodepointAt: multi-byte UTF-8" {
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("õäö", 0).?, "õ"));
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("õäö", 1).?, "ä"));
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("õäö", 2).?, "ö"));
    try std.testing.expect(utf8CodepointAt("õäö", 3) == null);
}

test "value::clone: integer" {
    const a = std.heap.page_allocator;
    const v = intValue(42);
    const c = try v.clone(a);
    try std.testing.expect(c.type == .integer);
    try std.testing.expect(c.int_val == 42);
}

test "value::clone: string round-trip" {
    const a = std.heap.page_allocator;
    var v = try stringValue(a, "test");
    var c = try v.clone(a);
    defer v.deinit(a);
    defer c.deinit(a);
    try std.testing.expect(std.mem.eql(u8, c.str_val, "test"));
}

test "value::clone: atom shares data" {
    const a = std.heap.page_allocator;
    const init = intValue(42);
    var v = try atomValue(a, init);
    var c = try v.clone(a);
    defer v.deinit(a);
    defer c.deinit(a);
    try std.testing.expect(v.atom_val == c.atom_val);
}

test "value::atomValue: ref count is 1" {
    const a = std.heap.page_allocator;
    const init = intValue(42);
    var v = try atomValue(a, init);
    defer v.deinit(a);
    try std.testing.expect(v.atom_val.?.ref_count == 1);
}

test "value::atomValueShared: increments ref count" {
    const a = std.heap.page_allocator;
    const init = intValue(42);
    var v = try atomValue(a, init);
    const data = v.atom_val.?;
    var shared = atomValueShared(data);
    defer v.deinit(a);
    defer shared.deinit(a);
    try std.testing.expect(data.ref_count == 2);
}

test "value::fmt: nil" {
    const a = std.heap.page_allocator;
    const s = try nilValue().fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "nil"));
}

test "value::fmt: bool" {
    const a = std.heap.page_allocator;
    const s1 = try boolValue(true).fmt(a);
    defer a.free(s1);
    try std.testing.expect(std.mem.eql(u8, s1, "true"));
    const s2 = try boolValue(false).fmt(a);
    defer a.free(s2);
    try std.testing.expect(std.mem.eql(u8, s2, "false"));
}

test "value::fmt: integer" {
    const a = std.heap.page_allocator;
    const s = try intValue(42).fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "42"));
}

test "value::fmt: string" {
    const a = std.heap.page_allocator;
    var v = try stringValue(a, "hello");
    defer v.deinit(a);
    const s = try v.fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\"hello\""));
}

test "value::fmt: keyword" {
    const a = std.heap.page_allocator;
    var v = try keywordValue(a, "foo");
    defer v.deinit(a);
    const s = try v.fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, ":foo"));
}

test "value::fmt: symbol" {
    const a = std.heap.page_allocator;
    var v = try symValue(a, "x");
    defer v.deinit(a);
    const s = try v.fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "x"));
}

test "value::Env::put and get" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);

    try env.put("x", intValue(42));
    const val = env.get("x");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.type == .integer);
    try std.testing.expect(val.?.int_val == 42);
}

test "value::Env::get returns null for missing key" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);
    try std.testing.expect(env.get("missing") == null);
}

test "value::Env::has" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);
    try env.put("x", intValue(1));
    try std.testing.expect(env.has("x"));
    try std.testing.expect(!env.has("y"));
}

test "value::Env::parent lookup" {
    const a = std.heap.page_allocator;
    var parent: Env = Env.init(a);
    var child: Env = Env.init(a);
    child.parent = &parent;
    defer parent.deinit(a);
    defer child.deinit(a);

    try parent.put("x", intValue(42));
    const val = child.get("x");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.int_val == 42);
}

test "value::Env::child shadows parent" {
    const a = std.heap.page_allocator;
    var parent: Env = Env.init(a);
    var child: Env = Env.init(a);
    child.parent = &parent;
    defer parent.deinit(a);
    defer child.deinit(a);

    try parent.put("x", intValue(42));
    try child.put("x", intValue(99));
    const val = child.get("x");
    try std.testing.expect(val.?.int_val == 99);
}

test "value::Env::put overwrites existing" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);

    try env.put("x", intValue(1));
    try env.put("x", intValue(2));
    const val = env.get("x");
    try std.testing.expect(val.?.int_val == 2);
}

test "value::Env::clone" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    try env.put("x", intValue(42));
    var cloned = try env.clone(a);
    defer env.deinit(a);
    defer cloned.deinit(a);

    const val = cloned.get("x");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.int_val == 42);
}

test "value::Env::clone preserves parent" {
    const a = std.heap.page_allocator;
    var parent: Env = Env.init(a);
    var child: Env = Env.init(a);
    child.parent = &parent;
    try parent.put("root", intValue(1));
    try child.put("local", intValue(2));
    var cloned = try child.clone(a);
    defer parent.deinit(a);
    defer child.deinit(a);
    defer cloned.deinit(a);

    try std.testing.expect(cloned.get("local").?.int_val == 2);
    try std.testing.expect(cloned.get("root").?.int_val == 1);
}
