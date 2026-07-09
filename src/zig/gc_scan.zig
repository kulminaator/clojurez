// gc_scan.zig — Scan function for the GC that understands Clojure Value structures.

const std = @import("std");
const gc = @import("gc.zig");
const vm = @import("value.zig");
const Value = vm.Value;
const phm = @import("persistent_hash_map.zig");
const BI = @import("big_int.zig");
const RatioMod = @import("ratio.zig");
const BD = @import("big_decimal.zig");

/// Helper: cast any pointer to *anyopaque for GC marking.
fn markPtr(ptr: anytype, ctx: *gc.ScanContext) void {
    ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(ptr))), ctx);
}

/// Check if a pointer is plausibly valid (non-null, not garbage like 0xffffffffffffffff).
/// Used to guard against scanUnknownBlock misidentifying non-Value blocks.
fn isValidPtr(ptr: anytype) bool {
    const addr = @intFromPtr(ptr);
    // Reject null pointers
    if (addr == 0) return false;
    // Reject obviously garbage pointers (all bits set, very small, etc.)
    if (addr == std.math.maxInt(@TypeOf(addr))) return false;
    // Reject pointers below minimum heap address (GC allocator starts well above this)
    if (addr < 0x1000) return false;
    return true;
}

/// Check if a pointer is both plausibly valid AND a real GC-tracked block.
/// This is a stronger check than isValidPtr — it verifies the pointer
/// corresponds to an actual GC allocation header.
/// Used as a safety net when scanUnknownBlock might have misidentified a block.
fn isValidGCPtr(ptr: anytype, ctx: *gc.ScanContext) bool {
    if (!isValidPtr(ptr)) return false;
    // Verify this pointer is a real GC-tracked block
    const header = ctx.gc.findHeader(@as(*anyopaque, @ptrCast(@constCast(ptr))));
    if (header == null) return false;
    return true;
}

/// Main scan function — dispatched by the GC for each marked block.
pub fn valueScanFn(obj: *anyopaque, ctx: *gc.ScanContext) void {
    const header = ctx.gc.findHeader(obj) orelse return;
    switch (header.obj_type) {
        .unknown => scanUnknownBlock(obj, ctx, header.size),
        .value_array => scanValueArray(obj, ctx, header.size),
        .map_entries => scanMapEntries(obj, ctx, header.size),
        .set_items => scanValueArray(obj, ctx, header.size),
        .queue_items => scanValueArray(obj, ctx, header.size),
        .lazy_seq_thunk => scanLazySeqThunk(obj, ctx),
        .atom_data => scanAtomData(obj, ctx),
        .future_data => scanFutureData(obj, ctx),
        .promise_data => scanPromiseData(obj, ctx),
        .fn_data => scanFnData(obj, ctx),
        .cons_data => scanConsData(obj, ctx),
        .hash_map_node => phm.scanHashMapNode(obj, ctx),
        .hash_map_kvp_array => scanKvpArray(obj, ctx, header.size),
        .hash_map_sub_nodes => scanSubNodesArray(obj, ctx, header.size),
        .env => scanEnv(obj, ctx),
        .namespace_manager => scanNamespaceManager(obj, ctx),
        .record_data => scanRecordData(obj, ctx),
        .list_data => scanListData(obj, ctx),
        .vector_data => scanVectorData(obj, ctx),
        .map_data => scanMapData(obj, ctx),
        .set_data => scanSetData(obj, ctx),
        .queue_data => scanQueueData(obj, ctx),
        .fn_arities => scanFnArities(obj, ctx, header.size),
        .string_data => {}, // raw string bytes — no child pointers to scan
        .bigint_limbs => {}, // raw u64 limbs — no child pointers to scan
        .bigint_data => scanBigIntData(obj, ctx),
        .ratio_data => scanRatioData(obj, ctx),
        .decimal_data => scanDecimalData(obj, ctx),
        .bytecode_program => scanBytecodeProgram(obj, ctx),
        .chunk_data => scanChunkData(obj, ctx),
        .chunked_cons_data => scanChunkedConsData(obj, ctx),
        .frame => scanFrame(obj, ctx),
        .value_cache => scanValueCache(obj, ctx),
        .exception_data => scanExceptionData(obj, ctx),
    }
}

/// Heuristic scan for blocks without a type tag.
///
/// IMPORTANT: This function is a FALLBACK for allocations that weren't
/// properly typed. All properly-typed blocks are handled by their specific
/// scan functions. This function handles edge cases where type tagging
/// was missed.
///
/// The isValidGCPtr safety net in scanValueChildrenDirect protects against
/// misidentification — even if this function guesses wrong, the pointer
/// validation will prevent crashes.
fn scanUnknownBlock(obj: *anyopaque, ctx: *gc.ScanContext, size: usize) void {
    const value_size = @sizeOf(Value);

    const atom_size = @sizeOf(vm.AtomData);
    const thunk_size = @sizeOf(vm.LazySeqThunk);

    // Safety check: never scan the REPL history buffer as Value objects.
    // It contains raw source text bytes, not Value structs.
    const gc_mod = @import("gc.zig");
    if (gc_mod.repl_history_buffer.len > 0 and
        @as(*anyopaque, @ptrCast(@constCast(gc_mod.repl_history_buffer.ptr))) == obj) {
        return;
    }

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
    // Fallback for arrays that weren't explicitly typed during allocation.
    if (size % value_size == 0 and size >= value_size and size / value_size <= 10000) {
        scanValueArray(obj, ctx, size);
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
    const entry_ptr: [*]vm.MapEntry = @ptrCast(@alignCast(entries_ptr));
    const count = total_size / @sizeOf(vm.MapEntry);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        scanValueChildrenDirect(&entry_ptr[i].key, ctx);
        scanValueChildrenDirect(&entry_ptr[i].value, ctx);
    }
}

/// Scan a single Value's child heap pointers and mark them.
pub fn scanValueChildrenDirect(val: *const Value, ctx: *gc.ScanContext) void {
    // Guard against corrupt/uninitialized Value structs.
    // This can happen when the GC scan misidentifies a non-Value block
    // as a Value array (e.g., a string whose length happens to be a
    // multiple of @sizeOf(Value)).
    const tag = std.meta.activeTag(val.*);
    const valid_types = [_]vm.Type{
        .nil, .bool, .integer, .float, .bigint, .ratio, .decimal,
        .string, .regex, .character, .symbol, .keyword,
        .list, .vector, .map, .set, .queue, .function, .builtin_fn,
        .lazy_seq, .cons, .chunk, .chunked_cons, .atom, .future, .promise, .reduced, .wrapped, .record, .exception,
    };
    var is_valid = false;
    for (valid_types) |vt| {
        if (tag == vt) { is_valid = true; break; }
    }
    if (!is_valid) return; // silently skip corrupt values

    switch (val.*) {
        .nil, .bool, .integer, .float, .character, .builtin_fn, .wrapped => {},

        .bigint => |bi_ptr| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(bi_ptr, ctx)) return;
            // Mark the BigInt struct itself
            ctx.gc.markRecursive(bi_ptr, ctx);
            // Mark the limbs array inside BigInt
            if (bi_ptr.limbs.len > 0 and bi_ptr.owns_limbs) {
                ctx.gc.markRecursive(bi_ptr.limbs.ptr, ctx);
            }
        },

        .ratio => |r_ptr| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(r_ptr, ctx)) return;
            // Mark the Ratio struct itself
            ctx.gc.markRecursive(r_ptr, ctx);
            // Mark the limbs arrays inside num and den BigInts
            if (r_ptr.num.limbs.len > 0 and r_ptr.num.owns_limbs) {
                ctx.gc.markRecursive(r_ptr.num.limbs.ptr, ctx);
            }
            if (r_ptr.den.limbs.len > 0 and r_ptr.den.owns_limbs) {
                ctx.gc.markRecursive(r_ptr.den.limbs.ptr, ctx);
            }
        },

        .decimal => |d_ptr| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(d_ptr, ctx)) return;
            // Mark the BigDecimal struct itself
            ctx.gc.markRecursive(d_ptr, ctx);
            // Mark the limbs array inside unscaled BigInt
            if (d_ptr.unscaled.limbs.len > 0 and d_ptr.unscaled.owns_limbs) {
                ctx.gc.markRecursive(d_ptr.unscaled.limbs.ptr, ctx);
            }
        },

        .string => |s| {
            if (s.len > 0) markPtr(s.ptr, ctx);
        },
        .regex => |s| {
            if (s.len > 0) markPtr(s.ptr, ctx);
        },
        .symbol => |s| {
            if (s.len > 0) markPtr(s.ptr, ctx);
        },
        .keyword => |s| {
            if (s.len > 0) markPtr(s.ptr, ctx);
        },

        .list => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the ListData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },
        .vector => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the VectorData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },
        .map => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the MapData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the entries array buffer
            if (data.entries.items.len > 0) {
                ctx.gc.markRecursive(data.entries.items.ptr, ctx);
            }
        },
        .set => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the SetData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },
        .queue => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the QueueData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },

        .function => |fn_data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(fn_data, ctx)) return;
            // Mark the FnData struct itself so GC can find arities and env
            ctx.gc.markRecursive(fn_data, ctx);
            // Mark the fn's name string (if GC-allocated)
            if (fn_data.name) |name| {
                if (name.len > 0) markPtr(name.ptr, ctx);
            }
            // Mark the fn's docstring (if GC-allocated)
            if (fn_data.docstring) |ds| {
                if (ds.len > 0) markPtr(ds.ptr, ctx);
            }
            // Mark the arities array buffer itself
            if (fn_data.arities.items.len > 0) {
                ctx.gc.markRecursive(fn_data.arities.items.ptr, ctx);
                // Each Arity has params (list) and body (list) that need marking
                for (fn_data.arities.items) |arity| {
                    if (arity.params.items.len > 0) {
                        ctx.gc.markRecursive(arity.params.items.ptr, ctx);
                    }
                    if (arity.body.items.len > 0) {
                        ctx.gc.markRecursive(arity.body.items.ptr, ctx);
                    }
                    if (arity.rest_name) |rn| {
                        if (rn.len > 0) markPtr(rn.ptr, ctx);
                    }
                }
            }
            // Mark the fn's env struct itself (heap-allocated *Env)
            const fn_env = fn_data.env;
            ctx.gc.markRecursive(fn_env, ctx);
            // Mark the fn's env HAMT root node (triggers recursive scanning)
            if (fn_env.entries.root) |root| {
                ctx.gc.markRecursive(root, ctx);
            }
            // Also mark the env's parent and ns_manager
            if (fn_env.parent) |parent| {
                ctx.gc.markRecursive(parent, ctx);
            }
            if (fn_env.ns_manager) |ns_mgr| {
                ctx.gc.markRecursive(ns_mgr, ctx);
            }
            // Mark the cached metadata map (if populated)
            if (fn_data.cached_meta) |cm| {
                scanValueChildrenDirect(&cm, ctx);
            }
        },

        .lazy_seq => |thunk| {
            if (thunk) |t| {
                ctx.gc.markRecursive(t, ctx);
            }
        },

        .cons => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the ConsData struct so GC can find head and tail
            ctx.gc.markRecursive(data, ctx);
        },

        .chunk => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the ChunkData struct so GC can find the items array
            ctx.gc.markRecursive(data, ctx);
        },

        .chunked_cons => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Mark the ChunkedConsData struct so GC can find chunk and tail
            ctx.gc.markRecursive(data, ctx);
        },

        .atom => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            ctx.gc.markRecursive(data, ctx);
        },

        .future => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            ctx.gc.markRecursive(data, ctx);
        },

        .promise => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            ctx.gc.markRecursive(data, ctx);
        },

        .reduced => |data| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(data, ctx)) return;
            // Scan the wrapped value
            ctx.gc.markRecursive(data, ctx);
        },

        .record => |rd| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(rd, ctx)) return;
            // Mark the RecordData block itself so it survives GC sweep
            markPtr(rd, ctx);
            // Then scan its children (type_name, fields, extmap, meta)
            scanRecordData(@as(*anyopaque, @ptrCast(@constCast(rd))), ctx);
        },

        .exception => |ed| {
            // Safety net: verify pointer is a real GC-tracked block
            if (!isValidGCPtr(ed, ctx)) return;
            // Mark the ExceptionData block itself so it survives GC sweep
            ctx.gc.markRecursive(ed, ctx);
        },
    }
}

/// Scan a LazySeqThunk: { params: list.List, body: list.List, env: Env }.
fn scanLazySeqThunk(thunk_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const thunk: *vm.LazySeqThunk = @ptrCast(@alignCast(thunk_ptr));
    if (thunk.params.items.len > 0) {
        ctx.gc.setObjectType(thunk.params.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(thunk.params.items.ptr, ctx);
    }
    if (thunk.body.items.len > 0) {
        ctx.gc.setObjectType(thunk.body.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(thunk.body.items.ptr, ctx);
    }
    // Mark the thunk's env HAMT root node (triggers recursive scanning)
    if (thunk.env.entries.root) |root| {
        ctx.gc.markRecursive(root, ctx);
    }
    // Mark the thunk's env parent and ns_manager
    if (thunk.env.parent) |parent| {
        ctx.gc.markRecursive(parent, ctx);
    }
    if (thunk.env.ns_manager) |ns_mgr| {
        ctx.gc.markRecursive(ns_mgr, ctx);
    }
    // Mark shared_coll (separate GC allocation for concrete collection in map).
    // This keeps the collection alive across GC cycles since it's a raw pointer
    // that the GC wouldn't otherwise discover.
    if (thunk.shared_coll) |sc| {
        markPtr(sc, ctx);
    }
}

/// Scan AtomData: { value: Value, ref_count: usize }.
fn scanAtomData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *vm.AtomData = @ptrCast(@alignCast(data_ptr));
    scanValueChildrenDirect(&data.value, ctx);
}

/// Scan FutureData: { state: atomic u32, result: ?Value, fn_val: ?Value, error_msg: ?[]u8, allocator }.
/// Scan fn_val (the cloned function) unconditionally — this keeps the function
/// and its captured environment alive while the future thread is running.
/// Only scan the result Value if the future is done (state == 1).
fn scanFutureData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *vm.FutureData = @ptrCast(@alignCast(data_ptr));
    // Scan the function value — this marks FnData, its captured Env, and all
    // values in that env (like local bindings captured by closures).
    if (data.fn_val != null) {
        scanValueChildrenDirect(&data.fn_val.?, ctx);
    }
    const state = data.state.load(.monotonic);
    if (state == 1 and data.result != null) {
        scanValueChildrenDirect(&data.result.?, ctx);
    }
}

/// Scan PromiseData: { state: atomic u32, value: ?Value, allocator }.
/// Only scan the value if the promise is delivered (state == 1).
fn scanPromiseData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *vm.PromiseData = @ptrCast(@alignCast(data_ptr));
    const state = data.state.load(.monotonic);
    if (state == 1 and data.value != null) {
        scanValueChildrenDirect(&data.value.?, ctx);
    }
}

/// Scan FnData: { arities: ArrayListUnmanaged(Arity), env: *Env }.
fn scanFnData(fndata_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const fndata: *vm.FnData = @ptrCast(@alignCast(fndata_ptr));
    if (fndata.arities.items.len > 0) {
        ctx.gc.setObjectType(fndata.arities.items.ptr, gc.GCObjectType.fn_arities);
        ctx.gc.markRecursive(fndata.arities.items.ptr, ctx);
    }
    // Mark the fn's name string (if GC-allocated)
    if (fndata.name) |name| {
        if (name.len > 0) markPtr(name.ptr, ctx);
    }
    // Mark the fn's docstring (if GC-allocated)
    if (fndata.docstring) |ds| {
        if (ds.len > 0) markPtr(ds.ptr, ctx);
    }
    // Mark the fn's env struct itself (heap-allocated *Env)
    const fn_env = fndata.env;
    ctx.gc.markRecursive(fn_env, ctx);
    // Mark the fn's env HAMT root node (triggers recursive scanning)
    if (fn_env.entries.root) |root| {
        ctx.gc.markRecursive(root, ctx);
    }
    // Mark the fn's env parent and ns_manager
    if (fn_env.parent) |parent| {
        ctx.gc.markRecursive(parent, ctx);
    }
    if (fn_env.ns_manager) |ns_mgr| {
        ctx.gc.markRecursive(ns_mgr, ctx);
    }
}

/// Scan ConsData: { head: Value, tail: Value, allocator: Allocator }.
fn scanConsData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *vm.ConsData = @ptrCast(@alignCast(data_ptr));
    scanValueChildrenDirect(&data.head, ctx);
    scanValueChildrenDirect(&data.tail, ctx);
}

/// Scan ChunkData: { items: []Value, off, end, allocator, owns_array }.
/// Marks the items array so GC can discover the Values inside.
fn scanChunkData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *vm.ChunkData = @ptrCast(@alignCast(data_ptr));
    // Mark the backing array so GC can find the Value objects inside
    if (data.items.len > 0) {
        ctx.gc.setObjectType(data.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(data.items.ptr, ctx);
    }
}

/// Scan ChunkedConsData: { chunk: *ChunkData, tail: Value, allocator, ref_count }.
fn scanChunkedConsData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *vm.ChunkedConsData = @ptrCast(@alignCast(data_ptr));
    // Mark the chunk (triggers scanChunkData which marks the items array)
    ctx.gc.markRecursive(data.chunk, ctx);
    // Mark the tail value
    scanValueChildrenDirect(&data.tail, ctx);
}

/// Scan Kvp array: array of { key: Value, val: Value }.
/// Kvp is the same layout as two consecutive Values.
fn scanKvpArray(items_ptr: *anyopaque, ctx: *gc.ScanContext, total_size: usize) void {
    const kvp_size = @sizeOf(phm.Kvp);
    const count = total_size / kvp_size;
    const kvp_ptr: [*]phm.Kvp = @ptrCast(@alignCast(items_ptr));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        scanValueChildrenDirect(&kvp_ptr[i].key, ctx);
        scanValueChildrenDirect(&kvp_ptr[i].val, ctx);
        // Mark wrapped pointers (e.g., *Env stored in NamespaceManager)
        switch (kvp_ptr[i].val) {
            .wrapped => |w| {
                if (w != 0) {
                    const ptr = @as(*anyopaque, @ptrFromInt(w));
                    ctx.gc.markRecursive(ptr, ctx);
                }
            },
            else => {},
        }
    }
}

/// Scan sub-nodes array: array of ?*Node.
fn scanSubNodesArray(items_ptr: *anyopaque, ctx: *gc.ScanContext, total_size: usize) void {
    const ptr_size = @sizeOf(?*phm.Node);
    const count = total_size / ptr_size;
    const node_ptr: [*](?*phm.Node) = @ptrCast(@alignCast(items_ptr));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (node_ptr[i]) |sub| {
            ctx.gc.markRecursive(sub, ctx);
        }
    }
}

/// Scan an Env struct: entries (PersistentHashMap), parent, ns_manager, referred_names, owned_symbols.
fn scanEnv(env_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const env: *vm.Env = @ptrCast(@alignCast(env_ptr));

    // Mark the HAMT root node (triggers recursive scanning of all nodes)
    if (env.entries.root) |root| {
        ctx.gc.markRecursive(root, ctx);
    }
    // Mark referred_names list buffer and strings
    if (env.referred_names.items.len > 0) {
        markPtr(env.referred_names.items.ptr, ctx);
        for (env.referred_names.items) |name| {
            if (name.len > 0) markPtr(name.ptr, ctx);
        }
    }
    // Mark owned_symbols list buffer and strings
    if (env.owned_symbols.items.len > 0) {
        markPtr(env.owned_symbols.items.ptr, ctx);
        for (env.owned_symbols.items) |name| {
            if (name.len > 0) markPtr(name.ptr, ctx);
        }
    }
    // Mark parent env pointer
    if (env.parent) |parent| {
        ctx.gc.markRecursive(parent, ctx);
    }
    // Mark ns_manager pointer
    if (env.ns_manager) |ns_mgr| {
        ctx.gc.markRecursive(ns_mgr, ctx);
    }
}

/// Scan RecordData: { type_name: []const u8, fields: Map, extmap: Map, meta: ?Map, allocator }.
fn scanRecordData(rd_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const rd: *vm.RecordData = @ptrCast(@alignCast(rd_ptr));
    // Mark type_name string
    if (rd.type_name.len > 0) markPtr(rd.type_name.ptr, ctx);
    // Mark fields map entries buffer (contains vm.MapEntry { key, value })
    if (rd.fields.items.len > 0) {
        ctx.gc.markRecursive(rd.fields.items.ptr, ctx);
    }
    // Mark extmap entries buffer
    if (rd.extmap.items.len > 0) {
        ctx.gc.markRecursive(rd.extmap.items.ptr, ctx);
    }
    // Mark meta map entries buffer if present
    if (rd.meta) |m| {
        if (m.items.len > 0) {
            ctx.gc.markRecursive(m.items.ptr, ctx);
        }
    }
}

/// Scan ListData: { items: ArrayListUnmanaged(Value) }.
fn scanListData(ld_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const ld: *vm.ListData = @ptrCast(@alignCast(ld_ptr));
    if (ld.items.items.len > 0) {
        ctx.gc.setObjectType(ld.items.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(ld.items.items.ptr, ctx);
    }
}

/// Scan VectorData: { items: ArrayListUnmanaged(Value) }.
fn scanVectorData(vd_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const vd: *vm.VectorData = @ptrCast(@alignCast(vd_ptr));
    if (vd.items.items.len > 0) {
        ctx.gc.setObjectType(vd.items.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(vd.items.items.ptr, ctx);
    }
}

/// Scan MapData: { entries: ArrayListUnmanaged(MapEntry) }.
fn scanMapData(md_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const md: *vm.MapData = @ptrCast(@alignCast(md_ptr));
    if (md.entries.items.len > 0) {
        ctx.gc.setObjectType(md.entries.items.ptr, gc.GCObjectType.map_entries);
        ctx.gc.markRecursive(md.entries.items.ptr, ctx);
    }
}

/// Scan SetData: { items: ArrayListUnmanaged(Value) }.
fn scanSetData(sd_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const sd: *vm.SetData = @ptrCast(@alignCast(sd_ptr));
    if (sd.items.items.len > 0) {
        ctx.gc.setObjectType(sd.items.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(sd.items.items.ptr, ctx);
    }
}

/// Scan QueueData: { items: ArrayListUnmanaged(Value) }.
fn scanQueueData(qd_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const qd: *vm.QueueData = @ptrCast(@alignCast(qd_ptr));
    if (qd.items.items.len > 0) {
        ctx.gc.setObjectType(qd.items.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(qd.items.items.ptr, ctx);
    }
}

/// Scan array of Arity structs: { params: list.List, body: list.List, rest_name: ?[]const u8 }.
fn scanFnArities(arities_ptr: *anyopaque, ctx: *gc.ScanContext, total_size: usize) void {
    const arity_size = @sizeOf(vm.Arity);
    const count = total_size / arity_size;
    const arity_ptr: [*]const vm.Arity = @ptrCast(@alignCast(arities_ptr));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const arity = arity_ptr[i];
        if (arity.params.items.len > 0) {
            ctx.gc.setObjectType(arity.params.items.ptr, gc.GCObjectType.value_array);
            ctx.gc.markRecursive(arity.params.items.ptr, ctx);
        }
        if (arity.body.items.len > 0) {
            ctx.gc.setObjectType(arity.body.items.ptr, gc.GCObjectType.value_array);
            ctx.gc.markRecursive(arity.body.items.ptr, ctx);
        }
        if (arity.rest_name) |rn| {
            if (rn.len > 0) markPtr(rn.ptr, ctx);
        }
        // Mark bytecode program so GC doesn't free it
        if (arity.bytecode) |bc| {
            ctx.gc.setObjectType(bc, gc.GCObjectType.bytecode_program);
            ctx.gc.markRecursive(bc, ctx);
        }
    }
}

/// Scan BigInt struct: { sign, limbs: []LIMB, allocator, owns_limbs }.
fn scanBigIntData(bi_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const bi: *BI.BigInt = @ptrCast(@alignCast(bi_ptr));
    if (bi.limbs.len > 0 and bi.owns_limbs) {
        ctx.gc.markRecursive(bi.limbs.ptr, ctx);
    }
}

/// Scan Ratio struct: { num: BigInt, den: BigInt, allocator }.
fn scanRatioData(r_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const r: *RatioMod.Ratio = @ptrCast(@alignCast(r_ptr));
    // Mark numerator limbs
    if (r.num.limbs.len > 0 and r.num.owns_limbs) {
        ctx.gc.markRecursive(r.num.limbs.ptr, ctx);
    }
    // Mark denominator limbs
    if (r.den.limbs.len > 0 and r.den.owns_limbs) {
        ctx.gc.markRecursive(r.den.limbs.ptr, ctx);
    }
}

/// Scan BigDecimal struct: { unscaled: BigInt, scale, allocator }.
fn scanDecimalData(d_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const d: *BD.BigDecimal = @ptrCast(@alignCast(d_ptr));
    // Mark unscaled value limbs
    if (d.unscaled.limbs.len > 0 and d.unscaled.owns_limbs) {
        ctx.gc.markRecursive(d.unscaled.limbs.ptr, ctx);
    }
}

/// Scan BytecodeProgram: marks internal arrays and constant pool Values.
fn scanBytecodeProgram(bc_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const bc_mod = @import("bytecode.zig");
    const bc: *bc_mod.BytecodeProgram = @ptrCast(@alignCast(bc_ptr));

    // Mark instructions array
    if (bc.instructions.items.len > 0) {
        markPtr(bc.instructions.items.ptr, ctx);
    }
    // Mark constants array and scan each Value in it
    if (bc.constants.items.len > 0) {
        ctx.gc.setObjectType(bc.constants.items.ptr, gc.GCObjectType.value_array);
        ctx.gc.markRecursive(bc.constants.items.ptr, ctx);
    }
    // Mark symbols array backing memory + individual symbol strings
    if (bc.symbols.items.len > 0) {
        markPtr(bc.symbols.items.ptr, ctx);
        var i: usize = 0;
        const max_symbols = bc.symbols.items.len;
        if (max_symbols < 10000) {
            while (i < max_symbols) : (i += 1) {
                const s = bc.symbols.items[i];
                if (s.len > 0) markPtr(s.ptr, ctx);
            }
        }
    }
    // Mark source_markers array (backing memory + individual file strings)
    if (bc.source_markers.items.len > 0) {
        markPtr(bc.source_markers.items.ptr, ctx);
        var i: usize = 0;
        const max_markers = bc.source_markers.items.len;
        if (max_markers < 10000) {
            while (i < max_markers) : (i += 1) {
                const m = bc.source_markers.items[i];
                if (m.file.len > 0) markPtr(m.file.ptr, ctx);
            }
        }
    }
    // Mark source_file string
    if (bc.source_file.len > 0) {
        markPtr(bc.source_file.ptr, ctx);
    }
    // Mark fn_pool
    if (bc.fn_pool) |pool| {
        if (pool.len > 0) markPtr(pool.ptr, ctx);
    }
}

/// Scan a NamespaceManager struct.
fn scanNamespaceManager(ns_mgr_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const ns_mgr: *vm.NamespaceManager = @ptrCast(@alignCast(ns_mgr_ptr));

    // Mark current_ns string
    if (ns_mgr.current_ns.len > 0) markPtr(ns_mgr.current_ns.ptr, ctx);
    // Mark namespaces PersistentHashMap root node
    if (ns_mgr.namespaces.root) |root| {
        ctx.gc.markRecursive(root, ctx);
    }
    // Mark aliases PersistentHashMap root node
    if (ns_mgr.aliases.root) |root| {
        ctx.gc.markRecursive(root, ctx);
    }
    // Mark classpath buffer and strings
    if (ns_mgr.classpath.items.len > 0) {
        markPtr(ns_mgr.classpath.items.ptr, ctx);
        for (ns_mgr.classpath.items) |dir| {
            if (dir.len > 0) markPtr(dir.ptr, ctx);
        }
    }
}

/// Scan a Frame struct: { parent, children, overlay, memo_cache, root_env, function_ref, src_loc, has_active_children }.
/// Marks parent frame, child frames, overlay HAMT, memo cache values, root env, and function_ref.
fn scanFrame(frame_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const frame: *vm.Frame = @ptrCast(@alignCast(frame_ptr));

    // Mark parent frame pointer
    if (frame.parent) |parent| {
        ctx.gc.markRecursive(parent, ctx);
    }
    // Mark child frame pointers — defensive: check items.len before iterating
    // (children list may have been safely reset by detachFromParent)
    if (frame.children.items.len > 0) {
        for (frame.children.items) |child| {
            ctx.gc.markRecursive(child, ctx);
        }
    }
    // Mark overlay HAMT root (triggers recursive scanning of HAMT nodes)
    if (frame.overlay.root) |root| {
        ctx.gc.markRecursive(root, ctx);
    }
    // Mark memo cache entries (StringHashMapUnmanaged values are Value objects)
    if (frame.memo_cache.count() > 0) {
        var it = frame.memo_cache.iterator();
        while (it.next()) |entry| {
            scanValueChildrenDirect(&entry.value_ptr.*, ctx);
        }
    }
    // Mark root_env pointer
    ctx.gc.markRecursive(frame.root_env, ctx);
    // Mark function_ref if present
    if (frame.function_ref) |*ref| {
        scanValueChildrenDirect(ref, ctx);
    }
    // Mark body_form if present (Phase 9: trampoline body stored in Frame)
    if (frame.body_form) |*bf| {
        scanValueChildrenDirect(bf, ctx);
    }
}

/// Scan ExceptionData: { message, data, cause, type_kw, allocator }.
/// All child pointers must be marked so GC doesn't sweep them.
fn scanExceptionData(ed_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const ed: *vm.ExceptionData = @ptrCast(@alignCast(ed_ptr));
    // 1. Message string — owned (dupe), tagged as string_data
    if (ed.message.len > 0) {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(ed.message.ptr))), ctx);
    }
    // 2. type_kw string — owned (dupe), tagged as string_data
    if (ed.type_kw.len > 0) {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(ed.type_kw.ptr))), ctx);
    }
    // 3. Data map — SHARED *MapData pointer. Mark the block + all entries.
    ctx.gc.markRecursive(ed.data, ctx);
    for (ed.data.entries.items) |*entry| {
        scanValueChildrenDirect(&entry.key, ctx);
        scanValueChildrenDirect(&entry.value, ctx);
    }
    // 4. Cause — SHARED pointer to parent ExceptionData. Walk the chain.
    if (ed.cause) |cause| {
        ctx.gc.markRecursive(cause, ctx);
    }
}

/// Scan the value cache — marks all pre-cached singleton Value pointers.
fn scanValueCache(cache_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const cache: *vm.ValueCache = @ptrCast(@alignCast(cache_ptr));

    // Mark singleton pointers
    markPtr(cache.nil_ptr, ctx);
    markPtr(cache.true_ptr, ctx);
    markPtr(cache.false_ptr, ctx);

    // Mark math constants
    markPtr(cache.e_ptr, ctx);
    markPtr(cache.pi_ptr, ctx);

    // Mark empty collections (the *Value wrappers)
    markPtr(cache.empty_string_ptr, ctx);
    markPtr(cache.empty_list_ptr, ctx);
    markPtr(cache.empty_vector_ptr, ctx);
    markPtr(cache.empty_map_ptr, ctx);
    markPtr(cache.empty_set_ptr, ctx);

    // Mark the underlying data structures for empty collections
    // (these are GC-tracked and need to be marked too)
    if (std.meta.activeTag(cache.empty_list_ptr.*) == .list) {
        markPtr(cache.empty_list_ptr.*.list, ctx);
    }
    if (std.meta.activeTag(cache.empty_vector_ptr.*) == .vector) {
        markPtr(cache.empty_vector_ptr.*.vector, ctx);
    }
    if (std.meta.activeTag(cache.empty_map_ptr.*) == .map) {
        markPtr(cache.empty_map_ptr.*.map, ctx);
    }
    if (std.meta.activeTag(cache.empty_set_ptr.*) == .set) {
        markPtr(cache.empty_set_ptr.*.set, ctx);
    }

    // Mark all cached integer values
    for (cache.int_cache) |ptr| {
        markPtr(ptr, ctx);
    }

    // Mark all cached character values
    for (cache.char_cache) |ptr| {
        markPtr(ptr, ctx);
    }
}
