// gc_scan.zig — Scan function for the GC that understands Clojure Value structures.

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("value.zig");

/// Main scan function — dispatched by the GC for each marked block.
pub fn valueScanFn(obj: *anyopaque, ctx: *gc.ScanContext) void {
    const header = ctx.gc.findHeader(obj) orelse return;
    switch (header.obj_type) {
        .unknown => scanUnknownBlock(obj, ctx, header.size),
        .value_array => scanValueArray(obj, ctx, header.size),
        .map_entries => scanMapEntries(obj, ctx, header.size),
        .set_items => scanValueArray(obj, ctx, header.size),
        .queue_items => scanValueArray(obj, ctx, header.size),
        .env_entries => scanEnvEntries(obj, ctx, header.size),
        .lazy_seq_thunk => scanLazySeqThunk(obj, ctx),
        .atom_data => scanAtomData(obj, ctx),
        .fn_data => scanFnData(obj, ctx),
        .cons_data => scanConsData(obj, ctx),
    }
}

/// Heuristic scan for blocks without a type tag.
fn scanUnknownBlock(obj: *anyopaque, ctx: *gc.ScanContext, size: usize) void {
    const value_size = @sizeOf(Value);
    const map_entry_size = @sizeOf(Value.MapEntry);
    const atom_size = @sizeOf(Value.AtomData);
    const thunk_size = @sizeOf(Value.LazySeqThunk);

    if (size == value_size) {
        const val: *const Value = @ptrCast(@alignCast(obj));
        scanValueChildrenDirect(val, ctx);
        return;
    }
    if (size == atom_size) {
        scanAtomData(obj, ctx);
        return;
    }
    if (size == thunk_size) {
        scanLazySeqThunk(obj, ctx);
        return;
    }
    // Array of Values (list items, vector items, set items, queue items)
    // Only match if size is a reasonable multiple of Value size
    if (size % value_size == 0 and size >= value_size and size / value_size <= 10000) {
        scanValueArray(obj, ctx, size);
        return;
    }
    // Array of MapEntries
    if (size % map_entry_size == 0 and size >= map_entry_size and size / map_entry_size <= 10000) {
        scanMapEntries(obj, ctx, size);
        return;
    }
    // String/keyword/symbol data — no child pointers, nothing to scan
}

/// Scan an array of Value objects.
fn scanValueArray(items_ptr: *anyopaque, ctx: *gc.ScanContext, total_size: usize) void {
    const item_ptr: [*]Value = @ptrCast(@alignCast(items_ptr));
    const count = total_size / @sizeOf(Value);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        scanValueChildrenDirect(&item_ptr[i], ctx);
    }
}

/// Scan MapEntry array: each entry has { key: Value, value: Value }.
fn scanMapEntries(entries_ptr: *anyopaque, ctx: *gc.ScanContext, total_size: usize) void {
    const entry_ptr: [*]Value.MapEntry = @ptrCast(@alignCast(entries_ptr));
    const count = total_size / @sizeOf(Value.MapEntry);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        scanValueChildrenDirect(&entry_ptr[i].key, ctx);
        scanValueChildrenDirect(&entry_ptr[i].value, ctx);
    }
}

/// Scan StringArrayHashMapUnmanaged(Value) MultiArrayList bytes buffer.
fn scanEnvEntries(bytes_ptr: *anyopaque, ctx: *gc.ScanContext, total_size: usize) void {
    const key_size = @sizeOf([]const u8);
    const value_size = @sizeOf(Value);

    const entry_total = key_size + value_size;
    const count = total_size / entry_total;

    // Compute offset to value array (after all keys, with alignment)
    const keys_raw = key_size * count;
    const value_align = @alignOf(Value);
    const keys_padded: usize = std.math.divCeil(usize, keys_raw, value_align) catch value_align * count;

    const bytes: [*]const u8 = @ptrCast(@alignCast(bytes_ptr));
    const keys_ptr: [*]const []const u8 = @ptrCast(@alignCast(bytes));
    const values_ptr: [*]const Value = @ptrCast(@alignCast(bytes + keys_padded));

    var i: usize = 0;
    while (i < count) : (i += 1) {
        // Mark the key string data (heap-allocated string pointed to by the slice)
        if (keys_ptr[i].len > 0) {
            ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(keys_ptr[i].ptr))), ctx);
        }
        // Mark the value's children
        scanValueChildrenDirect(&values_ptr[i], ctx);
    }
}

/// Scan a single Value's child heap pointers and mark them.
pub fn scanValueChildrenDirect(val: *const Value, ctx: *gc.ScanContext) void {
    // Guard against corrupt/uninitialized Value structs.
    // This can happen when the GC scan misidentifies a non-Value block
    // as a Value array (e.g., a string whose length happens to be a
    // multiple of @sizeOf(Value)).
    const valid_types = [_]Value.Type{
        .nil, .bool, .integer, .float, .bigint, .ratio, .decimal,
        .string, .regex, .character, .symbol, .keyword,
        .list, .vector, .map, .set, .queue, .function, .builtin_fn,
        .lazy_seq, .cons, .atom, .reduced,
    };
    var is_valid = false;
    for (valid_types) |vt| {
        if (val.type == vt) { is_valid = true; break; }
    }
    if (!is_valid) return; // silently skip corrupt values

    switch (val.type) {
        .nil, .bool, .integer, .float, .character, .builtin_fn => {},

        .bigint => {
            if (val.bigint_val) |bi_ptr| {
                // Mark the BigInt struct itself
                ctx.gc.markRecursive(bi_ptr, ctx);
                // Mark the limbs array inside BigInt
                if (bi_ptr.limbs.len > 0 and bi_ptr.owns_limbs) {
                    ctx.gc.markRecursive(bi_ptr.limbs.ptr, ctx);
                }
            }
        },

        .ratio => {
            if (val.ratio_val) |r_ptr| {
                // Mark the Ratio struct itself
                ctx.gc.markRecursive(r_ptr, ctx);
                // Mark the limbs arrays inside num and den BigInts
                if (r_ptr.num.limbs.len > 0 and r_ptr.num.owns_limbs) {
                    ctx.gc.markRecursive(r_ptr.num.limbs.ptr, ctx);
                }
                if (r_ptr.den.limbs.len > 0 and r_ptr.den.owns_limbs) {
                    ctx.gc.markRecursive(r_ptr.den.limbs.ptr, ctx);
                }
            }
        },

        .decimal => {
            if (val.decimal_val) |d_ptr| {
                // Mark the BigDecimal struct itself
                ctx.gc.markRecursive(d_ptr, ctx);
                // Mark the limbs array inside unscaled BigInt
                if (d_ptr.unscaled.limbs.len > 0 and d_ptr.unscaled.owns_limbs) {
                    ctx.gc.markRecursive(d_ptr.unscaled.limbs.ptr, ctx);
                }
            }
        },

        .string => {
            if (val.str_val.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(val.str_val.ptr))), ctx);
            }
        },
        .regex => {
            if (val.re_pattern.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(val.re_pattern.ptr))), ctx);
            }
        },
        .symbol => {
            if (val.sym_val.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(val.sym_val.ptr))), ctx);
            }
        },
        .keyword => {
            if (val.kw_val.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(val.kw_val.ptr))), ctx);
            }
        },

        .list => {
            if (val.list_val.items.len > 0) {
                ctx.gc.markRecursive(val.list_val.items.ptr, ctx);
            }
        },
        .vector => {
            if (val.vec_val.items.len > 0) {
                ctx.gc.markRecursive(val.vec_val.items.ptr, ctx);
            }
        },
        .map => {
            if (val.map_val.items.len > 0) {
                ctx.gc.markRecursive(val.map_val.items.ptr, ctx);
            }
        },
        .set => {
            if (val.set_val.items.len > 0) {
                ctx.gc.markRecursive(val.set_val.items.ptr, ctx);
            }
        },
        .queue => {
            if (val.queue_val.items.len > 0) {
                ctx.gc.markRecursive(val.queue_val.items.ptr, ctx);
            }
        },

        .function => {
            // Mark the arities array buffer itself
            if (val.fn_val.arities.items.len > 0) {
                ctx.gc.markRecursive(val.fn_val.arities.items.ptr, ctx);
                // Each Arity has params (list) and body (list) that need marking
                for (val.fn_val.arities.items) |arity| {
                    if (arity.params.items.len > 0) {
                        ctx.gc.markRecursive(arity.params.items.ptr, ctx);
                    }
                    if (arity.body.items.len > 0) {
                        ctx.gc.markRecursive(arity.body.items.ptr, ctx);
                    }
                    if (arity.rest_name) |rn| {
                        if (rn.len > 0) {
                            ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(rn.ptr))), ctx);
                        }
                    }
                }
            }
            // Mark the fn's env entries buffer
            const fn_entries = val.fn_val.env.entries;
            if (fn_entries.entries.len > 0) {
                ctx.gc.markRecursive(fn_entries.entries.bytes, ctx);
            }
            // Also mark the env's index_header
            if (fn_entries.index_header) |header| {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(header)), ctx);
            }
            // Mark key strings and scan values in the fn's env entries
            var fn_it = fn_entries.iterator();
            while (fn_it.next()) |entry| {
                if (entry.key_ptr.*.len > 0) {
                    ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(entry.key_ptr.*.ptr))), ctx);
                }
                scanValueChildrenDirect(entry.value_ptr, ctx);
            }
        },

        .lazy_seq => {
            if (val.lazy_seq_val.thunk) |thunk| {
                ctx.gc.markRecursive(thunk, ctx);
            }
        },

        .cons => {
            if (val.cons_val) |data| {
                // Mark the ConsData struct so GC can find head and tail
                ctx.gc.markRecursive(data, ctx);
            }
        },

        .atom => {
            if (val.atom_val) |data| {
                ctx.gc.markRecursive(data, ctx);
            }
        },

        .reduced => {
            // Scan the wrapped value
            if (val.reduced_val) |data| {
                ctx.gc.markRecursive(data, ctx);
            }
        },
    }
}

/// Scan a LazySeqThunk: { params: list.List, body: list.List, env: Env }.
fn scanLazySeqThunk(thunk_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const thunk: *Value.LazySeqThunk = @ptrCast(@alignCast(thunk_ptr));
    if (thunk.params.items.len > 0) {
        ctx.gc.markRecursive(thunk.params.items.ptr, ctx);
    }
    if (thunk.body.items.len > 0) {
        ctx.gc.markRecursive(thunk.body.items.ptr, ctx);
    }
    // Validate env entries before scanning — guard against false-positive size match
    const entries = thunk.env.entries;
    if (entries.entries.len > 10000) return; // sanity: unlikely to have this many
    if (entries.entries.capacity > 0 and entries.entries.len > entries.entries.capacity) return;
    // Mark the thunk's env entries buffer
    if (entries.entries.len > 0) {
        ctx.gc.markRecursive(entries.entries.bytes, ctx);
    }
    // Mark the thunk's env index_header (separate allocation)
    if (entries.index_header) |header| {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(header)), ctx);
    }
    // Scan the thunk's env values and mark key strings
    var it = entries.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.len > 0) {
            ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(entry.key_ptr.*.ptr))), ctx);
        }
        scanValueChildrenDirect(entry.value_ptr, ctx);
    }
    // Mark shared_coll (separate GC allocation for concrete collection in map).
    // This keeps the collection alive across GC cycles since it's a raw pointer
    // that the GC wouldn't otherwise discover.
    if (thunk.shared_coll) |sc| {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(sc))), ctx);
    }
}

/// Scan AtomData: { value: Value, ref_count: usize }.
fn scanAtomData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *Value.AtomData = @ptrCast(@alignCast(data_ptr));
    scanValueChildrenDirect(&data.value, ctx);
}

/// Scan FnData: { arities: ArrayListUnmanaged(Arity), env: Env }.
fn scanFnData(fndata_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const fndata: *Value.FnData = @ptrCast(@alignCast(fndata_ptr));
    if (fndata.arities.items.len > 0) {
        ctx.gc.markRecursive(fndata.arities.items.ptr, ctx);
        // Each Arity has params and body lists that need marking
        for (fndata.arities.items) |arity| {
            if (arity.params.items.len > 0) {
                ctx.gc.markRecursive(arity.params.items.ptr, ctx);
            }
            if (arity.body.items.len > 0) {
                ctx.gc.markRecursive(arity.body.items.ptr, ctx);
            }
            if (arity.rest_name) |rn| {
                if (rn.len > 0) {
                    ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(rn.ptr))), ctx);
                }
            }
        }
    }
    // Validate env entries before scanning
    const fn_entries = fndata.env.entries;
    if (fn_entries.entries.len > 10000) return;
    if (fn_entries.entries.capacity > 0 and fn_entries.entries.len > fn_entries.entries.capacity) return;
    // Mark the fn's env entries buffer
    if (fn_entries.entries.len > 0) {
        ctx.gc.markRecursive(fn_entries.entries.bytes, ctx);
    }
    // Mark the fn's env index_header (separate allocation)
    if (fn_entries.index_header) |header| {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(header)), ctx);
    }
    // Scan the fn's env values and mark key strings
    var it = fn_entries.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.len > 0) {
            ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(entry.key_ptr.*.ptr))), ctx);
        }
        scanValueChildrenDirect(entry.value_ptr, ctx);
    }
}

/// Scan ConsData: { head: Value, tail: Value, allocator: Allocator }.
fn scanConsData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *Value.ConsData = @ptrCast(@alignCast(data_ptr));
    scanValueChildrenDirect(&data.head, ctx);
    scanValueChildrenDirect(&data.tail, ctx);
}
