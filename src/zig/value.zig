const std = @import("std");
const Allocator = std.mem.Allocator;

const list = @import("list.zig");
const vec = @import("vector.zig");
const BI = @import("big_int.zig");
const RatioMod = @import("ratio.zig");
const BD = @import("big_decimal.zig");
const phm = @import("persistent_hash_map.zig");
const gc_mod = @import("gc.zig");

/// Helper: tag a string data allocation so the GC doesn't misidentify it as a Value.
fn tagStringData(ptr: *anyopaque) void {
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(ptr, gc_mod.GCObjectType.string_data);
    }
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
    atom,
    future,  // Future: computation running in another thread
    promise, // Promise: one-time writable container
    reduced, // Wrapper for early reduction termination
    wrapped, // Raw pointer wrapper — stores a usize pointer
    record,  // defrecord instance: named struct-like data with fields
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
    map,  // (map f coll) — apply f to each element of coll
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
    rest_name: ?[]const u8 = null,
};

pub const FnData = struct {
    arities: std.ArrayListUnmanaged(Arity) = .empty,
    env: *Env,
    is_macro: bool = false,
    name: ?[]const u8 = null,
};

// ============================================================
// Heap-allocated collection data structs
// ============================================================

pub const ListData = struct {
    items: std.ArrayListUnmanaged(Value),
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
    atom: *AtomData,
    future: *FutureData,
    promise: *PromiseData,
    reduced: *Value,
    wrapped: usize,
    record: *RecordData,
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
    const data = try allocator.create(ListData);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(data)), gc_mod.GCObjectType.list_data);
    }
    data.* = .{ .items = l };
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

pub fn fnValue(allocator: Allocator, arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool) anyerror!Value {
    return fnValueNamed(allocator, arities, env, is_macro, null);
}

pub fn fnValueNamed(allocator: Allocator, arities: std.ArrayListUnmanaged(Arity), env: Env, is_macro: bool, name: ?[]const u8) anyerror!Value {
    const env_ptr = try allocator.create(Env);
    errdefer allocator.destroy(env_ptr);
    env_ptr.* = env;
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(env_ptr)), gc_mod.GCObjectType.env);
    }
    const fn_data = try allocator.create(FnData);
    errdefer allocator.destroy(fn_data);
    fn_data.* = .{ .arities = arities, .env = env_ptr, .is_macro = is_macro, .name = name };
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
    switch (val.*) {
        .nil, .bool, .integer, .float, .character => {},
        .bigint => |ptr| {
            ptr.deinit();
            allocator.destroy(ptr);
        },
        .ratio => |ptr| {
            ptr.deinit();
            allocator.destroy(ptr);
        },
        .decimal => |ptr| {
            ptr.deinit();
            allocator.destroy(ptr);
        },
        .string => |s| allocator.free(s),
        .regex => |s| allocator.free(s),
        .symbol => |s| allocator.free(s),
        .keyword => |s| allocator.free(s),
        .list => |data| {
            for (data.items.items) |*item| {
                valueDeinit(item, allocator);
            }
            allocator.free(data.items.items);
            allocator.destroy(data);
        },
        .vector => |data| {
            for (data.items.items) |*item| {
                valueDeinit(item, allocator);
            }
            allocator.free(data.items.items);
            allocator.destroy(data);
        },
        .map => |data| {
            for (data.entries.items) |*entry| {
                valueDeinit(&entry.key, allocator);
                valueDeinit(&entry.value, allocator);
            }
            allocator.free(data.entries.items);
            allocator.destroy(data);
        },
        .set => |data| {
            for (data.items.items) |*item| {
                valueDeinit(item, allocator);
            }
            allocator.free(data.items.items);
            allocator.destroy(data);
        },
        .queue => |data| {
            for (data.items.items) |*item| {
                valueDeinit(item, allocator);
            }
            allocator.free(data.items.items);
            allocator.destroy(data);
        },
        .lazy_seq => |thunk| {
            if (thunk) |t| {
                const thunk_allocator = t.env.allocator;
                t.params.deinit(thunk_allocator);
                t.body.deinit(thunk_allocator);
                t.env.deinit(thunk_allocator);
                thunk_allocator.destroy(t);
            }
        },
        .function => |fn_data| {
            for (fn_data.arities.items) |*arity| {
                arity.params.deinit(allocator);
                arity.body.deinit(allocator);
                if (arity.rest_name) |rn| {
                    allocator.free(rn);
                }
            }
            allocator.free(fn_data.arities.items);
            fn_data.env.deinit(allocator);
            allocator.destroy(fn_data.env);
            if (fn_data.name) |n| allocator.free(n);
            allocator.destroy(fn_data);
        },
        .builtin_fn => {},
        .cons => |data| {
            data.ref_count -= 1;
            if (data.ref_count == 0) {
                const a = data.allocator;
                valueDeinit(&data.head, a);
                valueDeinit(&data.tail, a);
                a.destroy(data);
            }
        },
        .atom => |data| {
            data.ref_count -= 1;
            if (data.ref_count == 0) {
                valueDeinit(&data.value, allocator);
                allocator.destroy(data);
            }
        },
        .future => |data| {
            // FutureData is GC-managed. The GC's freeVTable is a no-op,
            // so allocator.destroy(data) doesn't actually free the memory.
            // But we should NOT call valueDeinit on child values (result, fn_val)
            // because they are also GC-managed and will be cleaned up by the GC.
            // Only clean up the error_msg string (dupe'd with allocator.dupe).
            if (data.error_msg) |msg| {
                allocator.free(msg);
            }
            // allocator.destroy(data) is a no-op through GC allocator.
            allocator.destroy(data);
        },
        .promise => |data| {
            data.ref_count -= 1;
            if (data.ref_count == 0) {
                if (data.value) |*v| {
                    valueDeinit(v, allocator);
                }
                allocator.destroy(data);
            }
        },
        .reduced => |data| {
            valueDeinit(data, allocator);
            allocator.destroy(data);
        },
        .wrapped => {},
        .record => |rd| {
            const a = rd.allocator;
            a.free(rd.type_name);
            for (rd.fields.items) |*entry| {
                valueDeinit(&entry.key, a);
                valueDeinit(&entry.value, a);
            }
            a.free(rd.fields.items);
            for (rd.extmap.items) |*entry| {
                valueDeinit(&entry.key, a);
                valueDeinit(&entry.value, a);
            }
            a.free(rd.extmap.items);
            if (rd.meta) |m| {
                for (m.items) |*entry| {
                    valueDeinit(&entry.key, a);
                    valueDeinit(&entry.value, a);
                }
                a.free(m.items);
            }
            allocator.destroy(rd);
        },
    }
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
        .list => |data| return try listValue(allocator, try list.clone(&data.items, allocator)),
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
                    .rest_name = cloned_rest,
                });
            }
            var cloned_name: ?[]const u8 = null;
            if (fn_data.name) |n| {
                const duped = try allocator.dupe(u8, n);
                tagStringData(@as(*anyopaque, @ptrCast(@constCast(duped.ptr))));
                cloned_name = duped;
            }
            return try fnValueNamed(allocator, cloned_arities, try fn_data.env.clone(allocator), fn_data.is_macro, cloned_name);
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
    }
}

/// Clone this Value into a GC-allocated *Value in a single allocation.
pub fn cloneGC(val: *const Value, allocator: Allocator) anyerror!*Value {
    const ptr = try allocator.create(Value);
    ptr.* = try clone(val, allocator);
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
        if (std.meta.activeTag(val) == .string) {
            return compareStrings(val.string, other.string);
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
    };
}

// ============================================================
// Deep-clone a vm.Map
// ============================================================

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
        self.entries.root = null;
        self.entries.count = 0;
        self.entries.has_null = false;
        // Do NOT free referred_names here — it is GC-managed.
        // The GC will reclaim the buffer and strings during sweep.
        // Freeing here causes use-after-free when child threads share
        // the buffer via shallow Env.clone (even though clone sets
        // referred_names to .empty, the original env's buffer could
        // be freed while the GC hasn't swept it yet).
        self.referred_names.items = &.{};
        _ = self.parent;
        _ = self.ns_manager;
        _ = allocator;
    }

    pub fn clone(self: *const Env, allocator: Allocator) anyerror!Env {
        return .{
            .allocator = allocator,
            .entries = self.entries,
            .parent = self.parent,
            .ns_manager = self.ns_manager,
            .referred_names = .empty,
        };
    }

    pub fn put(self: *Env, name: []const u8, value: Value) anyerror!void {
        const allocator = self.allocator;
        const key = phm.sym(name);
        const new_entries = try self.entries.mapAssoc(allocator, key, value);
        self.entries.root = null;
        self.entries.count = 0;
        self.entries.has_null = false;
        self.entries = new_entries;
        var val = value;
        valueDeinit(&val, allocator);
    }

    pub fn get(self: *Env, name: []const u8) ?Value {
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

    pub fn getPtr(self: *Env, name: []const u8) ?*const Value {
        return self.entries.findPtr(phm.sym(name));
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
