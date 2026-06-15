// gc_scan.zig — Scan function for the GC that understands Clojure Value structures.

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("value.zig");
const phm = @import("persistent_hash_map.zig");

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
        .hash_map_node => phm.scanHashMapNode(obj, ctx),
        .hash_map_kvp_array => scanKvpArray(obj, ctx, header.size),
        .hash_map_sub_nodes => scanSubNodesArray(obj, ctx, header.size),
        .env => scanEnv(obj, ctx),
        .namespace_manager => scanNamespaceManager(obj, ctx),
        .record_data => scanRecordData(obj, ctx),
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
/// (kept for backward compatibility — no longer used for Env entries)
fn scanEnvEntries(bytes_ptr: *anyopaque, ctx: *gc.ScanContext, total_size: usize) void {
    _ = bytes_ptr;
    _ = ctx;
    _ = total_size;
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
        .lazy_seq, .cons, .atom, .reduced, .wrapped, .record,
    };
    var is_valid = false;
    for (valid_types) |vt| {
        if (val.type == vt) { is_valid = true; break; }
    }
    if (!is_valid) return; // silently skip corrupt values

    switch (val.type) {
        .nil, .bool, .integer, .float, .character, .builtin_fn, .wrapped => {},

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
            // Mark the fn's env struct itself (heap-allocated *Env)
            const fn_env = val.fn_val.env;
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

        .record => {
            // Scan the RecordData directly (it's embedded in the Value, not a separate GC block)
            scanRecordData(@as(*anyopaque, @ptrCast(@constCast(&val.record_val))), ctx);
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
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(sc))), ctx);
    }
}

/// Scan AtomData: { value: Value, ref_count: usize }.
fn scanAtomData(data_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const data: *Value.AtomData = @ptrCast(@alignCast(data_ptr));
    scanValueChildrenDirect(&data.value, ctx);
}

/// Scan FnData: { arities: ArrayListUnmanaged(Arity), env: *Env }.
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
    const data: *Value.ConsData = @ptrCast(@alignCast(data_ptr));
    scanValueChildrenDirect(&data.head, ctx);
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
        if (kvp_ptr[i].val.type == .wrapped and kvp_ptr[i].val.wrapped_val != 0) {
            const ptr = @as(*anyopaque, @ptrFromInt(kvp_ptr[i].val.wrapped_val));
            ctx.gc.markRecursive(ptr, ctx);
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

/// Scan an Env struct: entries (PersistentHashMap), parent, ns_manager, referred_names.
fn scanEnv(env_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const env: *Value.Env = @ptrCast(@alignCast(env_ptr));

    // Mark the HAMT root node (triggers recursive scanning of all nodes)
    if (env.entries.root) |root| {
        ctx.gc.markRecursive(root, ctx);
    }
    // Mark referred_names list buffer and strings
    if (env.referred_names.items.len > 0) {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(env.referred_names.items.ptr)), ctx);
        for (env.referred_names.items) |name| {
            if (name.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(name.ptr))), ctx);
            }
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
    const rd: *Value.RecordData = @ptrCast(@alignCast(rd_ptr));
    // Mark type_name string
    if (rd.type_name.len > 0) {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(rd.type_name.ptr))), ctx);
    }
    // Mark fields map entries buffer (contains Value.MapEntry { key, value })
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

/// Scan a NamespaceManager struct.
fn scanNamespaceManager(ns_mgr_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const ns_mgr: *Value.NamespaceManager = @ptrCast(@alignCast(ns_mgr_ptr));

    // Mark current_ns string
    if (ns_mgr.current_ns.len > 0) {
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(ns_mgr.current_ns.ptr))), ctx);
    }
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
        ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(ns_mgr.classpath.items.ptr)), ctx);
        for (ns_mgr.classpath.items) |dir| {
            if (dir.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(dir.ptr))), ctx);
            }
        }
    }
}
