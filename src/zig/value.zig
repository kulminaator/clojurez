const std = @import("std");
const Allocator = std.mem.Allocator;

const list = @import("list.zig");
const vec = @import("vector.zig");
const BI = @import("big_int.zig");
const RatioMod = @import("ratio.zig");
const BD = @import("big_decimal.zig");
const phm = @import("persistent_hash_map.zig");
const gc_mod = @import("gc.zig");
const bytecode_mod = @import("bytecode.zig");

/// Helper: tag a string data allocation so the GC doesn't misidentify it as a Value.
fn tagStringData(ptr: *anyopaque) void {
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(ptr, gc_mod.GCObjectType.string_data);
    }
}

// ============================================================
// Value Cache — pre-allocated singleton values for common immediates
// ============================================================
// Avoids repeated GC heap allocations for nil, true, false,
// small integers (-128..127), and latin characters (0..127).
// The cache struct is a permanent GC root — never collected.
//
// Layout:
//   nil_ptr, true_ptr, false_ptr  — 3 singletons
//   int_cache[256]                 — index = value + 128
//   char_cache[128]                — index = codepoint
//
// Thread-safe: read-only after initialization.
// ============================================================

pub const ValueCache = struct {
    nil_ptr: *Value = undefined,
    true_ptr: *Value = undefined,
    false_ptr: *Value = undefined,
    int_cache: [256]*Value = undefined,  // index = int + 128
    char_cache: [128]*Value = undefined, // index = codepoint
    // Math constants
    e_ptr: *Value = undefined,
    pi_ptr: *Value = undefined,
    // Empty collections
    empty_string_ptr: *Value = undefined,
    empty_list_ptr: *Value = undefined,
    empty_vector_ptr: *Value = undefined,
    empty_map_ptr: *Value = undefined,
    empty_set_ptr: *Value = undefined,

    /// Initialize the cache. Allocates the struct and all child values
    /// through the GC allocator. Tags the struct as value_cache type.
    /// Must be called once at VM startup.
    pub fn init(self: *ValueCache, allocator: Allocator) anyerror!void {
        self.nil_ptr = try allocator.create(Value);
        self.nil_ptr.* = .nil;

        self.true_ptr = try allocator.create(Value);
        self.true_ptr.* = .{ .bool = true };

        self.false_ptr = try allocator.create(Value);
        self.false_ptr.* = .{ .bool = false };

        // Math constants
        self.e_ptr = try allocator.create(Value);
        self.e_ptr.* = .{ .float = std.math.e };
        self.pi_ptr = try allocator.create(Value);
        self.pi_ptr.* = .{ .float = std.math.pi };

        // Empty string
        self.empty_string_ptr = try allocator.create(Value);
        self.empty_string_ptr.* = .{ .string = try allocator.dupe(u8, "") };
        tagStringData(@as(*anyopaque, @ptrCast(@constCast(self.empty_string_ptr.*.string.ptr))));

        // Empty list
        self.empty_list_ptr = try allocator.create(Value);
        const empty_list_data = try allocator.create(ListData);
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(empty_list_data)), gc_mod.GCObjectType.list_data);
        }
        empty_list_data.* = .{ .items = list.empty(), .src_line = 0 };
        self.empty_list_ptr.* = .{ .list = empty_list_data };

        // Empty vector
        self.empty_vector_ptr = try allocator.create(Value);
        const empty_vec_data = try allocator.create(VectorData);
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(empty_vec_data)), gc_mod.GCObjectType.vector_data);
        }
        empty_vec_data.* = .{ .items = vec.empty() };
        self.empty_vector_ptr.* = .{ .vector = empty_vec_data };

        // Empty map
        self.empty_map_ptr = try allocator.create(Value);
        const empty_map_data = try allocator.create(MapData);
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(empty_map_data)), gc_mod.GCObjectType.map_data);
        }
        empty_map_data.* = .{ .entries = .empty };
        self.empty_map_ptr.* = .{ .map = empty_map_data };

        // Empty set
        self.empty_set_ptr = try allocator.create(Value);
        const empty_set_data = try allocator.create(SetData);
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(empty_set_data)), gc_mod.GCObjectType.set_data);
        }
        empty_set_data.* = .{ .items = .empty };
        self.empty_set_ptr.* = .{ .set = empty_set_data };

        var i: i64 = -128;
        while (i <= 127) : (i += 1) {
            const idx: usize = @as(usize, @intCast(i + 128));
            self.int_cache[idx] = try allocator.create(Value);
            self.int_cache[idx].* = .{ .integer = i };
        }

        var c: u21 = 0;
        while (c < 128) : (c += 1) {
            self.char_cache[c] = try allocator.create(Value);
            self.char_cache[c].* = .{ .character = c };
        }
    }

    /// Try to get a cached pointer for the given value.
    /// Returns null if the value is not in the cache.
    pub fn get(self: *const ValueCache, val: Value) ?*const Value {
        return switch (val) {
            .nil => self.nil_ptr,
            .bool => |b| if (b) self.true_ptr else self.false_ptr,
            .integer => |n| if (n >= -128 and n <= 127)
                self.int_cache[@as(usize, @intCast(n + 128))]
            else null,
            .character => |c| if (c < 128)
                self.char_cache[c]
            else null,
            else => null,
        };
    }
};

/// Global value cache pointer. Allocated through GC at VM startup.
/// Registered as a permanent root — never collected.
pub var value_cache: ?*ValueCache = null;

/// Check if the value cache has been initialized.
pub fn isValueCacheReady() bool {
    return value_cache != null;
}

/// Get cached E constant value.
pub fn cachedE() ?Value {
    if (value_cache) |cache| return cache.e_ptr.*;
    return null;
}

/// Get cached PI constant value.
pub fn cachedPI() ?Value {
    if (value_cache) |cache| return cache.pi_ptr.*;
    return null;
}

/// Get cached empty string value.
pub fn cachedEmptyString() ?Value {
    if (value_cache) |cache| return cache.empty_string_ptr.*;
    return null;
}

/// Get cached empty list value.
pub fn cachedEmptyList() ?Value {
    if (value_cache) |cache| return cache.empty_list_ptr.*;
    return null;
}

/// Get cached empty vector value.
pub fn cachedEmptyVector() ?Value {
    if (value_cache) |cache| return cache.empty_vector_ptr.*;
    return null;
}

/// Get cached empty map value.
pub fn cachedEmptyMap() ?Value {
    if (value_cache) |cache| return cache.empty_map_ptr.*;
    return null;
}

/// Get cached empty set value.
pub fn cachedEmptySet() ?Value {
    if (value_cache) |cache| return cache.empty_set_ptr.*;
    return null;
}

// ============================================================
// Type enum — discriminant for the Value tagged union
// ============================================================

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
    chunk,          // ChunkData — batch of values (IChunk equivalent)
    chunked_cons,   // ChunkedConsData — chunk + lazy tail
    atom,
    future,  // Future: computation running in another thread
    promise, // Promise: one-time writable container
    reduced, // Wrapper for early reduction termination
    wrapped, // Raw pointer wrapper — stores a usize pointer
    record,  // defrecord instance: named struct-like data with fields
    exception,  // ExceptionData — runtime exception value
    ref,       // RefData — STM reference
    multimethod, // MultimethodData — multimethod dispatch
};

// ============================================================
// Helper type to get the active tag from a Value
// ============================================================

pub fn getType(val: Value) Type {
    return std.meta.activeTag(val);
}

// ============================================================
// LazySeq handler enum
// ============================================================

pub const LazySeqHandler = enum {
    map,    // (map f coll) — apply f to each element of coll
    range,  // (range start end step) — produce chunked sequence of integers
    filter, // (filter pred coll) — filter elements by predicate
};

// ============================================================
// Chunked sequence support
// ============================================================

pub const CHUNK_SIZE: usize = 32;

/// Immutable chunk of values — a slice into a shared backing array.
/// Multiple ChunkData can share the same backing array with different
/// off/end ranges (structural sharing, like Clojure's ArrayChunk).
pub const ChunkData = struct {
    items: []Value,        // backing array (GC-allocated)
    off: usize = 0,        // start offset
    end: usize = 0,        // end offset (exclusive)
    allocator: Allocator,
    owns_array: bool = false, // true if we should free items on deinit

    pub fn count(self: *const ChunkData) usize {
        return self.end - self.off;
    }

    pub fn nth(self: *const ChunkData, i: usize) Value {
        return self.items[self.off + i];
    }

    /// Return a new ChunkData with off advanced by 1 (dropFirst).
    /// Shares the same backing array — no allocation.
    pub fn dropFirst(self: *const ChunkData) ChunkData {
        return .{
            .items = self.items,
            .off = self.off + 1,
            .end = self.end,
            .allocator = self.allocator,
            .owns_array = false, // original owns it
        };
    }
};

/// Chunked cons cell — head is a Chunk (batch of values), tail is a seq.
/// Like ConsData but holds CHUNK_SIZE values instead of one.
pub const ChunkedConsData = struct {
    chunk: *ChunkData,     // current chunk of values
    tail: Value,           // lazy-seq for remaining (or nil)
    allocator: Allocator,
    ref_count: usize = 1,
};

// ============================================================
// Data structs (forward references to Value/Env are OK within the same file)
// ============================================================

pub const LazySeqThunk = struct {
    params: list.List,
    body: list.List,
    env: Env,
    custom_handler: ?LazySeqHandler = null,
    shared_coll: ?*const anyopaque = null,

    // Direct field for map handler — stores the mapping function inline
    // to avoid one env.put (HAMT allocation) per thunk step.
    // Only map_fn is stored directly; coll/idx remain in env.
    map_fn: ?Value = null,

    // Phase 10: Bytecode for lazy-seq body.
    // When non-null, forceLazySeqGetResult executes this bytecode
    // instead of evaluating the body list.
    bytecode: ?*const bytecode_mod.BytecodeProgram = null,
};

pub const AtomData = struct {
    value: Value,
    ref_count: usize = 1,
};

/// Future: a computation running in another thread.
/// state: 0 = running, 1 = done (result set), 2 = error (error_msg set)
/// Uses atomic state + sleep-based polling for thread safety.
/// No mutex needed — result is written once (after completion),
/// and the atomic state guards visibility.
/// fn_val holds the cloned function value so the GC can discover
/// the function and its captured environment, keeping them alive
/// while the future thread is running.
pub const FutureData = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    result: ?Value = null,
    fn_val: ?Value = null,    // cloned function value (GC root for captured env)
    error_msg: ?[]const u8 = null,
    allocator: Allocator,
};

/// Promise: a one-time writable container.
/// state: 0 = pending, 1 = delivered (value set)
/// Uses atomic state + sleep-based polling for thread safety.
/// ref_count tracks shared references (like AtomData).
pub const PromiseData = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    value: ?Value = null,
    allocator: Allocator,
    ref_count: usize = 1,
};

pub const RecordData = struct {
    type_name: []const u8,
    fields: Map,
    extmap: Map,
    meta: ?Map,
    allocator: Allocator,
};

/// Exception data: heap-allocated, immutable once created.
/// Used by throw/try/catch for runtime exceptions.
/// message and type_kw are owned (duped strings).
/// data and cause are SHARED pointers — never cloned.
pub const ExceptionData = struct {
    message: []const u8,    // Human-readable message (UTF-8, GC-allocated via dupe)
    data: *MapData,         // SHARED pointer to the map's data struct (never cloned)
    cause: ?*ExceptionData, // SHARED pointer to cause exception (never cloned)
    type_kw: []const u8,    // Exception type string, e.g. "clojure.lang/ArithmeticException"
    allocator: Allocator,
};

/// RefData — STM reference with version counter for optimistic concurrency.
/// Used by ref, dosync, alter, commute, ref-set.
pub const RefData = struct {
    value: Value,
    version: u64 = 0,       // Monotonically increasing version counter
    validator: ?Value = null, // Optional validator function
    meta: ?Value = null,     // Optional metadata map (for :commutative, etc.)
    allocator: Allocator,
};

/// MultimethodData — multimethod dispatch with method table.
/// Used by defmulti/defmethod.
pub const MultimethodData = struct {
    dispatch_fn: Value,                // Dispatch function
    method_table: Map = .empty,        // dispatch-value → method-fn
    pref_table: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty, // preference pairs
    default_dispatch: ?Value = null,   // Default dispatch value
    allocator: Allocator,
};

/// Cons cell data: heap-allocated, contains head, tail, and the allocator used.
pub const ConsData = struct {
    head: Value,
    tail: Value,
    allocator: Allocator,
    ref_count: usize = 1,
};

/// Single arity: one [params] + body forms + optional rest param
pub const Arity = struct {
    params: list.List,
    body: list.List,
    bytecode: ?*bytecode_mod.BytecodeProgram = null,
    rest_name: ?[]const u8 = null,
};

pub const FnData = struct {
    arities: std.ArrayListUnmanaged(Arity) = .empty,
    env: *Env,
    is_macro: bool = false,
    name: ?[]const u8 = null,
    docstring: ?[]const u8 = null,
    namespace: ?[]const u8 = null, // Namespace where function was defined (for :ns in metadata)
    cached_meta: ?Value = null, // Cached metadata map (populated by meta)
};

// ============================================================
// Heap-allocated collection data structs
// ============================================================

pub const ListData = struct {
    items: std.ArrayListUnmanaged(Value),
    src_line: usize = 0, // 1-based line number from parser (0 = unknown)
};

pub const VectorData = struct {
    items: std.ArrayListUnmanaged(Value),
};

pub const MapData = struct {
    entries: std.ArrayListUnmanaged(MapEntry),
};

pub const SetData = struct {
    items: std.ArrayListUnmanaged(Value),
};

pub const QueueData = struct {
    items: std.ArrayListUnmanaged(Value),
};

// ============================================================
// Value tagged union — ~32 bytes (was 296 bytes as flat struct)
// ============================================================

pub const Value = union(Type) {
    nil,
    bool: bool,
    integer: i64,
    float: f64,
    bigint: *BI.BigInt,
    ratio: *RatioMod.Ratio,
    decimal: *BD.BigDecimal,
    string: []const u8,
    regex: []const u8,
    character: u21,
    symbol: []const u8,
    keyword: []const u8,
    list: *ListData,
    vector: *VectorData,
    map: *MapData,
    set: *SetData,
    queue: *QueueData,
    function: *FnData,
    builtin_fn: BuiltinFn,
    lazy_seq: ?*LazySeqThunk,
    cons: *ConsData,
    chunk: *ChunkData,
    chunked_cons: *ChunkedConsData,
    atom: *AtomData,
    future: *FutureData,
    promise: *PromiseData,
    reduced: *Value,
    wrapped: usize,
    record: *RecordData,
    exception: *ExceptionData,
    ref: *RefData,
    multimethod: *MultimethodData,
};

// ============================================================
// Helper types (Value must be defined first for by-value embedding)
// ============================================================

pub const MapEntry = struct {
    key: Value,
    value: Value,
};

pub const Map = std.ArrayListUnmanaged(MapEntry);
pub const Set = std.ArrayListUnmanaged(Value);
pub const Queue = std.ArrayListUnmanaged(Value);

pub const BuiltinFn = *const fn (self: *const Value, args: *const list.List, env: *Env) anyerror!Value;

// ============================================================
// Constructors
// ============================================================

pub fn nilValue() Value {
    return .nil;
}

pub fn boolValue(b: bool) Value {
    return .{ .bool = b };
}

pub fn intValue(i: i64) Value {
    return .{ .integer = i };
}

pub fn floatValue(f: f64) Value {
    return .{ .float = f };
}

pub fn bigIntValue(allocator: Allocator, bi: BI.BigInt) anyerror!Value {
    const ptr = try allocator.create(BI.BigInt);
    ptr.* = bi;
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(ptr)), gc_mod.GCObjectType.bigint_data);
    }
    return .{ .bigint = ptr };
}

pub fn ratioValue(allocator: Allocator, r: RatioMod.Ratio) anyerror!Value {
    const ptr = try allocator.create(RatioMod.Ratio);
    ptr.* = r;
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(ptr)), gc_mod.GCObjectType.ratio_data);
    }
    return .{ .ratio = ptr };
}

pub fn decimalValue(allocator: Allocator, d: BD.BigDecimal) anyerror!Value {
    const ptr = try allocator.create(BD.BigDecimal);
    ptr.* = d;
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(ptr)), gc_mod.GCObjectType.decimal_data);
    }
    return .{ .decimal = ptr };
}

pub fn stringValue(allocator: Allocator, s: []const u8) anyerror!Value {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUTF8;
    const duped = try allocator.dupe(u8, s);
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
    return .{ .string = duped };
}

pub fn regexValue(allocator: Allocator, s: []const u8) anyerror!Value {
    const duped = try allocator.dupe(u8, s);
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
    return .{ .regex = duped };
}

pub fn charValue(c: u21) Value {
    return .{ .character = c };
}

pub fn symValue(allocator: Allocator, s: []const u8) anyerror!Value {
    const duped = try allocator.dupe(u8, s);
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
    return .{ .symbol = duped };
}

pub fn keywordValue(allocator: Allocator, s: []const u8) anyerror!Value {
    const duped = try allocator.dupe(u8, s);
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
    return .{ .keyword = duped };
}

pub fn listValue(allocator: Allocator, l: list.List) anyerror!Value {
    return listValueWithLine(allocator, l, 0);
}

pub fn listValueWithLine(allocator: Allocator, l: list.List, src_line: usize) anyerror!Value {
    const data = try allocator.create(ListData);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.list_data);
    }
    data.* = .{ .items = l, .src_line = src_line };
    return .{ .list = data };
}

pub fn vectorValue(allocator: Allocator, v: vec.Vector) anyerror!Value {
    const data = try allocator.create(VectorData);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.vector_data);
    }
    data.* = .{ .items = v };
    return .{ .vector = data };
}

pub fn mapValue(allocator: Allocator, m: Map) anyerror!Value {
    const data = try allocator.create(MapData);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.map_data);
    }
    data.* = .{ .entries = m };
    return .{ .map = data };
}

pub fn setValue(allocator: Allocator, s: Set) anyerror!Value {
    const data = try allocator.create(SetData);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.set_data);
    }
    data.* = .{ .items = s };
    return .{ .set = data };
}

pub fn queueValue(allocator: Allocator, q: Queue) anyerror!Value {
    const data = try allocator.create(QueueData);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.queue_data);
    }
    data.* = .{ .items = q };
    return .{ .queue = data };
}

pub fn atomValue(allocator: Allocator, initial: Value) anyerror!Value {
    const data = try allocator.create(AtomData);
    data.* = .{ .value = try clone(&initial, allocator), .ref_count = 1 };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.atom_data);
    }
    return .{ .atom = data };
}

pub fn atomValueShared(data: *AtomData) Value {
    data.ref_count += 1;
    return .{ .atom = data };
}

/// Create a future value (computation running in another thread).
pub fn futureValue(allocator: Allocator) anyerror!Value {
    const data = try allocator.create(FutureData);
    data.* = .{ .allocator = allocator, .fn_val = null };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.future_data);
    }
    return .{ .future = data };
}

/// Create a future value that shares an existing FutureData (for cloning).
pub fn futureValueShared(data: *FutureData) Value {
    return .{ .future = data };
}

/// Create a promise value (one-time writable container).
pub fn promiseValue(allocator: Allocator) anyerror!Value {
    const data = try allocator.create(PromiseData);
    data.* = .{ .allocator = allocator };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.promise_data);
        // Set generation to max so PromiseData is never swept.
        // Promises may outlive their creating scope (e.g., passed to futures).
        if (gc.findHeader(@as(*anyopaque, @ptrCast(data)))) |hdr| {
            hdr.generation = std.math.maxInt(u32);
        }
    }
    return .{ .promise = data };
}

/// Create a promise value that shares an existing PromiseData (for cloning).
pub fn promiseValueShared(data: *PromiseData) Value {
    data.ref_count += 1;
    return .{ .promise = data };
}

/// Create a ref value (STM reference).
pub fn refValue(allocator: Allocator, initial: Value) anyerror!Value {
    return refValueWithMeta(allocator, initial, null);
}

/// Create a ref value with optional metadata.
pub fn refValueWithMeta(allocator: Allocator, initial: Value, metadata: ?Value) anyerror!Value {
    const data = try allocator.create(RefData);
    data.* = .{
        .value = try clone(&initial, allocator),
        .version = 0,
        .validator = null,
        .meta = if (metadata) |m| try clone(&m, allocator) else null,
        .allocator = allocator,
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.ref_data);
    }
    return .{ .ref = data };
}

/// Create a multimethod value.
pub fn multimethodValue(allocator: Allocator, dispatch_fn: Value) anyerror!Value {
    const data = try allocator.create(MultimethodData);
    data.* = .{
        .dispatch_fn = try clone(&dispatch_fn, allocator),
        .method_table = .empty,
        .pref_table = .empty,
        .default_dispatch = null,
        .allocator = allocator,
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.multimethod_data);
    }
    return .{ .multimethod = data };
}

/// Create a reduced wrapper for early reduction termination
pub fn reducedValue(allocator: Allocator, val: Value) anyerror!Value {
    const data = try allocator.create(Value);
    data.* = try clone(&val, allocator);
    return .{ .reduced = data };
}

/// Check if a value is a reduced wrapper
pub fn isReduced(val: Value) bool {
    return std.meta.activeTag(val) == .reduced;
}

/// Unwrap a reduced value if it is reduced, otherwise return the value itself
pub fn unreducedValue(allocator: Allocator, val: Value) anyerror!Value {
    if (std.meta.activeTag(val) == .reduced) {
        switch (val) {
            .reduced => |data| return try clone(data, allocator),
            else => unreachable,
        }
    }
    return try clone(&val, allocator);
}

pub fn lazySeqValue(thunk: ?*LazySeqThunk) Value {
    return .{ .lazy_seq = thunk };
}

/// Create a cons cell: (head . tail)
pub fn consValue(allocator: Allocator, head: Value, tail: Value) anyerror!Value {
    const data = try allocator.create(ConsData);
    errdefer allocator.destroy(data);
    data.* = .{ .head = head, .tail = tail, .allocator = allocator, .ref_count = 1 };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.cons_data);
    }
    return .{ .cons = data };
}

/// Create a cons cell value that shares an existing ConsData (increments ref count).
pub fn consValueShared(data: *ConsData) Value {
    data.ref_count += 1;
    return .{ .cons = data };
}

/// Create a chunk value (batch of values with shared backing array).
pub fn chunkValue(allocator: Allocator, items: []Value, off: usize, end: usize, owns: bool) anyerror!Value {
    const data = try allocator.create(ChunkData);
    errdefer allocator.destroy(data);
    data.* = .{
        .items = items,
        .off = off,
        .end = end,
        .allocator = allocator,
        .owns_array = owns,
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.chunk_data);
    }
    return .{ .chunk = data };
}

/// Create a chunked-cons value (chunk + lazy tail).
pub fn chunkedConsValue(allocator: Allocator, chunk: *ChunkData, tail: Value) anyerror!Value {
    const data = try allocator.create(ChunkedConsData);
    errdefer allocator.destroy(data);
    data.* = .{
        .chunk = chunk,
        .tail = tail,
        .allocator = allocator,
        .ref_count = 1,
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.chunked_cons_data);
    }
    return .{ .chunked_cons = data };
}

pub fn fnValue(allocator: Allocator, arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool) anyerror!Value {
    return fnValueNamed(allocator, arities, env, is_macro, null);
}

pub fn fnValueNamed(allocator: Allocator, arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool, name: ?[]const u8) anyerror!Value {
    return fnValueNamedWithDoc(allocator, arities, env, is_macro, name, null);
}

pub fn fnValueNamedWithDoc(allocator: Allocator, arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool, name: ?[]const u8, docstring: ?[]const u8) anyerror!Value {
    const env_ptr = try allocator.create(Env);
    errdefer allocator.destroy(env_ptr);
    env_ptr.* = env;
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(env_ptr)), gc_mod.GCObjectType.env);
    }
    // Extract namespace name from the environment for :ns in function metadata
    // Walk the env chain to find ns_manager (it may be on a parent env)
    var ns_name: ?[]const u8 = null;
    var search_env: ?*const Env = &env;
    while (search_env) |e| : (search_env = e.parent) {
        if (e.ns_manager) |ns_mgr| {
            const current_ns = ns_mgr.getCurrentNamespace();
            ns_name = try allocator.dupe(u8, current_ns);
            break;
        }
    }
    const fn_data = try allocator.create(FnData);
    errdefer {
        if (ns_name) |n| allocator.free(n);
        allocator.destroy(fn_data);
    }
    fn_data.* = .{ .arities = arities, .env = env_ptr, .is_macro = is_macro, .name = name, .docstring = docstring, .namespace = ns_name };
    if (gc_mod.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(fn_data)), gc_mod.GCObjectType.fn_data);
        if (arities.items.len > 0) {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(arities.items.ptr)), gc_mod.GCObjectType.fn_arities);
        }
    }
    return .{ .function = fn_data };
}

/// Create a single-arity function (convenience wrapper)
pub fn fnValueSingle(allocator: Allocator, params: list.List, body: list.List, env: Env, rest_name: ?[]const u8, is_macro: bool) anyerror!Value {
    return fnValueSingleNamed(allocator, params, body, env, rest_name, is_macro, null);
}

/// Create a single-arity function with an optional name for self-reference
pub fn fnValueSingleNamed(allocator: Allocator, params: list.List, body: list.List, env: Env, rest_name: ?[]const u8, is_macro: bool, name: ?[]const u8) anyerror!Value {
    var arities: std.ArrayListUnmanaged(Arity) = .empty;
    errdefer allocator.free(arities.items);
    try arities.append(allocator, Arity{ .params = params, .body = body, .rest_name = rest_name });
    return fnValueNamed(allocator, arities, env, is_macro, name);
}

pub fn builtinFnValue(fn_ptr: BuiltinFn) Value {
    return .{ .builtin_fn = fn_ptr };
}

/// Wrap a raw pointer into a Value for storage in PersistentHashMap.
pub fn wrapPtr(T: type, ptr: T) Value {
    return .{ .wrapped = @intFromPtr(ptr) };
}

/// Unwrap a raw pointer from a Value. Caller must ensure type is .wrapped.
pub fn unwrapPtr(T: type, val: Value) T {
    return @ptrFromInt(val.wrapped);
}

// ============================================================
// Value methods (free functions — not accessible as .method() when imported via alias)
// ============================================================

pub fn valueDeinit(val: *Value, allocator: Allocator) void {
    _ = allocator;
    // In a GC system, we never free data here.
    // The GC tracks all objects and frees them when unreachable.
    // We just null out the Value so the GC stops seeing the pointer.
    val.* = nilValue();
}

pub fn clone(val: *const Value, allocator: Allocator) anyerror!Value {
    switch (val.*) {
        .nil => return nilValue(),
        .bool => |b| return boolValue(b),
        .integer => |i| return intValue(i),
        .float => |f| return floatValue(f),
        .bigint => |ptr| return try bigIntValue(allocator, try ptr.clone(allocator)),
        .ratio => |ptr| return try ratioValue(allocator, try ptr.clone(allocator)),
        .decimal => |ptr| return try decimalValue(allocator, try ptr.clone(allocator)),
        .string => |s| return stringValue(allocator, s),
        .regex => |s| return regexValue(allocator, s),
        .character => |c| return charValue(c),
        .symbol => |s| return symValue(allocator, s),
        .keyword => |s| return keywordValue(allocator, s),
        .list => |data| return try listValueWithLine(allocator, try list.clone(&data.items, allocator), data.src_line),
        .vector => |data| return try vectorValue(allocator, try vec.clone(&data.items, allocator)),
        .map => |data| {
            var new_map: Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    valueDeinit(&entry.key, allocator);
                    valueDeinit(&entry.value, allocator);
                }
                allocator.free(new_map.items);
            }
            try new_map.ensureTotalCapacity(allocator, data.entries.items.len);
            for (data.entries.items) |entry| {
                try new_map.append(allocator, .{
                    .key = try clone(&entry.key, allocator),
                    .value = try clone(&entry.value, allocator),
                });
            }
            return try mapValue(allocator, new_map);
        },
        .set => |data| {
            var new_set: Set = .empty;
            errdefer {
                for (new_set.items) |*item| {
                    valueDeinit(item, allocator);
                }
                allocator.free(new_set.items);
            }
            try new_set.ensureTotalCapacity(allocator, data.items.items.len);
            for (data.items.items) |item| {
                try new_set.append(allocator, try clone(&item, allocator));
            }
            return try setValue(allocator, new_set);
        },
        .queue => |data| {
            var new_queue: Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    valueDeinit(item, allocator);
                }
                allocator.free(new_queue.items);
            }
            try new_queue.ensureTotalCapacity(allocator, data.items.items.len);
            for (data.items.items) |item| {
                try new_queue.append(allocator, try clone(&item, allocator));
            }
            return try queueValue(allocator, new_queue);
        },
        .lazy_seq => |thunk| {
            if (thunk) |t| {
                const new_thunk = try allocator.create(LazySeqThunk);
                new_thunk.* = .{
                    .params = try list.clone(&t.params, allocator),
                    .body = try list.clone(&t.body, allocator),
                    .env = try t.env.clone(allocator),
                    .custom_handler = t.custom_handler,
                    .shared_coll = t.shared_coll,
                };
                if (gc_mod.current_gc) |gc| {
                    gc.setObjectType(@as(*anyopaque, @ptrCast(new_thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
                }
                return Value{ .lazy_seq = new_thunk };
            }
            return Value{ .lazy_seq = null };
        },
        .cons => |data| {
            return consValueShared(data);
        },
        .chunk => |data| {
            // Share the backing array, clone the ChunkData wrapper
            const new_data = try allocator.create(ChunkData);
            errdefer allocator.destroy(new_data);
            new_data.* = .{
                .items = data.items,  // shared backing array
                .off = data.off,
                .end = data.end,
                .allocator = allocator,
                .owns_array = false,  // original owns it
            };
            if (gc_mod.current_gc) |gc| {
                gc.setObjectType(@as(*anyopaque, @ptrCast(new_data)), gc_mod.GCObjectType.chunk_data);
            }
            // Clone each Value in the chunk
            var i: usize = data.off;
            while (i < data.end) : (i += 1) {
                new_data.items[i] = try clone(&data.items[i], allocator);
            }
            return .{ .chunk = new_data };
        },
        .chunked_cons => |data| {
            data.ref_count += 1;
            const new_tail = try clone(&data.tail, allocator);
            const new_ccd = try allocator.create(ChunkedConsData);
            errdefer allocator.destroy(new_ccd);
            new_ccd.* = .{
                .chunk = data.chunk,  // shared chunk
                .tail = new_tail,
                .allocator = allocator,
                .ref_count = 1,
            };
            if (gc_mod.current_gc) |gc| {
                gc.setObjectType(@as(*anyopaque, @ptrCast(new_ccd)), gc_mod.GCObjectType.chunked_cons_data);
            }
            return .{ .chunked_cons = new_ccd };
        },
        .atom => |data| {
            return atomValueShared(data);
        },
        .future => |data| {
            return futureValueShared(data);
        },
        .promise => |data| {
            return promiseValueShared(data);
        },
        .function => |fn_data| {
            var cloned_arities: std.ArrayListUnmanaged(Arity) = .empty;
            errdefer {
                for (cloned_arities.items) |*ca| {
                    ca.params.deinit(allocator);
                    ca.body.deinit(allocator);
                    if (ca.rest_name) |rn| allocator.free(rn);
                }
                allocator.free(cloned_arities.items);
            }
            try cloned_arities.ensureTotalCapacity(allocator, fn_data.arities.items.len);
            for (fn_data.arities.items) |arity| {
                var cloned_rest: ?[]const u8 = null;
                if (arity.rest_name) |rn| {
                    const duped = try allocator.dupe(u8, rn);
                    tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
                    cloned_rest = duped;
                }
                try cloned_arities.append(allocator, Arity{
                    .params = try list.clone(&arity.params, allocator),
                    .body = try list.clone(&arity.body, allocator),
                    .bytecode = arity.bytecode, // share bytecode pointer (no deep clone needed)
                    .rest_name = cloned_rest,
                });
            }
            var cloned_name: ?[]const u8 = null;
            if (fn_data.name) |n| {
                const duped = try allocator.dupe(u8, n);
                tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
                cloned_name = duped;
            }
            var cloned_doc: ?[]const u8 = null;
            if (fn_data.docstring) |ds| {
                const duped = try allocator.dupe(u8, ds);
                tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
                cloned_doc = duped;
            }
            return try fnValueNamedWithDoc(allocator, cloned_arities, try fn_data.env.clone(allocator), fn_data.is_macro, cloned_name, cloned_doc);
        },
        .builtin_fn => |fn_ptr| return builtinFnValue(fn_ptr),
        .wrapped => |w| return Value{ .wrapped = w },
        .reduced => |data| {
            return try reducedValue(allocator, data.*);
        },
        .record => |rd| {
            const owned_name = try allocator.dupe(u8, rd.type_name);
            tagStringData(@as(*anyopaque, @ptrCast(@constCast(owned_name.ptr))));
            const cloned_fields = try cloneMap(allocator, rd.fields);
            const cloned_extmap = try cloneMap(allocator, rd.extmap);
            const cloned_meta = if (rd.meta) |m|
                try cloneMap(allocator, m)
            else
                null;
            errdefer {
                if (cloned_meta) |cm| {
                    for (cm.items) |*entry| {
                        valueDeinit(&entry.key, allocator);
                        valueDeinit(&entry.value, allocator);
                    }
                    allocator.free(cm.items);
                }
                for (cloned_extmap.items) |*entry| {
                    valueDeinit(&entry.key, allocator);
                    valueDeinit(&entry.value, allocator);
                }
                allocator.free(cloned_extmap.items);
                for (cloned_fields.items) |*entry| {
                    valueDeinit(&entry.key, allocator);
                    valueDeinit(&entry.value, allocator);
                }
                allocator.free(cloned_fields.items);
                allocator.free(owned_name);
            }
            return try recordValue(allocator, owned_name, cloned_fields, cloned_extmap, cloned_meta);
        },
        .exception => |ed| {
            // Exceptions are immutable — share the ExceptionData pointer
            return Value{ .exception = ed };
        },
        .ref => |data| {
            // Refs are shared (like atoms) — clone the data struct
            const new_data = try allocator.create(RefData);
            new_data.* = .{
                .value = try clone(&data.value, allocator),
                .version = data.version,
                .validator = if (data.validator) |v| try clone(&v, allocator) else null,
                .meta = if (data.meta) |m| try clone(&m, allocator) else null,
                .allocator = allocator,
            };
            if (gc_mod.current_gc) |gc| {
                gc.setObjectType(@as(*anyopaque, @ptrCast(new_data)), gc_mod.GCObjectType.ref_data);
            }
            return Value{ .ref = new_data };
        },
        .multimethod => |data| {
            // Multimethods are shared — clone the data struct
            var cloned_table: Map = .empty;
            errdefer {
                for (cloned_table.items) |*entry| {
                    valueDeinit(&entry.key, allocator);
                    valueDeinit(&entry.value, allocator);
                }
                allocator.free(cloned_table.items);
            }
            try cloned_table.ensureTotalCapacity(allocator, data.method_table.items.len);
            for (data.method_table.items) |entry| {
                try cloned_table.append(allocator, .{
                    .key = try clone(&entry.key, allocator),
                    .value = try clone(&entry.value, allocator),
                });
            }
            const new_data = try allocator.create(MultimethodData);
            var cloned_default: ?Value = null;
            if (data.default_dispatch) |v| {
                cloned_default = try clone(&v, allocator);
            }
            new_data.* = .{
                .dispatch_fn = try clone(&data.dispatch_fn, allocator),
                .method_table = cloned_table,
                .pref_table = .empty,
                .default_dispatch = cloned_default,
                .allocator = allocator,
            };
            if (gc_mod.current_gc) |gc| {
                gc.setObjectType(@as(*anyopaque, @ptrCast(new_data)), gc_mod.GCObjectType.multimethod_data);
            }
            return Value{ .multimethod = new_data };
        },
    }
}

/// Clone this Value into a GC-allocated *Value in a single allocation.
/// Shares the underlying data (FnData, StringData, etc.) instead of deep-cloning.
/// All underlying data is GC-tracked, so sharing pointers is safe —
/// the GC will keep everything alive as long as something references it.
pub fn cloneGC(val: *const Value, allocator: Allocator) anyerror!*Value {
    const ptr = try allocator.create(Value);
    ptr.* = val.*;  // Share all data — GC keeps it alive
    return ptr;
}

/// Shallow clone: for functions, creates a new Value sharing the same FnData pointer.
/// For all other types, does a normal deep clone.
/// Use this when you need a Value that won't be mutated but want to avoid
/// the cost of deep-cloning function bodies (e.g., ns-interns returning function refs).
pub fn shallowClone(val: *const Value, allocator: Allocator) anyerror!Value {
    // For types that own heap data (strings, symbols, keywords),
    // we need to duplicate the string so the caller owns an independent copy.
    // For all other types (functions, maps, lists, integers, etc.),
    // we share the Value tag union - the GC handles lifetime.
    switch (val.*) {
        .string => |s| return stringValue(allocator, s),
        .symbol => |s| return symValue(allocator, s),
        .keyword => |s| return keywordValue(allocator, s),
        .exception => |ed| return Value{ .exception = ed }, // share, immutable
        // All other types: share the Value (GC-managed or immediate)
        else => return val.*,
    }
}

/// Share: allocates a *Value on the heap that shares all data with the original.
/// No deep cloning at all - just copies the Value tag union and allocates it.
/// Safe for immutable values (which ALL Clojure values are).
/// The caller owns the *Value allocation but NOT the underlying data.
pub fn shareGC(val: *const Value, allocator: Allocator) anyerror!*Value {
    const ptr = try allocator.create(Value);
    ptr.* = val.*;  // Copy the tag union (shallow - shares all pointers)
    return ptr;
}

pub fn isTruthy(val: Value) bool {
    return switch (val) {
        .nil => false,
        .bool => |b| b,
        .character => true,
        .atom => |data| isTruthy(data.value),
        else => true,
    };
}

pub fn equals(val: Value, other: Value) bool {
    if (std.meta.activeTag(val) != std.meta.activeTag(other)) return false;
    switch (val) {
        .nil => return true,
        .bool => |a| return a == other.bool,
        .integer => |a| return a == other.integer,
        .float => |a| return a == other.float,
        .bigint => |a| {
            return BI.equals(a.*, other.bigint.*);
        },
        .ratio => |a| {
            return RatioMod.equals(a.*, other.ratio.*);
        },
        .decimal => |a| {
            return BD.equals(a.*, other.decimal.*);
        },
        .string => |a| return std.mem.eql(u8, a, other.string),
        .regex => |a| return std.mem.eql(u8, a, other.regex),
        .character => |a| return a == other.character,
        .symbol => |a| return std.mem.eql(u8, a, other.symbol),
        .keyword => |a| return std.mem.eql(u8, a, other.keyword),
        .list => |data| {
            const other_data = other.list;
            if (data.items.items.len != other_data.items.items.len) return false;
            for (data.items.items, 0..) |item, i| {
                if (!equals(item, other_data.items.items[i])) return false;
            }
            return true;
        },
        .vector => |data| {
            const other_data = other.vector;
            if (data.items.items.len != other_data.items.items.len) return false;
            for (data.items.items, 0..) |item, i| {
                if (!equals(item, other_data.items.items[i])) return false;
            }
            return true;
        },
        .map => |data| {
            const other_data = other.map;
            if (data.entries.items.len != other_data.entries.items.len) return false;
            for (data.entries.items) |entry| {
                const other_val = mapLookup(other_data.entries.items, entry.key);
                if (other_val == null or !equals(entry.value, other_val.?)) return false;
            }
            return true;
        },
        .set => |data| {
            const other_data = other.set;
            if (data.items.items.len != other_data.items.items.len) return false;
            for (data.items.items) |item| {
                var found = false;
                for (other_data.items.items) |other_item| {
                    if (equals(item, other_item)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        },
        .queue => |data| {
            const other_data = other.queue;
            if (data.items.items.len != other_data.items.items.len) return false;
            for (data.items.items, 0..) |item, i| {
                if (!equals(item, other_data.items.items[i])) return false;
            }
            return true;
        },
        .cons => |s_data| {
            return equals(s_data.head, other.cons.head) and equals(s_data.tail, other.cons.tail);
        },
        .atom => return false,
        .future => return false,
        .promise => return false,
        .ref => return false, // identity-based like atoms
        .multimethod => return false, // identity-based
        .function => |a| return a == other.function, // identity-based
        .reduced => |s_data| {
            return equals(s_data.*, other.reduced.*);
        },
        .wrapped => |a| return a == other.wrapped,
        .record => |a| {
            const b = other.record;
            if (!std.mem.eql(u8, a.type_name, b.type_name)) return false;
            if (a.fields.items.len != b.fields.items.len) return false;
            for (a.fields.items) |a_entry| {
                const b_val = mapLookup(b.fields.items, a_entry.key);
                if (b_val == null or !equals(a_entry.value, b_val.?)) return false;
            }
            if (a.extmap.items.len != b.extmap.items.len) return false;
            for (a.extmap.items) |a_entry| {
                const b_val = mapLookup(b.extmap.items, a_entry.key);
                if (b_val == null or !equals(a_entry.value, b_val.?)) return false;
            }
            return true;
        },
        .exception => |a| {
            const b = other.exception;
            if (!std.mem.eql(u8, a.message, b.message)) return false;
            if (!std.mem.eql(u8, a.type_kw, b.type_kw)) return false;
            // Compare data maps
            if (!equals(Value{ .map = a.data }, Value{ .map = b.data })) return false;
            // Compare cause chains
            return exceptionCausesEqual(a.cause, b.cause);
        },
        else => return false,
    }
}

/// Look up a key in a map, returning the value or null.
fn mapLookup(m: []MapEntry, key: Value) ?Value {
    for (m) |entry| {
        if (equals(entry.key, key)) return entry.value;
    }
    return null;
}

/// Convert a numeric value to f64 for comparison
fn toNumValue(v: Value) f64 {
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => 0,
    };
}

/// Three-way comparison: returns -1, 0, or 1
pub fn compare(val: Value, other: Value) i64 {
    if (std.meta.activeTag(val) == .nil and std.meta.activeTag(other) == .nil) return 0;
    if (std.meta.activeTag(val) == .nil) return -1;
    if (std.meta.activeTag(other) == .nil) return 1;

    const is_self_num = switch (std.meta.activeTag(val)) {
        .integer, .float, .bigint, .ratio, .decimal => true,
        else => false,
    };
    const is_other_num = switch (std.meta.activeTag(other)) {
        .integer, .float, .bigint, .ratio, .decimal => true,
        else => false,
    };
    if (is_self_num and is_other_num) {
        const a_num = toNumValue(val);
        const b_num = toNumValue(other);
        if (a_num < b_num) return -1;
        if (a_num > b_num) return 1;
        return 0;
    }

    if (std.meta.activeTag(val) == std.meta.activeTag(other)) {
        if (equals(val, other)) return 0;
        switch (std.meta.activeTag(val)) {
            .string => return compareStrings(val.string, other.string),
            .symbol => return compareStrings(val.symbol, other.symbol),
            .keyword => return compareStrings(val.keyword, other.keyword),
            else => {},
        }
        return 1;
    }

    return @as(i64, @intFromEnum(std.meta.activeTag(val))) - @as(i64, @intFromEnum(std.meta.activeTag(other)));
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

pub fn fmt(val: Value, allocator: Allocator) anyerror![]const u8 {
    return switch (val) {
        .nil => allocator.dupe(u8, "nil"),
        .bool => |b| if (b) allocator.dupe(u8, "true") else allocator.dupe(u8, "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bigint => |ptr| return try ptr.toString(allocator),
        .ratio => |ptr| return try ptr.toString(allocator),
        .decimal => |ptr| return try ptr.toString(allocator),
        .string => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .regex => |s| try std.fmt.allocPrint(allocator, "#\"{s}\"", .{s}),
        .character => |c| return try charFmt(c, allocator),
        .symbol => |s| allocator.dupe(u8, s),
        .keyword => |s| try std.fmt.allocPrint(allocator, ":{s}", .{s}),
        .list => |data| return try list.fmt(data.items, allocator),
        .vector => |data| return try vec.fmt(data.items, allocator),
        .map => |data| return try mapFmt(data.entries, allocator),
        .set => |data| return try setFmt(data.items, allocator),
        .queue => |data| return try queueFmt(data.items, allocator),
        .function => allocator.dupe(u8, "#function"),
        .builtin_fn => allocator.dupe(u8, "#builtin"),
        .lazy_seq => allocator.dupe(u8, "#lazy-seq"),
        .cons => |data| return try consFmt(data, allocator),
        .chunk => |data| return try chunkFmt(data, allocator),
        .chunked_cons => |data| return try chunkedConsFmt(data, allocator),
        .atom => |data| {
            const inner_str = try fmt(data.value, allocator);
            defer allocator.free(inner_str);
            return try std.fmt.allocPrint(allocator, "#atom({s})", .{inner_str});
        },
        .future => |data| {
            const state = data.state.load(.monotonic);
            return switch (state) {
                0 => allocator.dupe(u8, "#future(running)"),
                1 => blk: {
                    if (data.result) |*r| {
                        const inner_str = try fmt(r.*, allocator);
                        defer allocator.free(inner_str);
                        break :blk try std.fmt.allocPrint(allocator, "#future({s})", .{inner_str});
                    }
                    break :blk allocator.dupe(u8, "#future(done)");
                },
                2 => blk: {
                    if (data.error_msg) |msg| {
                        break :blk try std.fmt.allocPrint(allocator, "#future(error: {s})", .{msg});
                    }
                    break :blk allocator.dupe(u8, "#future(error)");
                },
                else => allocator.dupe(u8, "#future(unknown)"),
            };
        },
        .promise => |data| {
            const state = data.state.load(.monotonic);
            if (state == 0) return allocator.dupe(u8, "#promise(pending)");
            if (data.value) |*v| {
                const inner_str = try fmt(v.*, allocator);
                defer allocator.free(inner_str);
                return try std.fmt.allocPrint(allocator, "#promise({s})", .{inner_str});
            }
            return allocator.dupe(u8, "#promise(delivered)");
        },
        .reduced => |data| {
            const inner_str = try fmt(data.*, allocator);
            defer allocator.free(inner_str);
            return try std.fmt.allocPrint(allocator, "#reduced({s})", .{inner_str});
        },
        .wrapped => |w| try std.fmt.allocPrint(allocator, "#ptr({X})", .{w}),
        .record => |rd| return try recordFmt(rd, allocator),
        .exception => |ed| return try exceptionFmt(ed, allocator),
        .ref => |data| {
            const inner_str = try fmt(data.value, allocator);
            defer allocator.free(inner_str);
            return try std.fmt.allocPrint(allocator, "#ref({s})", .{inner_str});
        },
        .multimethod => |data| {
            const fn_str = try fmt(data.dispatch_fn, allocator);
            defer allocator.free(fn_str);
            return try std.fmt.allocPrint(allocator, "#multimethod({s})", .{fn_str});
        },
    };
}

/// Format a value directly into an existing buffer (no intermediate string allocation).
/// Used by core_str to avoid allocating per-argument formatted strings.
pub fn fmtToBuffer(val: Value, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    return switch (val) {
        .nil => buf.appendSlice(allocator, "nil"),
        .bool => |b| if (b) buf.appendSlice(allocator, "true") else buf.appendSlice(allocator, "false"),
        .integer => |i| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .bigint => |ptr| {
            const s = try ptr.toString(allocator);
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .ratio => |ptr| {
            const s = try ptr.toString(allocator);
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .decimal => |ptr| {
            const s = try ptr.toString(allocator);
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '"');
        },
        .regex => |s| {
            try buf.appendSlice(allocator, "#\"");
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '"');
        },
        .character => |c| return try charFmtToBuffer(c, buf, allocator),
        .symbol => |s| try buf.appendSlice(allocator, s),
        .keyword => |s| {
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, s);
        },
        .list => |data| return try listFmtToBuffer(data.items, buf, allocator),
        .vector => |data| return try vecFmtToBuffer(data.items, buf, allocator),
        .map => |data| return try mapFmtToBuffer(data.entries, buf, allocator),
        .set => |data| return try setFmtToBuffer(data.items, buf, allocator),
        .queue => |data| return try queueFmtToBuffer(data.items, buf, allocator),
        .function => buf.appendSlice(allocator, "#function"),
        .builtin_fn => buf.appendSlice(allocator, "#builtin"),
        .lazy_seq => buf.appendSlice(allocator, "#lazy-seq"),
        .cons => |data| return try consFmtToBuffer(data, buf, allocator),
        .chunk => |data| return try chunkFmtToBuffer(data, buf, allocator),
        .chunked_cons => |data| return try chunkedConsFmtToBuffer(data, buf, allocator),
        .atom => |data| {
            try buf.appendSlice(allocator, "#atom(");
            try fmtToBuffer(data.value, buf, allocator);
            try buf.append(allocator, ')');
        },
        .future => |data| {
            const state = data.state.load(.monotonic);
            return switch (state) {
                0 => buf.appendSlice(allocator, "#future(running)"),
                1 => blk: {
                    if (data.result) |*r| {
                        try buf.appendSlice(allocator, "#future(");
                        try fmtToBuffer(r.*, buf, allocator);
                        try buf.append(allocator, ')');
                        break :blk {};
                    }
                    break :blk buf.appendSlice(allocator, "#future(done)");
                },
                2 => blk: {
                    if (data.error_msg) |msg| {
                        try buf.appendSlice(allocator, "#future(error: ");
                        try buf.appendSlice(allocator, msg);
                        try buf.append(allocator, ')');
                        break :blk {};
                    }
                    break :blk buf.appendSlice(allocator, "#future(error)");
                },
                else => buf.appendSlice(allocator, "#future(unknown)"),
            };
        },
        .promise => |data| {
            const state = data.state.load(.monotonic);
            if (state == 0) return buf.appendSlice(allocator, "#promise(pending)");
            if (data.value) |*v| {
                try buf.appendSlice(allocator, "#promise(");
                try fmtToBuffer(v.*, buf, allocator);
                try buf.append(allocator, ')');
                return;
            }
            return buf.appendSlice(allocator, "#promise(delivered)");
        },
        .reduced => |data| {
            try buf.appendSlice(allocator, "#reduced(");
            try fmtToBuffer(data.*, buf, allocator);
            try buf.append(allocator, ')');
        },
        .wrapped => |w| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "#ptr({X})", .{w}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .record => |rd| return try recordFmtToBuffer(rd, buf, allocator),
        .exception => |ed| return try exceptionFmtToBuffer(ed, buf, allocator),
        .ref => |data| {
            try buf.appendSlice(allocator, "#ref(");
            try fmtToBuffer(data.value, buf, allocator);
            try buf.append(allocator, ')');
        },
        .multimethod => |data| {
            try buf.appendSlice(allocator, "#multimethod(");
            try fmtToBuffer(data.dispatch_fn, buf, allocator);
            try buf.append(allocator, ')');
        },
    };
}

// ============================================================
// Deep-clone a vm.Map
// ============================================================

/// Format an ExceptionData for printing.
fn exceptionFmt(ed: *const ExceptionData, allocator: Allocator) anyerror![]const u8 {
    return try std.fmt.allocPrint(allocator,
        "#error({s}: \"{s}\")", .{ ed.type_kw, ed.message });
}

/// Format an ExceptionData directly into a buffer.
fn exceptionFmtToBuffer(ed: *const ExceptionData, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.appendSlice(allocator, "#error(");
    try buf.appendSlice(allocator, ed.type_kw);
    try buf.appendSlice(allocator, ": \"");
    try buf.appendSlice(allocator, ed.message);
    try buf.appendSlice(allocator, "\")");
}

/// Compare two cause chains for equality.
fn exceptionCausesEqual(a: ?*ExceptionData, b: ?*ExceptionData) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const a_ex = a.?;
    const b_ex = b.?;
    if (!std.mem.eql(u8, a_ex.message, b_ex.message)) return false;
    if (!std.mem.eql(u8, a_ex.type_kw, b_ex.type_kw)) return false;
    if (!equals(Value{ .map = a_ex.data }, Value{ .map = b_ex.data })) return false;
    return exceptionCausesEqual(a_ex.cause, b_ex.cause);
}

pub fn cloneMap(allocator: Allocator, src: Map) anyerror!Map {
    var dst: Map = .empty;
    errdefer {
        for (dst.items) |*entry| {
            valueDeinit(&entry.key, allocator);
            valueDeinit(&entry.value, allocator);
        }
        allocator.free(dst.items);
    }
    try dst.ensureTotalCapacity(allocator, src.items.len);
    for (src.items) |entry| {
        try dst.append(allocator, .{
            .key = try clone(&entry.key, allocator),
            .value = try clone(&entry.value, allocator),
        });
    }
    if (dst.items.len > 0) {
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(dst.items.ptr)), gc_mod.GCObjectType.map_entries);
        }
    }
    return dst;
}

// ============================================================
// UTF-8 helpers
// ============================================================

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

// ============================================================
// Format helpers
// ============================================================

pub fn setFmt(s: Set, allocator: Allocator) anyerror![]const u8 {
    if (s.items.len == 0) return allocator.dupe(u8, "#{}");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '#');
    try buf.append(allocator, '{');
    for (s.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const s_str = try fmt(item, allocator);
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
        const s_str = try fmt(item, allocator);
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
        const key_s = try fmt(entry.key, allocator);
        defer allocator.free(key_s);
        const val_s = try fmt(entry.value, allocator);
        defer allocator.free(val_s);
        try buf.appendSlice(allocator, key_s);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, val_s);
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// Format a cons cell as a list: (head ...tail_elements...)
pub fn consFmt(data: *const ConsData, allocator: Allocator) anyerror![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '(');

    var head_ref: *const Value = &data.head;
    var tail_ref: *const Value = &data.tail;
    var first = true;

    while (true) {
        if (!first) try buf.append(allocator, ' ');
        const head_str = try fmt(head_ref.*, allocator);
        defer allocator.free(head_str);
        try buf.appendSlice(allocator, head_str);
        first = false;

        switch (tail_ref.*) {
            .cons => {
                const tail_data = tail_ref.cons;
                head_ref = &tail_data.head;
                tail_ref = &tail_data.tail;
            },
            .list => {
                for (tail_ref.list.items.items) |item| {
                    try buf.append(allocator, ' ');
                    const item_str = try fmt(item, allocator);
                    defer allocator.free(item_str);
                    try buf.appendSlice(allocator, item_str);
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, "#lazy-seq");
                break;
            },
            else => {
                try buf.append(allocator, ' ');
                try buf.append(allocator, '.');
                try buf.append(allocator, ' ');
                const tail_str = try fmt(tail_ref.*, allocator);
                defer allocator.free(tail_str);
                try buf.appendSlice(allocator, tail_str);
                break;
            },
        }
    }

    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

/// Format a ChunkData as a parenthesized list of elements.
fn chunkFmt(data: *const ChunkData, allocator: Allocator) anyerror![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '(');
    var i: usize = data.off;
    while (i < data.end) : (i += 1) {
        if (i > data.off) try buf.append(allocator, ' ');
        const s = try fmt(data.items[i], allocator);
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

/// Format a ChunkedConsData: chunk elements followed by tail.
fn chunkedConsFmt(data: *const ChunkedConsData, allocator: Allocator) anyerror![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '(');
    var i: usize = data.chunk.off;
    while (i < data.chunk.end) : (i += 1) {
        if (i > data.chunk.off) try buf.append(allocator, ' ');
        const s = try fmt(data.chunk.items[i], allocator);
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    if (std.meta.activeTag(data.tail) != .nil) {
        try buf.append(allocator, ' ');
        const tail_str = try fmt(data.tail, allocator);
        defer allocator.free(tail_str);
        try buf.appendSlice(allocator, tail_str);
    }
    try buf.append(allocator, ')');
    return buf.toOwnedSlice(allocator);
}

/// Format a RecordData as #ns.RecordName{:field1 val1 :field2 val2 ...}
fn recordFmt(rd: *const RecordData, allocator: Allocator) anyerror![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '#');
    try buf.appendSlice(allocator, rd.type_name);
    try buf.append(allocator, '{');

    for (rd.fields.items, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const key_s = try fmt(entry.key, allocator);
        defer allocator.free(key_s);
        const val_s = try fmt(entry.value, allocator);
        defer allocator.free(val_s);
        try buf.appendSlice(allocator, key_s);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, val_s);
    }

    for (rd.extmap.items, 0..) |entry, i| {
        if (rd.fields.items.len > 0 or i > 0) try buf.append(allocator, ' ');
        const key_s = try fmt(entry.key, allocator);
        defer allocator.free(key_s);
        const val_s = try fmt(entry.value, allocator);
        defer allocator.free(val_s);
        try buf.appendSlice(allocator, key_s);
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, val_s);
    }

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// Format a character value as \x or \newline, \space, etc.
fn charFmt(c: u21, allocator: Allocator) anyerror![]const u8 {
    if (c == 9) return allocator.dupe(u8, "\\tab");
    if (c == 10) return allocator.dupe(u8, "\\newline");
    if (c == 13) return allocator.dupe(u8, "\\return");
    if (c == 32) return allocator.dupe(u8, "\\space");
    if (c == 12) return allocator.dupe(u8, "\\formfeed");

    if (c < 128) {
        const ch = @as(u8, @intCast(c));
        return std.fmt.allocPrint(allocator, "\\{c}", .{ch});
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '\\');
    var utf8_buf: [4]u8 = undefined;
    const utf8_len = std.unicode.utf8Encode(c, &utf8_buf) catch return error.InvalidUnicode;
    try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
    return buf.toOwnedSlice(allocator);
}

/// Format a character value directly into a buffer.
fn charFmtToBuffer(c: u21, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    if (c == 9) return buf.appendSlice(allocator, "\\tab");
    if (c == 10) return buf.appendSlice(allocator, "\\newline");
    if (c == 13) return buf.appendSlice(allocator, "\\return");
    if (c == 32) return buf.appendSlice(allocator, "\\space");
    if (c == 12) return buf.appendSlice(allocator, "\\formfeed");

    if (c < 128) {
        const ch = @as(u8, @intCast(c));
        var tmp: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "\\{c}", .{ch}) catch unreachable;
        return buf.appendSlice(allocator, s);
    }

    try buf.append(allocator, '\\');
    var utf8_buf: [4]u8 = undefined;
    const utf8_len = std.unicode.utf8Encode(c, &utf8_buf) catch return error.InvalidUnicode;
    try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
}

// ============================================================
// Buffer-based formatting helpers (no intermediate string allocation)
// ============================================================

/// Format a list directly into a buffer.
fn listFmtToBuffer(items: list.List, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.append(allocator, '(');
    for (items.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try fmtToBuffer(item, buf, allocator);
    }
    try buf.append(allocator, ')');
}

/// Format a vector directly into a buffer.
fn vecFmtToBuffer(items: vec.Vector, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.append(allocator, '[');
    for (items.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try fmtToBuffer(item, buf, allocator);
    }
    try buf.append(allocator, ']');
}

/// Format a set directly into a buffer.
fn setFmtToBuffer(s: Set, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.appendSlice(allocator, "#{");
    for (s.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try fmtToBuffer(item, buf, allocator);
    }
    try buf.append(allocator, '}');
}

/// Format a queue directly into a buffer.
fn queueFmtToBuffer(q: Queue, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.appendSlice(allocator, "#queue(");
    for (q.items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try fmtToBuffer(item, buf, allocator);
    }
    try buf.append(allocator, ')');
}

/// Format a map directly into a buffer.
fn mapFmtToBuffer(m: Map, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.append(allocator, '{');
    for (m.items, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try fmtToBuffer(entry.key, buf, allocator);
        try buf.append(allocator, ' ');
        try fmtToBuffer(entry.value, buf, allocator);
    }
    try buf.append(allocator, '}');
}

/// Format a cons cell directly into a buffer.
fn consFmtToBuffer(data: *const ConsData, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.append(allocator, '(');

    var head_ref: *const Value = &data.head;
    var tail_ref: *const Value = &data.tail;
    var first = true;

    while (true) {
        if (!first) try buf.append(allocator, ' ');
        try fmtToBuffer(head_ref.*, buf, allocator);
        first = false;

        switch (tail_ref.*) {
            .cons => {
                const tail_data = tail_ref.cons;
                head_ref = &tail_data.head;
                tail_ref = &tail_data.tail;
            },
            .list => {
                for (tail_ref.list.items.items) |item| {
                    try buf.append(allocator, ' ');
                    try fmtToBuffer(item, buf, allocator);
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, "#lazy-seq");
                break;
            },
            else => {
                try buf.append(allocator, ' ');
                try buf.append(allocator, '.');
                try buf.append(allocator, ' ');
                try fmtToBuffer(tail_ref.*, buf, allocator);
                break;
            },
        }
    }

    try buf.append(allocator, ')');
}

/// Format a ChunkData directly into a buffer.
fn chunkFmtToBuffer(data: *const ChunkData, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.append(allocator, '(');
    var i: usize = data.off;
    while (i < data.end) : (i += 1) {
        if (i > data.off) try buf.append(allocator, ' ');
        try fmtToBuffer(data.items[i], buf, allocator);
    }
    try buf.append(allocator, ')');
}

/// Format a ChunkedConsData directly into a buffer.
fn chunkedConsFmtToBuffer(data: *const ChunkedConsData, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.append(allocator, '(');
    var i: usize = data.chunk.off;
    while (i < data.chunk.end) : (i += 1) {
        if (i > data.chunk.off) try buf.append(allocator, ' ');
        try fmtToBuffer(data.chunk.items[i], buf, allocator);
    }
    if (std.meta.activeTag(data.tail) != .nil) {
        try buf.append(allocator, ' ');
        try fmtToBuffer(data.tail, buf, allocator);
    }
    try buf.append(allocator, ')');
}

/// Format a RecordData directly into a buffer.
fn recordFmtToBuffer(rd: *const RecordData, buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) anyerror!void {
    try buf.append(allocator, '#');
    try buf.appendSlice(allocator, rd.type_name);
    try buf.append(allocator, '{');

    for (rd.fields.items, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try fmtToBuffer(entry.key, buf, allocator);
        try buf.append(allocator, ' ');
        try fmtToBuffer(entry.value, buf, allocator);
    }

    for (rd.extmap.items, 0..) |entry, i| {
        if (rd.fields.items.len > 0 or i > 0) try buf.append(allocator, ' ');
        try fmtToBuffer(entry.key, buf, allocator);
        try buf.append(allocator, ' ');
        try fmtToBuffer(entry.value, buf, allocator);
    }

    try buf.append(allocator, '}');
}

// ============================================================
// recordValue constructor (defined after Value for forward reference)
// ============================================================

/// Create a record value.
pub fn recordValue(
    allocator: Allocator,
    type_name: []const u8,
    fields: Map,
    extmap: Map,
    meta: ?Map,
) anyerror!Value {
    const owned_name = try allocator.dupe(u8, type_name);
    const owned_meta = if (meta) |m| try cloneMap(allocator, m) else null;
    errdefer {
        if (owned_meta) |om| {
            for (om.items) |*entry| {
                valueDeinit(&entry.key, allocator);
                valueDeinit(&entry.value, allocator);
            }
            allocator.free(om.items);
        }
        allocator.free(owned_name);
    }
    if (fields.items.len > 0) {
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(fields.items.ptr)), gc_mod.GCObjectType.map_entries);
        }
    }
    if (extmap.items.len > 0) {
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(extmap.items.ptr)), gc_mod.GCObjectType.map_entries);
        }
    }
    if (owned_meta) |om| {
        if (om.items.len > 0) {
            if (gc_mod.current_gc) |gc| {
                gc.setObjectType(@as(*anyopaque, @ptrCast(om.items.ptr)), gc_mod.GCObjectType.map_entries);
            }
        }
    }
    const rd = try allocator.create(RecordData);
    errdefer allocator.destroy(rd);
    rd.* = .{
        .type_name = owned_name,
        .fields = fields,
        .extmap = extmap,
        .meta = owned_meta,
        .allocator = allocator,
    };
    // Tag type_name string so GC doesn't misidentify it as a Value
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(owned_name.ptr))));
    if (gc_mod.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(rd)), gc_mod.GCObjectType.record_data);
    }
    return .{ .record = rd };
}

// ============================================================
// Exception constructors
// ============================================================

/// Create an exception value from components.
/// message and type_kw are owned (duped strings).
/// data is a SHARED pointer to MapData — never cloned.
/// cause is a SHARED pointer to ExceptionData — never cloned.
pub fn exceptionValue(
    allocator: Allocator,
    message: []const u8,
    data: *MapData,
    cause: ?*ExceptionData,
    type_kw: []const u8,
) anyerror!Value {
    const ed = try allocator.create(ExceptionData);
    errdefer allocator.destroy(ed);
    ed.* = .{
        .message = try allocator.dupe(u8, message),
        .data = data,           // SHARED — immutable Clojure map, never clone
        .cause = cause,         // SHARED — immutable ExceptionData, never clone
        .type_kw = try allocator.dupe(u8, type_kw),
        .allocator = allocator,
    };
    // Tag strings for GC
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(ed.message.ptr))));
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(ed.type_kw.ptr))));
    // Tag ExceptionData for GC
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(ed)), gc_mod.GCObjectType.exception_data);
    }
    return .{ .exception = ed };
}

/// Wrap an existing ExceptionData pointer into a Value (shared, no clone).
/// Used by ex-cause and by try/catch binding.
/// Cannot fail — just wraps a pointer.
pub fn exceptionValueFromData(ed: *ExceptionData) Value {
    return Value{ .exception = ed };
}

// ============================================================
// Internal helper for PersistentHashMap keys (non-owned string)
// ============================================================

fn symKey(s: []const u8) Value {
    return .{ .symbol = s };
}

// ============================================================
// Environment
// ============================================================

pub const Env = struct {
    allocator: Allocator,
    entries: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    parent: ?*Env = null,
    ns_manager: ?*NamespaceManager = null,
    referred_names: std.ArrayListUnmanaged([]const u8) = .empty,
    // Tracks symbols explicitly defined/owned in this namespace (def, defn, defmacro).
    // Used by ns-interns/ns-publics to distinguish owned vars from copied/referred ones.
    // Uses ArrayList instead of HashMap to avoid GC tracking issues with internal memory.
    owned_symbols: std.ArrayListUnmanaged([]const u8) = .empty,
    // Metadata map: stores metadata maps for symbols defined in this namespace.
    // Keys are symbols, values are metadata maps (Value maps).
    // Used by alter-meta!, meta on vars, and def with metadata-bearing symbols.
    metas: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    // Dynamic variable bindings: stores symbol → value mappings for dynamic vars.
    // Used by binding to make dynamic bindings visible across function calls.
    // Checked before normal entries in Env.get().
    dynamic_vars: phm.PersistentHashMap = phm.PersistentHashMap.empty(),

    pub fn init(allocator: Allocator) Env {
        return .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = null,
            .ns_manager = null,
            .referred_names = .empty,
            .owned_symbols = .empty,
            .metas = phm.PersistentHashMap.empty(),
            .dynamic_vars = phm.PersistentHashMap.empty(),
        };
    }

    pub fn deinit(self: *Env, allocator: Allocator) void {
        // Do NOT null out entries.root — the HAMT is structurally shared
        // and GC-managed. Nulling it would corrupt other Envs that share
        // the same HAMT nodes (e.g., closures captured via Env.clone).
        // The GC will reclaim unreachable HAMT nodes during sweep.
        self.entries.count = 0;
        self.entries.has_null = false;
        // Do NOT free referred_names here — it is GC-managed.
        // The GC will reclaim the buffer and strings during sweep.
        // Freeing here causes use-after-free when child threads share
        // the buffer via shallow Env.clone (even though clone sets
        // referred_names to .empty, the original env's buffer could
        // be freed while the GC hasn't swept it yet).
        self.referred_names.items = &.{};
        // Free owned_symbols strings (they are heap-allocated)
        for (self.owned_symbols.items) |key| {
            allocator.free(key);
        }
        allocator.free(self.owned_symbols.items);
        self.owned_symbols = .empty;
        _ = self.parent;
        _ = self.ns_manager;
    }

    pub fn clone(self: *const Env, allocator: Allocator) anyerror!Env {
        return .{
            .allocator = allocator,
            .entries = self.entries,
            .parent = self.parent,
            .ns_manager = self.ns_manager,
            .referred_names = .empty,
            .owned_symbols = .empty,
            .metas = self.metas,
            .dynamic_vars = self.dynamic_vars,
        };
    }

    /// Mark a symbol as owned by this namespace (called by bindInCurrentNamespace).
    pub fn markOwned(self: *Env, name: []const u8) anyerror!void {
        // Skip if already present
        for (self.owned_symbols.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.owned_symbols.append(self.allocator, owned);
    }

    /// Check if a symbol is owned by this namespace.
    pub fn isOwned(self: *const Env, name: []const u8) bool {
        for (self.owned_symbols.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }

    /// Mark all current entries in this env as owned.
    /// Used after registering built-in functions that bypass bindInCurrentNamespace.
    pub fn markAllOwned(self: *Env) anyerror!void {
        var it = self.entries.entryIterator();
        while (it.next()) |entry| {
            if (std.meta.activeTag(entry.key) == .symbol) {
                try self.markOwned(entry.key.symbol);
            }
        }
    }

    pub fn put(self: *Env, name: []const u8, value: Value) anyerror!void {
        const allocator = self.allocator;
        const key = phm.sym(name);
        // mapAssoc returns a NEW PersistentHashMap (structural sharing via HAMT).
        // Assign directly without clearing old fields first — clearing would
        // corrupt any other Env that shares the same HAMT via shallow clone.
        self.entries = try self.entries.mapAssoc(allocator, key, value);
        // NOTE: Do NOT call valueDeinit on the stored value.
        // The HashMap stores a shallow copy of the Value union. For GC-managed
        // types (lazy_seq, chunked_cons, function, etc.), valueDeinit would free
        // the shared heap data, corrupting the HashMap's copy. The GC handles
        // cleanup of unreachable objects. For non-GC types, the caller retains
        // ownership of their original value.
    }

    pub fn get(self: *Env, name: []const u8) ?Value {
        // Check namespace manager dynamic vars first (visible across all function calls)
        // Walk up parent chain to find ns_manager (function envs may have null ns_manager).
        var dyn_cursor: ?*Env = self;
        while (dyn_cursor) |e| : (dyn_cursor = e.parent) {
            if (e.ns_manager) |ns_mgr| {
                if (!ns_mgr.dynamic_vars.isEmpty()) {
                    const found = ns_mgr.dynamic_vars.find(phm.sym(name));
                    if (found) |val| return val;
                }
                break;
            }
        }
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

    /// Store metadata map for a symbol in this namespace.
    pub fn putMeta(self: *Env, name: []const u8, meta_map: Value) anyerror!void {
        const allocator = self.allocator;
        const key = phm.sym(name);
        self.metas = try self.metas.mapAssoc(allocator, key, meta_map);
    }

    /// Get metadata map for a symbol from this namespace (no parent lookup).
    pub fn getMeta(self: *Env, name: []const u8) ?Value {
        if (!self.metas.isEmpty()) {
            return self.metas.find(phm.sym(name));
        }
        return null;
    }

    /// Set a dynamic variable binding in this namespace.
    pub fn putDynamicVar(self: *Env, name: []const u8, val: Value) anyerror!void {
        const allocator = self.allocator;
        const key = phm.sym(name);
        self.dynamic_vars = try self.dynamic_vars.mapAssoc(allocator, key, val);
    }

    /// Get a dynamic variable binding from this namespace.
    pub fn getDynamicVar(self: *Env, name: []const u8) ?Value {
        if (!self.dynamic_vars.isEmpty()) {
            return self.dynamic_vars.find(phm.sym(name));
        }
        return null;
    }

    /// Remove a dynamic variable binding from this namespace.
    pub fn removeDynamicVar(self: *Env, name: []const u8) anyerror!void {
        const allocator = self.allocator;
        const key = phm.sym(name);
        self.dynamic_vars = try self.dynamic_vars.mapWithout(allocator, key);
    }

    pub fn has(self: *Env, name: []const u8) bool {
        var current: ?*Env = self;
        while (current) |env| {
            if (env.entries.containsKey(phm.sym(name))) return true;
            current = env.parent;
        }
        return false;
    }

    pub fn getPtr(self: *Env, name: []const u8) ?*const Value {
        var current: ?*Env = self;
        while (current) |env| {
            if (!env.entries.isEmpty()) {
                if (env.entries.findPtr(phm.sym(name))) |ptr| return ptr;
            }
            current = env.parent;
        }
        return null;
    }
};

// ============================================================
// Source location for error reporting and stack traces.
// Defined here so it can be shared between value.zig (Frame) and eval.zig.
// ============================================================

pub const SourceLoc = struct {
    file: []const u8 = "",
    line: usize = 0, // 1-based line number (0 = unknown)

    pub fn isEmpty(self: SourceLoc) bool {
        return self.file.len == 0;
    }
};

// ============================================================
// Frame — Virtual Stack Frame (Phase 3: Memory Model Overhaul)
// ============================================================
//
// A Frame is a GC-managed heap object representing one level of
// evaluation scope (function call, let binding, loop, etc.).
// Frames form a linked chain via parent pointers, replacing
// deep C-stack recursion with bounded heap allocation.
//
// Design (per MEMORY_MODEL.md):
// - No full copies: child frame stores only new bindings + overrides
// - Parent pointer: child knows its parent for scope lookup
// - Child tracking: parent tracks children for lifecycle + immutability
// - Overlay-only writes: put() writes only to current overlay
// - Memoization: recently looked-up parent values are cached
//
// Frame.get() walks: overlay → parent.overlay → ... → root Env
// Frame.put() writes only to overlay (never to parent)

/// Maximum number of entries in a Frame's memoization cache.
/// When exceeded, the cache is cleared entirely (simple eviction strategy).
/// 64 entries covers typical tight loops accessing parent-level bindings.
/// At 10,000 recursion depth this bounds per-frame overhead to ~3KB.
pub const MEMO_CACHE_MAX: usize = 64;

pub const Frame = struct {
    parent: ?*Frame = null,
    // Children tracking: parent knows which frames reference it.
    // Used for lifecycle management and parent immutability enforcement.
    children: std.ArrayListUnmanaged(*Frame) = .empty,
    // Overlay: only bindings introduced/overridden in this frame.
    // Uses PersistentHashMap for GC integration (HAMT nodes are scanned).
    overlay: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    // Memoization cache for parent-chain lookups.
    // Stores symbol name → Value for recently accessed parent-level bindings.
    // Prevents O(depth) traversal on every lookup in tight loops.
    // Bounded by MEMO_CACHE_MAX — cleared entirely when limit is exceeded.
    memo_cache: std.StringHashMapUnmanaged(Value) = .empty,
    // Root namespace environment (terminates the lookup chain).
    // Frame overlay → parent overlay → ... → root_env
    root_env: *Env,
    // The function being executed in this frame (for stack traces).
    function_ref: ?Value = null,
    // Source location of the call site.
    src_loc: SourceLoc = .{},
    // True if any child frame is still alive.
    // Used for parent immutability enforcement (Phase 7).
    has_active_children: bool = false,
    // The function body items to evaluate (for trampoline frames).
    // Phase 2: stores a slice reference into arity.body.items instead of
    // cloning into a temporary list Value. The body is part of the function
    // definition (immutable, permanently rooted) — no clone needed.
    // null for scope frames (let, loop, binding).
    body_form_items: ?[]const Value = null,
    // Source line number for the body (for error reporting).
    body_form_src_line: usize = 0,
    // True for frames created by callFunction (function call frames).
    // When true, symbol lookup skips the parent chain and goes directly
    // to root_env (the function's captured closure environment).
    // This prevents caller's bindings from shadowing closure captures.
    is_function_frame: bool = false,

    /// Create a new Frame with the given allocator, optional parent,
    /// and root namespace environment.
    pub fn init(_: Allocator, parent_frame: ?*Frame, root_env_ptr: *Env) Frame {
        return .{
            .parent = parent_frame,
            .root_env = root_env_ptr,
        };
    }

    /// Put a value into the memo cache, respecting the size limit.
    /// If the cache exceeds MEMO_CACHE_MAX entries, clear it entirely
    /// before inserting. This is a simple eviction strategy that
    /// bounds per-frame memory while keeping hot-path lookups fast.
    fn _memoCachePut(self: *Frame, name: []const u8, value: Value) void {
        const allocator = self.root_env.allocator;
        // Evict if cache is full (check before insert to avoid exceeding limit)
        if (self.memo_cache.count() >= MEMO_CACHE_MAX) {
            self.memo_cache.deinit(allocator);
            self.memo_cache = .{};
        }
        self.memo_cache.put(allocator, name, value) catch {};
    }

    /// Look up a binding by name.
    /// Walks: overlay → parent.overlay → ... → root_env.
    /// Memoizes results from parent chain lookups (bounded by MEMO_CACHE_MAX).
    pub fn get(self: *Frame, name: []const u8) ?Value {
        // 0. Check namespace manager dynamic vars first (always visible)
        // Dynamic bindings must be checked before memo cache since they can
        // change at runtime and the memo cache would return stale values.
        // Walk up parent chain to find ns_manager (function frames may have null ns_manager).
        {
            var env_cursor: ?*Env = self.root_env;
            while (env_cursor) |e| : (env_cursor = e.parent) {
                if (e.ns_manager) |ns_mgr| {
                    if (!ns_mgr.dynamic_vars.isEmpty()) {
                        const dyn_found = ns_mgr.dynamic_vars.find(phm.sym(name));
                        if (dyn_found) |val| return val;
                    }
                    break;
                }
            }
        }
        // 1. Check memo cache first (fast path for repeated lookups)
        if (self.memo_cache.get(name)) |cached| {
            return cached;
        }
        // 2. Check own overlay
        if (!self.overlay.isEmpty()) {
            const found = self.overlay.find(phm.sym(name));
            if (found) |val| return val;
        }
        // 3. Walk parent chain (only for scope frames, not function call frames)
        // Function call frames have captured environment in root_env - parent chain
        // would incorrectly expose caller's bindings which shadow closure captures.
        if (!self.is_function_frame) {
            var current: ?*Frame = self.parent;
            while (current) |frame| {
                if (!frame.overlay.isEmpty()) {
                    const found = frame.overlay.find(phm.sym(name));
                    if (found) |val| {
                        // Memoize for next time (respects MEMO_CACHE_MAX)
                        self._memoCachePut(name, val);
                        return val;
                    }
                }
                current = frame.parent;
            }
        }
        // 4. Fall back to root namespace environment
        const root_val = self.root_env.get(name);
        if (root_val) |val| {
            // Memoize for next time (respects MEMO_CACHE_MAX)
            self._memoCachePut(name, val);
            return val;
        }
        return null;
    }

    /// Like get() but returns a pointer to the stored Value instead of a copy.
    /// Used by the evaluator to avoid unnecessary cloneGC allocations.
    /// The returned pointer is valid as long as the binding is not modified.
    pub fn getPtr(self: *Frame, name: []const u8) ?*const Value {
        // 1. Check own overlay
        if (!self.overlay.isEmpty()) {
            if (self.overlay.findPtr(phm.sym(name))) |ptr| return ptr;
        }
        // 2. Walk parent chain (only for scope frames, not function call frames)
        if (!self.is_function_frame) {
            var current: ?*Frame = self.parent;
            while (current) |frame| {
                if (!frame.overlay.isEmpty()) {
                    if (frame.overlay.findPtr(phm.sym(name))) |ptr| return ptr;
                }
                current = frame.parent;
            }
        }
        // 3. Fall back to root namespace environment
        return self.root_env.getPtr(name);
    }

    /// Check if a binding exists (anywhere in the chain).
    pub fn has(self: *Frame, name: []const u8) bool {
        if (!self.overlay.isEmpty() and self.overlay.containsKey(phm.sym(name))) return true;
        // Function call frames skip parent chain (same as get)
        if (!self.is_function_frame) {
            var current: ?*Frame = self.parent;
            while (current) |frame| {
                if (!frame.overlay.isEmpty() and frame.overlay.containsKey(phm.sym(name))) return true;
                current = frame.parent;
            }
        }
        return self.root_env.has(name);
    }

    /// Check if a binding exists in the parent chain only (not in current overlay).
    /// Used by put() to enforce parent immutability: if this frame has active children
    /// and the binding exists in a parent, we must not shadow it because child frames
    /// may be depending on the parent's value.
    /// For function call frames, skips frame parent chain (caller's bindings not visible).
    fn _existsInParentChain(self: *Frame, name: []const u8) bool {
        // Function call frames skip frame parent chain
        if (!self.is_function_frame) {
            var current: ?*Frame = self.parent;
            while (current) |frame| {
                if (!frame.overlay.isEmpty() and frame.overlay.containsKey(phm.sym(name))) return true;
                current = frame.parent;
            }
        }
        return self.root_env.has(name);
    }

    /// Check if a binding exists in the current frame's overlay only.
    /// Used by set! to verify the binding is local to this frame.
    pub fn hasInOverlay(self: *Frame, name: []const u8) bool {
        return !self.overlay.isEmpty() and self.overlay.containsKey(phm.sym(name));
    }

    /// Bind a name to a value in this frame's overlay only.
    /// Never writes to parent overlays (immutability invariant).
    ///
    /// Parent immutability check (MEMORY_MODEL.md R11):
    /// If this frame has active children AND the name exists in the parent chain,
    /// reject the write. Child frames may be depending on the parent's value.
    /// If the name is only in the current overlay, allow the write (local rebinding).
    ///
    /// Also updates the memo cache (respects MEMO_CACHE_MAX).
    pub fn put(self: *Frame, name: []const u8, value: Value) anyerror!void {
        // Parent immutability enforcement (Phase 7)
        if (self.has_active_children and self._existsInParentChain(name)) {
            return error.ParentImmutabilityViolation;
        }
        const allocator = self.root_env.allocator;
        const new_overlay = try self.overlay.mapAssoc(allocator, phm.sym(name), value);
        self.overlay = new_overlay;
        // Update memo cache (respects MEMO_CACHE_MAX)
        self._memoCachePut(name, value);
    }

    /// Create a child frame with this frame as parent.
    /// The child inherits the lookup chain but has its own overlay.
    pub fn createChild(self: *Frame, allocator: Allocator) anyerror!*Frame {
        const frame_ptr = try allocator.create(Frame);
        errdefer allocator.destroy(frame_ptr);
        frame_ptr.* = Frame.init(allocator, self, self.root_env);
        // Tag for GC scanning
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(frame_ptr)), gc_mod.GCObjectType.frame);
        }
        // Track child in parent
        try self.children.append(allocator, frame_ptr);
        self.has_active_children = true;
        return frame_ptr;
    }

    /// Remove this frame from its parent's children list.
    /// Called when a frame is logically popped (function returns).
    pub fn pop(self: *Frame, allocator: Allocator) void {
        if (self.parent) |parent| {
            // Remove self from parent's children list
            var i: usize = 0;
            while (i < parent.children.items.len) : (i += 1) {
                if (parent.children.items[i] == self) {
                    _ = parent.children.swapRemove(i);
                    break;
                }
            }
            // Update parent's has_active_children flag
            parent.has_active_children = parent.children.items.len > 0;
        }
        // Clean up this frame's resources
        self.body_form_items = null;
        self.body_form_src_line = 0;
        self.overlay.root = null;
        self.overlay.count = 0;
        self.overlay.has_null = false;
        self.memo_cache.deinit(allocator);
        // Safe cleanup: free backing array and reset to empty slice.
        // Do NOT use deinit() which sets items to undefined (breaks GC scanning).
        if (self.children.items.len > 0) {
            allocator.free(self.children.items);
        }
        self.children.items = &.{};
        self.children.capacity = 0;
    }

    /// Detach this frame from its parent's children list.
    /// Does NOT clear the overlay — child frames on the trampoline stack
    /// may still need to walk the parent chain through this frame.
    /// GC will reclaim the frame and its overlay when no references remain.
    pub fn detachFromParent(self: *Frame) void {
        // Parent may have already been deinited (its memory freed).
        // We can't safely access it, so just clean up our own resources.
        // The GC will handle the rest.
        const allocator = self.root_env.allocator;
        // Clear children list safely — do NOT use deinit() which sets items to undefined.
        // GC may still scan this frame (parent's children list may reference it),
        // so items must be a valid (empty) slice, not undefined.
        if (self.children.items.len > 0) {
            allocator.free(self.children.items);
        }
        self.children.items = &.{};
        self.children.capacity = 0;
        // Clear memo cache (not needed after frame is done)
        self.memo_cache.deinit(allocator);
        self.memo_cache = .{};
        // Clear body_form_items (body was already evaluated, no longer needed)
        self.body_form_items = null;
        self.body_form_src_line = 0;
        // Do NOT clear overlay — child frames on trampoline may still walk through us.
        // Do NOT null parent — child frames need the parent chain.
    }

    /// Release this frame from its parent's children list WITHOUT clearing
    /// the frame's own data. Used when a special form (let, letfn, binding)
    /// returns a trampoline — child frames on the trampoline stack may still
    /// need to walk the parent chain through this frame.
    /// GC will reclaim the frame once no references remain.
    pub fn releaseFromParent(self: *Frame, allocator: Allocator) void {
        // Remove self from parent's children list so parent doesn't hold reference
        if (self.parent) |parent| {
            var i: usize = 0;
            while (i < parent.children.items.len) : (i += 1) {
                if (parent.children.items[i] == self) {
                    const last = parent.children.items.len - 1;
                    parent.children.items[i] = parent.children.items[last];
                    parent.children.items.len = last;
                    break;
                }
            }
            // Check if parent still has active children
            if (parent.children.items.len == 0) {
                parent.has_active_children = false;
            }
        }
        // Clear our own children list (they should have been detached already)
        // Safe cleanup: do NOT use deinit() which sets items to undefined.
        if (self.children.items.len > 0) {
            allocator.free(self.children.items);
        }
        self.children.items = &.{};
        self.children.capacity = 0;
        // Do NOT clear overlay, memo_cache, or parent pointer —
        // child frames may still need to walk through us.
    }

    /// Full cleanup (deinit + destroy). Used at thread exit.
    pub fn deinit(self: *Frame, allocator: Allocator) void {
        self.pop(allocator);
        allocator.destroy(self);
    }
};

// ============================================================
// Namespace Manager
// ============================================================

pub const NamespaceManager = struct {
    allocator: Allocator,
    namespaces: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    current_ns: []const u8 = undefined,
    aliases: phm.PersistentHashMap = phm.PersistentHashMap.empty(),
    classpath: std.ArrayListUnmanaged([]const u8) = .empty,
    loaded_libs: std.ArrayListUnmanaged([]const u8) = .empty,
    // Dynamic variable bindings shared across all namespaces.
    // Used by binding to make dynamic bindings visible across function calls.
    dynamic_vars: phm.PersistentHashMap = phm.PersistentHashMap.empty(),

    pub fn init(allocator: Allocator) anyerror!*NamespaceManager {
        const mgr = try allocator.create(NamespaceManager);
        mgr.* = .{ .allocator = allocator };
        if (gc_mod.current_gc) |gc_inst| {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(mgr)), gc_mod.GCObjectType.namespace_manager);
        }
        mgr.current_ns = try allocator.dupe(u8, "user");
        _ = try mgr.createNamespace("user");
        return mgr;
    }

    pub fn deinit(self: *NamespaceManager) void {
        const allocator = self.allocator;
        var ns_it = self.namespaces.entryIterator();
        while (ns_it.next()) |entry| {
            const env_ptr: *Env = unwrapPtr(*Env, entry.val);
            env_ptr.deinit(allocator);
            allocator.destroy(env_ptr);
        }
        self.namespaces.deinit(allocator);
        self.aliases.deinit(allocator);
        for (self.classpath.items) |dir| {
            allocator.free(dir);
        }
        allocator.free(self.classpath.items);
        for (self.loaded_libs.items) |lib| {
            allocator.free(lib);
        }
        self.loaded_libs.deinit(allocator);
        allocator.free(self.current_ns);
        allocator.destroy(self);
    }

    /// Set a dynamic variable binding in the namespace manager.
    pub fn putDynamicVar(self: *NamespaceManager, name: []const u8, val: Value) anyerror!void {
        const allocator = self.allocator;
        const key = phm.sym(name);
        self.dynamic_vars = try self.dynamic_vars.mapAssoc(allocator, key, val);
    }

    /// Get a dynamic variable binding from the namespace manager.
    pub fn getDynamicVar(self: *NamespaceManager, name: []const u8) ?Value {
        if (!self.dynamic_vars.isEmpty()) {
            return self.dynamic_vars.find(phm.sym(name));
        }
        return null;
    }

    /// Remove a dynamic variable binding from the namespace manager.
    pub fn removeDynamicVar(self: *NamespaceManager, name: []const u8) anyerror!void {
        const allocator = self.allocator;
        const key = phm.sym(name);
        self.dynamic_vars = try self.dynamic_vars.mapWithout(allocator, key);
    }

    pub fn createNamespace(self: *NamespaceManager, name: []const u8) anyerror!*Env {
        const key = symKey(name);
        if (self.namespaces.find(key)) |existing_val| {
            return unwrapPtr(*Env, existing_val);
        }

        const ns_env = try self.allocator.create(Env);
        ns_env.* = Env.init(self.allocator);
        if (gc_mod.current_gc) |gc_inst| {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(ns_env)), gc_mod.GCObjectType.env);
        }
        const wrapped = wrapPtr(*Env, ns_env);
        self.namespaces = try self.namespaces.mapAssoc(self.allocator, key, wrapped);
        return ns_env;
    }

    pub fn getNamespace(self: *NamespaceManager, name: []const u8) ?*Env {
        const key = symKey(name);
        const found = self.namespaces.find(key);
        if (found) |val| return unwrapPtr(*Env, val);
        return null;
    }

    pub fn setCurrentNamespace(self: *NamespaceManager, name: []const u8) anyerror!void {
        const new_ns = try self.allocator.dupe(u8, name);
        self.allocator.free(self.current_ns);
        self.current_ns = new_ns;
    }

    pub fn getCurrentNamespace(self: *const NamespaceManager) []const u8 {
        return self.current_ns;
    }

    pub fn addAlias(self: *NamespaceManager, ns_name: []const u8, alias: []const u8, target: []const u8) anyerror!void {
        var key_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer key_buf.deinit(self.allocator);
        try key_buf.appendSlice(self.allocator, ns_name);
        try key_buf.append(self.allocator, '/');
        try key_buf.appendSlice(self.allocator, alias);
        const composite_key = key_buf.items;

        const key = symKey(composite_key);
        const target_val = try stringValue(self.allocator, target);
        self.aliases = try self.aliases.mapAssoc(self.allocator, key, target_val);
    }

    pub fn resolveAlias(self: *const NamespaceManager, ns_name: []const u8, alias: []const u8) ?[]const u8 {
        var key_buf: [256]u8 = undefined;
        const ns_len = ns_name.len;
        const alias_len = alias.len;
        if (ns_len + 1 + alias_len >= key_buf.len) return null;
        @memcpy(key_buf[0..ns_len], ns_name);
        key_buf[ns_len] = '/';
        @memcpy(key_buf[ns_len + 1 .. ns_len + 1 + alias_len], alias);
        const composite_key = key_buf[0 .. ns_len + 1 + alias_len];

        const key = symKey(composite_key);
        const found = self.aliases.find(key);
        if (found) |val| {
            if (std.meta.activeTag(val) == .string) return val.string;
        }
        return null;
    }

    pub fn removeAlias(self: *NamespaceManager, ns_name: []const u8, alias: []const u8) anyerror!void {
        var key_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer key_buf.deinit(self.allocator);
        try key_buf.appendSlice(self.allocator, ns_name);
        try key_buf.append(self.allocator, '/');
        try key_buf.appendSlice(self.allocator, alias);
        const composite_key = key_buf.items;

        const key = symKey(composite_key);
        self.aliases = try self.aliases.mapWithout(self.allocator, key);
    }

    pub fn addLoadedLib(self: *NamespaceManager, ns_name: []const u8) anyerror!void {
        for (self.loaded_libs.items) |lib| {
            if (std.mem.eql(u8, lib, ns_name)) return;
        }
        const owned = try self.allocator.dupe(u8, ns_name);
        try self.loaded_libs.append(self.allocator, owned);
    }

    pub fn getLoadedLibs(self: *const NamespaceManager) []const []const u8 {
        return self.loaded_libs.items;
    }

    pub fn addClasspath(self: *NamespaceManager, dir: []const u8) anyerror!void {
        const owned = try self.allocator.dupe(u8, dir);
        try self.classpath.append(self.allocator, owned);
    }

    pub fn resolveNamespaceToPath(self: *const NamespaceManager, allocator: Allocator, ns_name: []const u8) anyerror!?[]const u8 {
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

        for (self.classpath.items) |cp_dir| {
            var full_path: std.ArrayList(u8) = .empty;
            errdefer full_path.deinit(allocator);
            try full_path.appendSlice(allocator, cp_dir);
            if (cp_dir.len > 0 and cp_dir[cp_dir.len - 1] != '/') {
                try full_path.append(allocator, '/');
            }
            try full_path.appendSlice(allocator, file_path);

            const cwd = std.Io.Dir.cwd();
            const test_file = std.Io.Dir.openFile(cwd, std.Options.debug_io, full_path.items, .{}) catch continue;
            std.Io.File.close(test_file, std.Options.debug_io);
            const result: []const u8 = try full_path.toOwnedSlice(allocator);
            return result;
        }

        return null;
    }
};

// ============================================================
// Cached Keywords for Stats Functions
// ============================================================
// Keywords used in gc-stats and stack-stats are constant strings
// that are created fresh on every call. This wastes allocations:
//   - keywordValue() does allocator.dupe(u8, name) + tagStringData
//   - gc-stats has 7 keywords = 7 string allocs per call
//   - stack-stats has 4 keywords = 4 string allocs per call
//
// Solution: cache the keyword string data as singletons. The cached
// strings are allocated once from the GC heap and reused forever.
// This eliminates all keyword allocations in the hot stats path.
// ============================================================

const StatsKeywords = struct {
    // gc-stats keywords
    current_allocated: ?[]const u8 = null,
    peak_allocated: ?[]const u8 = null,
    total_allocated: ?[]const u8 = null,
    total_freed: ?[]const u8 = null,
    sweep_count: ?[]const u8 = null,
    alloc_count: ?[]const u8 = null,
    block_count: ?[]const u8 = null,
    // stack-stats keywords
    app_baseline: ?[]const u8 = null,
    vm_baseline: ?[]const u8 = null,
    current: ?[]const u8 = null,
    usage: ?[]const u8 = null,
};

var stats_keywords: StatsKeywords = .{};

/// Lazily initialize and return the cached keyword string for a given name.
/// Returns the cached string on subsequent calls. Uses the GC allocator.
pub fn getCachedKeyword(name: []const u8) anyerror![]const u8 {
    // Resolve the cache slot for known keywords
    const slot: ?*?[]const u8 = if (std.mem.eql(u8, name, "current-allocated")) &stats_keywords.current_allocated
    else if (std.mem.eql(u8, name, "peak-allocated")) &stats_keywords.peak_allocated
    else if (std.mem.eql(u8, name, "total-allocated")) &stats_keywords.total_allocated
    else if (std.mem.eql(u8, name, "total-freed")) &stats_keywords.total_freed
    else if (std.mem.eql(u8, name, "sweep-count")) &stats_keywords.sweep_count
    else if (std.mem.eql(u8, name, "alloc-count")) &stats_keywords.alloc_count
    else if (std.mem.eql(u8, name, "block-count")) &stats_keywords.block_count
    else if (std.mem.eql(u8, name, "app-baseline")) &stats_keywords.app_baseline
    else if (std.mem.eql(u8, name, "vm-baseline")) &stats_keywords.vm_baseline
    else if (std.mem.eql(u8, name, "current")) &stats_keywords.current
    else if (std.mem.eql(u8, name, "usage")) &stats_keywords.usage
    else null;

    if (slot) |s| {
        if (s.*) |cached| return cached;

        var allocator: Allocator = std.heap.page_allocator;
        if (gc_mod.current_gc) |gc| allocator = gc.allocator();
        const duped = try allocator.dupe(u8, name);
        tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
        s.* = duped;
        return duped;
    }

    // Unknown keyword — allocate without caching
    var allocator: Allocator = std.heap.page_allocator;
    if (gc_mod.current_gc) |gc| allocator = gc.allocator();
    return try allocator.dupe(u8, name);
}

/// Return a keyword Value using a cached string.
/// Caller does NOT own the string — it is a global singleton.
pub fn getCachedKeywordValue(name: []const u8) anyerror!Value {
    return .{ .keyword = try getCachedKeyword(name) };
}
