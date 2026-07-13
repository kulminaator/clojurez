// Chunked sequence helpers — internal operations for chunk production/consumption.
// NOT exposed as Clojure functions. Called directly from other Zig modules.

const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec_mod = @import("../../vector.zig");
const gc_mod = @import("../../gc.zig");
const helpers = @import("helpers.zig");
const Allocator = std.mem.Allocator;

/// Mutable buffer for accumulating chunk elements.
/// NOT a Value type — used internally during chunk construction.
pub const ChunkBuffer = struct {
    items: []Value,
    count: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) anyerror!ChunkBuffer {
        const items = try allocator.alloc(Value, capacity);
        @memset(items, vm.nilValue());
        return .{ .items = items, .count = 0, .allocator = allocator };
    }

    pub fn deinit(self: *ChunkBuffer) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            vm.valueDeinit(&self.items[i], self.allocator);
        }
        self.allocator.free(self.items);
        self.count = 0;
    }

    pub fn append(self: *ChunkBuffer, val: Value) anyerror!void {
        try self.ensureCapacity();
        self.items[self.count] = val;
        self.count += 1;
    }

    fn ensureCapacity(self: *ChunkBuffer) anyerror!void {
        if (self.count >= self.items.len) {
            const new_cap = self.items.len * 2;
            const new_items = try self.allocator.alloc(Value, new_cap);
            @memset(new_items[self.items.len..], vm.nilValue());
            @memcpy(new_items[0..self.items.len], self.items[0..self.items.len]);
            self.allocator.free(self.items);
            self.items = new_items;
        }
    }

    /// Seal buffer into an immutable ChunkData Value.
    /// Transfers ownership of the items array.
    pub fn seal(self: *ChunkBuffer) anyerror!Value {
        const result = try vm.chunkValue(
            self.allocator, self.items, 0, self.count, true);
        self.items = &.{};
        self.count = 0;
        return result;
    }
};

/// Create a ChunkedCons from a chunk Value and a tail Value.
pub fn chunkedCons(allocator: Allocator, chunk_val: Value, tail: Value) anyerror!Value {
    return vm.chunkedConsValue(allocator, chunk_val.chunk, tail);
}

/// Check if a value is a chunked sequence (chunked_cons).
pub fn isChunkedSeq(val: Value) bool {
    return std.meta.activeTag(val) == .chunked_cons;
}

/// Get the chunk from a chunked_cons. Returns the ChunkData pointer.
pub fn getChunkPtr(val: Value) *vm.ChunkData {
    return val.chunked_cons.chunk;
}

/// chunk-cons: create a chunked_cons from a chunk Value and a rest Value.
/// If chunk is empty, return rest directly (matching Clojure semantics).
pub fn chunkCons(allocator: Allocator, chunk_val: Value, rest: Value) anyerror!Value {
    if (std.meta.activeTag(chunk_val) != .chunk) return error.TypeError;
    if (chunk_val.chunk.count() == 0) {
        return rest;
    }
    return vm.chunkedConsValue(allocator, chunk_val.chunk, rest);
}

/// chunk-first: get the chunk from a chunked_cons.
pub fn chunkFirst(allocator: Allocator, val: Value) anyerror!Value {
    if (std.meta.activeTag(val) != .chunked_cons) return error.TypeError;
    const ccd = val.chunked_cons;
    return try vm.chunkValue(allocator, ccd.chunk.items, ccd.chunk.off, ccd.chunk.end, false);
}

/// chunk-rest: get the remaining sequence after consuming the full chunk.
/// Returns the tail (may be nil, lazy_seq, or chunked_cons).
pub fn chunkRest(allocator: Allocator, val: Value) anyerror!Value {
    _ = allocator;
    if (std.meta.activeTag(val) != .chunked_cons) return error.TypeError;
    return val.chunked_cons.tail;
}

/// chunk-next: like chunk-rest but returns nil if tail is nil.
pub fn chunkNext(allocator: Allocator, val: Value) anyerror!Value {
    _ = allocator;
    if (std.meta.activeTag(val) != .chunked_cons) return error.TypeError;
    const tail = val.chunked_cons.tail;
    if (std.meta.activeTag(tail) == .nil) return vm.nilValue();
    return tail;
}

// ===== Clojure-exposed wrapper functions =====

pub fn core_chunk_cons(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    return chunkCons(env_env.allocator, args.items[0], args.items[1]);
}

pub fn core_chunk_first(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return chunkFirst(env_env.allocator, args.items[0]);
}

pub fn core_chunk_rest(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return chunkRest(env_env.allocator, args.items[0]);
}

pub fn core_chunk_next(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return chunkNext(env_env.allocator, args.items[0]);
}

/// chunk-buffer: create a new chunk buffer with given capacity.
/// Returns a vector that serves as the mutable buffer.
pub fn core_chunk_buffer(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    _ = try helpers.toInt(args.items[0]); // validate capacity is integer
    // Return an empty vector as the buffer
    return try vm.vectorValue(env_env.allocator, vec_mod.Vector.empty);
}

/// chunk-append: append an element to a chunk buffer (vector).
/// Returns the new buffer with the element appended.
pub fn core_chunk_append(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    if (std.meta.activeTag(args.items[0]) != .vector) return error.TypeError;
    var new_vec: vec_mod.Vector = .empty;
    errdefer new_vec.deinit(allocator);
    for (args.items[0].vector.items.items) |item| {
        try new_vec.append(allocator, item);
    }
    try new_vec.append(allocator, args.items[1]);
    return try vm.vectorValue(allocator, new_vec);
}

/// chunk: seal a chunk buffer (vector) into an immutable chunk.
pub fn core_chunk(self: *const Value, args: *const list.List, env_env: *vm.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    if (std.meta.activeTag(args.items[0]) != .vector) return error.TypeError;
    const items = args.items[0].vector.items.items;
    const new_items = try allocator.alloc(Value, items.len);
    errdefer allocator.free(new_items);
    @memset(new_items, vm.nilValue());
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        new_items[i] = items[i];
    }
    return try vm.chunkValue(allocator, new_items, 0, items.len, true);
}

/// Register chunk helper functions exposed to Clojure.
pub fn registerChunkFunctions(env: *vm.Env) anyerror!void {
    try env.put("chunk-cons", vm.builtinFnValue(core_chunk_cons));
    try env.put("chunk-first", vm.builtinFnValue(core_chunk_first));
    try env.put("chunk-rest", vm.builtinFnValue(core_chunk_rest));
    try env.put("chunk-next", vm.builtinFnValue(core_chunk_next));
    try env.put("chunk-buffer", vm.builtinFnValue(core_chunk_buffer));
    try env.put("chunk-append", vm.builtinFnValue(core_chunk_append));
    try env.put("chunk", vm.builtinFnValue(core_chunk));
}
