const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();
const list = @import("list.zig");
const vec = @import("vector.zig");
const BI = @import("big_int.zig");
const RatioMod = @import("ratio.zig");
const BD = @import("big_decimal.zig");
const phm = @import("persistent_hash_map.zig");
const gc_mod = @import("gc.zig");

pub const Type = enum {
    nil,
    bool,
    integer,
    float,
    bigint,
    ratio,
    decimal,
    string,
    regex,     // Regex pattern: #"..."
    character, // Char type: a single Unicode code point
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
    cons,    // Cons cell: (head . tail) — tail is any sequence value
    atom,
    reduced, // Wrapper for early reduction termination
    wrapped, // Raw pointer wrapper — stores a usize pointer in wrapped_val
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
    // When set, the lazy-seq forcing code uses this custom handler
    // instead of evaluating `body` through the Clojure evaluator.
    // This avoids per-element evaluator overhead for map/filter/etc.
    custom_handler: ?LazySeqHandler = null,
    // Shared collection pointer for map's index-based iteration.
    // Points to the collection owned by the root thunk's env.
    // Child thunks share this pointer — no cloning needed.
    // Uses anyopaque since Value is not yet defined at this point.
    shared_coll: ?*const anyopaque = null,
};

pub const LazySeqHandler = enum {
    map,  // (map f coll) — apply f to each element of coll
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
bigint_val: ?*BI.BigInt = null,
ratio_val: ?*RatioMod.Ratio = null,
decimal_val: ?*BD.BigDecimal = null,
char_val: u21 = 0,
str_val: []const u8 = "",
re_pattern: []const u8 = "", // regex pattern string
sym_val: []const u8 = "",
kw_val: []const u8 = "",
list_val: list.List = list.List.empty,
vec_val: vec.Vector = vec.Vector.empty,
map_val: Map = .empty,
set_val: Set = .empty,
queue_val: Queue = .empty,
fn_val: FnData = .{ .arities = .empty, .env = undefined, .is_macro = false, .name = null },
builtin_fn_val: BuiltinFn = undefined,
lazy_seq_val: LazySeq = .{},
cons_val: ?*ConsData = null,
atom_val: ?*AtomData = null,
reduced_val: ?*Self = null, // wrapped value for early reduction
wrapped_val: usize = 0,     // raw pointer stored as usize (for PersistentHashMap pointer values)

// Single arity: one [params] + body forms + optional rest param
pub const Arity = struct {
    params: list.List,
    body: list.List,
    rest_name: ?[]const u8 = null, // variadic rest parameter name (e.g., & args)
};

pub const FnData = struct {
    arities: std.ArrayListUnmanaged(Arity) = .empty, // multi-arity support
    env: *Env, // heap-allocated to break circular type dependency
    is_macro: bool = false, // true if this is a macro (args passed unevaluated)
    name: ?[]const u8 = null, // optional name for self-reference in recursive calls
};

/// Wrap a raw pointer into a Value for storage in PersistentHashMap.
/// The wrapped Value is cheap to clone (just copies the usize).
pub fn wrapPtr(T: type, ptr: T) Self {
    return .{ .type = .wrapped, .wrapped_val = @intFromPtr(ptr) };
}

/// Unwrap a raw pointer from a Value. Caller must ensure type is .wrapped.
pub fn unwrapPtr(T: type, self: Self) T {
    return @ptrFromInt(self.wrapped_val);
}

/// Create a symbol Value for use as a PersistentHashMap key (non-owned string).
fn symKey(s: []const u8) Self {
    return .{ .type = .symbol, .sym_val = s };
}

/// Namespace manager: tracks all namespaces, current namespace, and aliases.
/// Only the root env holds a non-null pointer to this.
/// Uses PersistentHashMap (HAMT) for namespaces and aliases — immutable,
/// structural sharing, no deep-clone headaches.
pub const NamespaceManager = struct {
    allocator: Allocator,
    /// Maps namespace name → Env pointer (stored as Value.wrapped)
    namespaces: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    /// Current namespace name (owned string)
    current_ns: []const u8 = undefined,
    /// Maps composite key "ns_name/alias_name" → target namespace name (stored as Value.wrapped pointer to owned string)
    aliases: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    /// Classpath directories for loading .clj files
    classpath: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator) anyerror!*NamespaceManager {
        const mgr = try allocator.create(NamespaceManager);
        mgr.* = .{ .allocator = allocator };
        // Register with GC for proper scanning
        if (gc_mod.current_gc) |gc_inst| {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(mgr)), gc_mod.GCObjectType.namespace_manager);
        }
        // Heap-allocate initial namespace name so setCurrentNamespace/deinit can free it.
        mgr.current_ns = try allocator.dupe(u8, "user");
        // Create default "user" namespace
        _ = try mgr.createNamespace("user");
        return mgr;
    }

    pub fn deinit(self: *NamespaceManager) void {
        const allocator = self.allocator;
        // Free Env structs pointed to by namespace entries (but not their entries — managed by caller)
        var ns_it = self.namespaces.entryIterator();
        while (ns_it.next()) |entry| {
            const env_ptr: *Env = unwrapPtr(*Env, entry.val);
            env_ptr.deinit(allocator);
            allocator.destroy(env_ptr);
        }
        self.namespaces.deinit(allocator);
        // Aliases store target strings as Value.string — deinit handles freeing them
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
        const key = symKey(name);
        if (self.namespaces.find(key)) |existing_val| {
            return unwrapPtr(*Env, existing_val);
        }

        // Create new env with parent = null (will be set by caller to root env)
        const ns_env = try self.allocator.create(Env);
        ns_env.* = Env.init(self.allocator);
        // Register with GC for proper scanning
        if (gc_mod.current_gc) |gc_inst| {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(ns_env)), gc_mod.GCObjectType.env);
        }
        // ns_env.parent is set by caller
        const wrapped = wrapPtr(*Env, ns_env);
        self.namespaces = try self.namespaces.mapAssoc(self.allocator, key, wrapped);
        return ns_env;
    }

    /// Get the Env for a namespace (must already exist).
    pub fn getNamespace(self: *NamespaceManager, name: []const u8) ?*Env {
        const key = symKey(name);
        const found = self.namespaces.find(key);
        if (found) |val| return unwrapPtr(*Env, val);
        return null;
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
    /// Uses composite key "ns_name/alias_name" for flat storage.
    /// Target stored as Value.string (owned by the PersistentHashMap).
    pub fn addAlias(self: *NamespaceManager, ns_name: []const u8, alias: []const u8, target: []const u8) anyerror!void {
        // Build composite key: "ns_name/alias_name"
        var key_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer key_buf.deinit(self.allocator);
        try key_buf.appendSlice(self.allocator, ns_name);
        try key_buf.append(self.allocator, '/');
        try key_buf.appendSlice(self.allocator, alias);
        const composite_key = key_buf.items;

        // Store target as Value.string (PersistentHashMap owns it)
        const key = symKey(composite_key);
        const target_val = try stringValue(self.allocator, target);
        self.aliases = try self.aliases.mapAssoc(self.allocator, key, target_val);
    }

    /// Resolve an alias in a namespace. Returns the target namespace name, or null.
    pub fn resolveAlias(self: *const NamespaceManager, ns_name: []const u8, alias: []const u8) ?[]const u8 {
        // Build composite key: "ns_name/alias_name" — use stack buffer
        var key_buf: [256]u8 = undefined;
        const ns_len = ns_name.len;
        const alias_len = alias.len;
        if (ns_len + 1 + alias_len >= key_buf.len) return null; // safety guard
        @memcpy(key_buf[0..ns_len], ns_name);
        key_buf[ns_len] = '/';
        @memcpy(key_buf[ns_len + 1 .. ns_len + 1 + alias_len], alias);
        const composite_key = key_buf[0 .. ns_len + 1 + alias_len];

        const key = symKey(composite_key);
        const found = self.aliases.find(key);
        if (found) |val| {
            if (val.type == .string) return val.str_val;
        }
        return null;
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
    entries: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    parent: ?*Env = null,
    /// Pointer to namespace manager (only set on root env, inherited via parent chain)
    ns_manager: ?*NamespaceManager = null,
    /// Names added via :refer (not owned by this namespace).
    /// Prevents transitive refers — original Clojure only copies owned vars.
    /// Uses ArrayList for simplicity (linear scan, avoids HashMap allocator issues).
    referred_names: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator) Env {
        return .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = null,
            .ns_manager = null,
            .referred_names = .empty,
        };
    }

    pub fn deinit(self: *Env, allocator: Allocator) void {
        // HAMT nodes are GC-tracked; don't explicitly deinit entries.
        // Reset to avoid dangling pointers if deinit is called multiple times.
        self.entries.root = null;
        self.entries.count = 0;
        self.entries.has_null = false;
        for (self.referred_names.items) |name| {
            allocator.free(name);
        }
        self.referred_names.deinit(allocator);
        _ = self.parent; // Don't deinit parent here; it's managed separately
        _ = self.ns_manager; // Don't deinit ns_manager here
    }

    pub fn clone(self: *const Env, allocator: Allocator) anyerror!Env {
        // Structural sharing: just copy the PersistentHashMap struct.
        // The underlying HAMT nodes are shared between old and new env.
        return .{
            .allocator = allocator,
            .entries = self.entries,
            .parent = self.parent,
            .ns_manager = self.ns_manager,
            .referred_names = .empty,
        };
    }

    pub fn put(self: *Env, name: []const u8, value: Self) anyerror!void {
        const allocator = self.allocator;
        // mapAssoc returns a new immutable map with structural sharing.
        // The HAMT clones the value internally.
        const key = phm.sym(name);
        const new_entries = try self.entries.mapAssoc(allocator, key, value);
        // Don't deinit old entries — HAMT nodes are GC-tracked.
        // Other envs might share nodes via structural sharing (clone).
        // The GC will free unreachable HAMT nodes during collection.
        // Reset old entries to avoid double-free if deinit is called later.
        self.entries.root = null;
        self.entries.count = 0;
        self.entries.has_null = false;
        self.entries = new_entries;
        // mapAssoc cloned the value into the HAMT, so deinit the original.
        var val = value;
        val.deinit(allocator);
    }

    pub fn get(self: *Env, name: []const u8) ?Self {
        var current: ?*Env = self;
        while (current) |env| {
            if (!env.entries.isEmpty()) {
                const found = env.entries.find(phm.sym(name));
                if (found) |val| return val;
            }
            current = env.parent;
        }
        return null;
    }

    pub fn has(self: *Env, name: []const u8) bool {
        var current: ?*Env = self;
        while (current) |env| {
            if (env.entries.containsKey(phm.sym(name))) return true;
            current = env.parent;
        }
        return false;
    }

    /// Return a pointer to the Value stored under the given key.
    /// The pointer is valid as long as the HAMT node containing it is alive.
    /// Returns null if the key is not found.
    pub fn getPtr(self: *Env, name: []const u8) ?*const Self {
        return self.entries.findPtr(phm.sym(name));
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

pub fn bigIntValue(allocator: Allocator, bi: BI.BigInt) anyerror!Self {
    const ptr = try allocator.create(BI.BigInt);
    ptr.* = bi;
    return .{ .type = .bigint, .bigint_val = ptr };
}

pub fn ratioValue(allocator: Allocator, r: RatioMod.Ratio) anyerror!Self {
    const ptr = try allocator.create(RatioMod.Ratio);
    ptr.* = r;
    return .{ .type = .ratio, .ratio_val = ptr };
}

pub fn decimalValue(allocator: Allocator, d: BD.BigDecimal) anyerror!Self {
    const ptr = try allocator.create(BD.BigDecimal);
    ptr.* = d;
    return .{ .type = .decimal, .decimal_val = ptr };
}

pub fn stringValue(allocator: Allocator, s: []const u8) anyerror!Self {
    // Validate UTF-8 encoding
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUTF8;
    const duped = try allocator.dupe(u8, s);
    return .{ .type = .string, .str_val = duped };
}

pub fn regexValue(allocator: Allocator, s: []const u8) anyerror!Self {
    const duped = try allocator.dupe(u8, s);
    return .{ .type = .regex, .re_pattern = duped };
}

pub fn charValue(c: u21) Self {
    return .{ .type = .character, .char_val = c };
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

/// Create a reduced wrapper for early reduction termination
pub fn reducedValue(allocator: Allocator, val: Self) anyerror!Self {
    const data = try allocator.create(Self);
    data.* = try val.clone(allocator);
    return .{ .type = .reduced, .reduced_val = data };
}

/// Check if a value is a reduced wrapper
pub fn isReduced(self: Self) bool {
    return self.type == .reduced;
}

/// Unwrap a reduced value if it is reduced, otherwise return the value itself
pub fn unreducedValue(allocator: Allocator, self: Self) anyerror!Self {
    if (self.type == .reduced) {
        if (self.reduced_val) |data| {
            return try data.clone(allocator);
        }
        return nilValue();
    }
    return try self.clone(allocator);
}

pub fn lazySeqValue(thunk: ?*LazySeqThunk) Self {
    return .{ .type = .lazy_seq, .lazy_seq_val = .{ .thunk = thunk } };
}

/// Create a cons cell: (head . tail)
pub fn consValue(allocator: Allocator, head: Self, tail: Self) anyerror!Self {
    const data = try allocator.create(ConsData);
    errdefer allocator.destroy(data);
    data.* = .{ .head = head, .tail = tail, .allocator = allocator, .ref_count = 1 };
    return .{ .type = .cons, .cons_val = data };
}

/// Create a cons cell value that shares an existing ConsData (increments ref count).
pub fn consValueShared(data: *ConsData) Self {
    data.ref_count += 1;
    return .{ .type = .cons, .cons_val = data };
}

pub fn fnValue(allocator: Allocator, arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool) anyerror!Self {
    return fnValueNamed(allocator, arities, env, is_macro, null);
}

pub fn fnValueNamed(allocator: Allocator, arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool, name: ?[]const u8) anyerror!Self {
    const env_ptr = try allocator.create(Env);
    errdefer allocator.destroy(env_ptr);
    env_ptr.* = env;
    return .{ .type = .function, .fn_val = .{ .arities = arities, .env = env_ptr, .is_macro = is_macro, .name = name } };
}

/// Create a single-arity function (convenience wrapper)
pub fn fnValueSingle(allocator: Allocator, params: list.List, body: list.List, env: Env, rest_name: ?[]const u8, is_macro: bool) anyerror!Self {
    return fnValueSingleNamed(allocator, params, body, env, rest_name, is_macro, null);
}

/// Create a single-arity function with an optional name for self-reference
pub fn fnValueSingleNamed(allocator: Allocator, params: list.List, body: list.List, env: Env, rest_name: ?[]const u8, is_macro: bool, name: ?[]const u8) anyerror!Self {
    var arities: std.ArrayListUnmanaged(Arity) = .empty;
    errdefer allocator.free(arities.items);
    try arities.append(allocator, Arity{ .params = params, .body = body, .rest_name = rest_name });
    return fnValueNamed(allocator, arities, env, is_macro, name);
}

pub fn builtinFnValue(fn_ptr: BuiltinFn) Self {
    return .{ .type = .builtin_fn, .builtin_fn_val = fn_ptr };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    switch (self.type) {
        .nil, .bool, .integer, .float, .character => {},
        .bigint => {
            if (self.bigint_val) |ptr| {
                ptr.deinit();
                allocator.destroy(ptr);
            }
        },
        .ratio => {
            if (self.ratio_val) |ptr| {
                ptr.deinit();
                allocator.destroy(ptr);
            }
        },
        .decimal => {
            if (self.decimal_val) |ptr| {
                ptr.deinit();
                allocator.destroy(ptr);
            }
        },
        .string => allocator.free(self.str_val),
        .regex => allocator.free(self.re_pattern),
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
            allocator.destroy(self.fn_val.env);
            if (self.fn_val.name) |n| allocator.free(n);
        },
        .builtin_fn => {},
        .cons => {
            if (self.cons_val) |data| {
                data.ref_count -= 1;
                if (data.ref_count == 0) {
                    const a = data.allocator;
                    data.head.deinit(a);
                    data.tail.deinit(a);
                    a.destroy(data);
                }
            }
        },
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
        .reduced => {
            if (self.reduced_val) |data| {
                data.deinit(allocator);
                allocator.destroy(data);
            }
        },
        .wrapped => {}, // raw pointer, no ownership
    }
}

pub fn clone(self: *const Self, allocator: Allocator) anyerror!Self {
    switch (self.type) {
        .nil => return nilValue(),
        .bool => return boolValue(self.bool_val),
        .integer => return intValue(self.int_val),
        .float => return floatValue(self.float_val),
        .bigint => {
            if (self.bigint_val) |ptr| return try bigIntValue(allocator, try ptr.clone(allocator));
            return nilValue();
        },
        .ratio => {
            if (self.ratio_val) |ptr| return try ratioValue(allocator, try ptr.clone(allocator));
            return nilValue();
        },
        .decimal => {
            if (self.decimal_val) |ptr| return try decimalValue(allocator, try ptr.clone(allocator));
            return nilValue();
        },
        .string => return stringValue(allocator, self.str_val),
        .regex => return regexValue(allocator, self.re_pattern),
        .character => return charValue(self.char_val),
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
                    .custom_handler = thunk.custom_handler,
                    .shared_coll = thunk.shared_coll, // shared pointer, no clone (anyopaque)
                };
                new_lazy.thunk = new_thunk;
            }
            return lazySeqValue(new_lazy.thunk);
        },
        .cons => {
            if (self.cons_val) |data| {
                // Cons cells are immutable — share via reference counting, no deep clone needed.
                return consValueShared(data);
            }
            return nilValue();
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
            var cloned_name: ?[]const u8 = null;
            if (fnv.name) |n| cloned_name = try allocator.dupe(u8, n);
            return fnValueNamed(allocator, cloned_arities, try fnv.env.clone(allocator), fnv.is_macro, cloned_name);
        },
        .builtin_fn => return builtinFnValue(self.builtin_fn_val),
        .wrapped => return .{ .type = .wrapped, .wrapped_val = self.wrapped_val }, // cheap pointer copy
        .reduced => {
            if (self.reduced_val) |data| {
                return reducedValue(allocator, data.*);
            }
            return .{ .type = .reduced, .reduced_val = null };
        },
    }
}

pub fn isTruthy(self: Self) bool {
    return switch (self.type) {
        .nil => false,
        .bool => self.bool_val,
        .character => true,
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
        .bigint => {
            if (self.bigint_val) |a| {
                if (other.bigint_val) |b| return BI.equals(a.*, b.*);
            }
            return false;
        },
        .ratio => {
            if (self.ratio_val) |a| {
                if (other.ratio_val) |b| return RatioMod.equals(a.*, b.*);
            }
            return false;
        },
        .decimal => {
            if (self.decimal_val) |a| {
                if (other.decimal_val) |b| return BD.equals(a.*, b.*);
            }
            return false;
        },
        .string => return std.mem.eql(u8, self.str_val, other.str_val),
        .regex => return std.mem.eql(u8, self.re_pattern, other.re_pattern),
        .character => return self.char_val == other.char_val,
        .symbol => return std.mem.eql(u8, self.sym_val, other.sym_val),
        .keyword => return std.mem.eql(u8, self.kw_val, other.kw_val),
        .list => {
            if (self.list_val.items.len != other.list_val.items.len) return false;
            for (self.list_val.items, 0..) |item, i| {
                if (!item.equals(other.list_val.items[i])) return false;
            }
            return true;
        },
        .vector => {
            if (self.vec_val.items.len != other.vec_val.items.len) return false;
            for (self.vec_val.items, 0..) |item, i| {
                if (!item.equals(other.vec_val.items[i])) return false;
            }
            return true;
        },
        .map => {
            if (self.map_val.items.len != other.map_val.items.len) return false;
            for (self.map_val.items) |entry| {
                const other_val = mapLookup(other.map_val, entry.key);
                if (other_val == null or !entry.value.equals(other_val.?)) return false;
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
        .cons => {
            if (self.cons_val) |s_data| {
                if (other.cons_val) |o_data| {
                    return s_data.head.equals(o_data.head) and s_data.tail.equals(o_data.tail);
                }
            }
            return false;
        },
        .atom => {
            // Atoms are never equal by identity
            return false;
        },
        .reduced => {
            if (self.reduced_val) |s_data| {
                if (other.reduced_val) |o_data| {
                    return s_data.equals(o_data.*);
                }
            }
            return false;
        },
        .wrapped => return self.wrapped_val == other.wrapped_val,
        else => return false,
    }
}

/// Look up a key in a map, returning the value or null.
fn mapLookup(m: Map, key: Self) ?Self {
    for (m.items) |entry| {
        if (entry.key.equals(key)) return entry.value;
    }
    return null;
}

/// Convert a numeric value to f64 for comparison
fn toNumValue(v: Self) f64 {
    return switch (v.type) {
        .integer => @as(f64, @floatFromInt(v.int_val)),
        .float => v.float_val,
        else => 0,
    };
}

/// Three-way comparison: returns -1, 0, or 1
/// Mirrors the behavior of core_compare
pub fn compare(self: Self, other: Self) i64 {
    // nil handling: nil < everything else
    if (self.type == .nil and other.type == .nil) return 0;
    if (self.type == .nil) return -1;
    if (other.type == .nil) return 1;

    // For numbers, compare as f64
    const is_self_num = switch (self.type) {
        .integer, .float, .bigint, .ratio, .decimal => true,
        else => false,
    };
    const is_other_num = switch (other.type) {
        .integer, .float, .bigint, .ratio, .decimal => true,
        else => false,
    };
    if (is_self_num and is_other_num) {
        const a_num = toNumValue(self);
        const b_num = toNumValue(other);
        if (a_num < b_num) return -1;
        if (a_num > b_num) return 1;
        return 0;
    }

    // For same types, use equals check
    if (self.type == other.type) {
        if (self.equals(other)) return 0;
        // For strings, do lexicographic comparison
        if (self.type == .string) {
            return compareStrings(self.str_val, other.str_val);
        }
        // Fallback: use type order
        return 1;
    }

    // Different non-numeric types: compare by type order
    return @as(i64, @intFromEnum(self.type)) - @as(i64, @intFromEnum(other.type));
}

fn compareStrings(a: []const u8, b: []const u8) i64 {
    const len = if (a.len < b.len) a.len else b.len;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

pub fn fmt(self: Self, allocator: Allocator) anyerror![]const u8 {
    return switch (self.type) {
        .nil => allocator.dupe(u8, "nil"),
        .bool => if (self.bool_val) allocator.dupe(u8, "true") else allocator.dupe(u8, "false"),
        .integer => try std.fmt.allocPrint(allocator, "{d}", .{self.int_val}),
        .float => try std.fmt.allocPrint(allocator, "{d}", .{self.float_val}),
        .bigint => {
            if (self.bigint_val) |ptr| return try ptr.toString(allocator);
            return allocator.dupe(u8, "0");
        },
        .ratio => {
            if (self.ratio_val) |ptr| return try ptr.toString(allocator);
            return allocator.dupe(u8, "0");
        },
        .decimal => {
            if (self.decimal_val) |ptr| return try ptr.toString(allocator);
            return allocator.dupe(u8, "0");
        },
        .string => try std.fmt.allocPrint(allocator, "\"{s}\"", .{self.str_val}),
        .regex => try std.fmt.allocPrint(allocator, "#\"{s}\"", .{self.re_pattern}),
        .character => try charFmt(self.char_val, allocator),
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
        .cons => {
            if (self.cons_val) |data| return try consFmt(data, allocator);
            return allocator.dupe(u8, "()");
        },
        .atom => {
            if (self.atom_val) |data| {
                const inner_str = try data.value.fmt(allocator);
                defer allocator.free(inner_str);
                return try std.fmt.allocPrint(allocator, "#atom({s})", .{inner_str});
            }
            return allocator.dupe(u8, "#atom(nil)");
        },
        .reduced => {
            if (self.reduced_val) |data| {
                const inner_str = try data.fmt(allocator);
                defer allocator.free(inner_str);
                return try std.fmt.allocPrint(allocator, "#reduced({s})", .{inner_str});
            }
            return allocator.dupe(u8, "#reduced(nil)");
        },
        .wrapped => try std.fmt.allocPrint(allocator, "#ptr({X})", .{self.wrapped_val}),
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

/// Format a cons cell as a list: (head ...tail_elements...)
/// Walks the cons chain and prints all elements.
pub fn consFmt(data: *const ConsData, allocator: Allocator) anyerror![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '(');

    // Walk the cons chain without taking ownership
    var head_ref: *const Self = &data.head;
    var tail_ref: *const Self = &data.tail;
    var first = true;

    while (true) {
        if (!first) try buf.append(allocator, ' ');
        const head_str = try head_ref.fmt(allocator);
        defer allocator.free(head_str);
        try buf.appendSlice(allocator, head_str);
        first = false;

        // Check what the tail is
        switch (tail_ref.type) {
            .cons => {
                if (tail_ref.cons_val) |tail_data| {
                    head_ref = &tail_data.head;
                    tail_ref = &tail_data.tail;
                } else break;
            },
            .list => {
                // Splice in the list elements
                for (tail_ref.list_val.items) |item| {
                    try buf.append(allocator, ' ');
                    const item_str = try item.fmt(allocator);
                    defer allocator.free(item_str);
                    try buf.appendSlice(allocator, item_str);
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                // Print lazy-seq marker
                try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, "#lazy-seq");
                break;
            },
            else => {
                // Dotted pair: (head . tail)
                try buf.append(allocator, ' ');
                try buf.append(allocator, '.');
                try buf.append(allocator, ' ');
                const tail_str = try tail_ref.fmt(allocator);
                defer allocator.free(tail_str);
                try buf.appendSlice(allocator, tail_str);
                break;
            },
        }
    }

    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

/// Format a character value as \x or \newline, \space, etc.
fn charFmt(c: u21, allocator: Allocator) anyerror![]const u8 {
    // Named escapes (same as Clojure)
    if (c == 9) return allocator.dupe(u8, "\\tab");
    if (c == 10) return allocator.dupe(u8, "\\newline");
    if (c == 13) return allocator.dupe(u8, "\\return");
    if (c == 32) return allocator.dupe(u8, "\\space");
    if (c == 12) return allocator.dupe(u8, "\\formfeed");

    // For printable ASCII, use \x
    if (c < 128) {
        const ch = @as(u8, @intCast(c));
        return std.fmt.allocPrint(allocator, "\\{c}", .{ch});
    }

    // For Unicode characters, encode as UTF-8 and prepend \
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '\\');
    var utf8_buf: [4]u8 = undefined;
    const utf8_len = std.unicode.utf8Encode(c, &utf8_buf) catch return error.InvalidUnicode;
    try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
    return buf.toOwnedSlice(allocator);
}

// Cons cell data: heap-allocated, contains head, tail, and the allocator used.
// This avoids circular dependency (Value contains *ConsData, ConsData contains Value).
pub const ConsData = struct {
    head: Self,
    tail: Self,
    allocator: Allocator,
    ref_count: usize = 1, // reference counting for safe sharing of immutable cons cells
};

// Unit tests are in test_value.zig
