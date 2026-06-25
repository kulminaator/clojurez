// gc_scan.zig — Scan function for the GC that understands Clojure Value structures.

const std = @import("std");
const gc = @import("gc.zig");
const vm = @import("value.zig");
const Value = vm.Value;
const phm = @import("persistent_hash_map.zig");

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
    }
}

/// Heuristic scan for blocks without a type tag.
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
        .lazy_seq, .cons, .atom, .reduced, .wrapped, .record,
    };
    var is_valid = false;
    for (valid_types) |vt| {
        if (tag == vt) { is_valid = true; break; }
    }
    if (!is_valid) return; // silently skip corrupt values

    switch (val.*) {
        .nil, .bool, .integer, .float, .character, .builtin_fn, .wrapped => {},

        .bigint => |bi_ptr| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(bi_ptr)) return;
            // Mark the BigInt struct itself
            ctx.gc.markRecursive(bi_ptr, ctx);
            // Mark the limbs array inside BigInt
            if (bi_ptr.limbs.len > 0 and bi_ptr.owns_limbs) {
                ctx.gc.markRecursive(bi_ptr.limbs.ptr, ctx);
            }
        },

        .ratio => |r_ptr| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(r_ptr)) return;
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
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(d_ptr)) return;
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
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            // Mark the ListData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },
        .vector => |data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            // Mark the VectorData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },
        .map => |data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            // Mark the MapData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the entries array buffer
            if (data.entries.items.len > 0) {
                ctx.gc.markRecursive(data.entries.items.ptr, ctx);
            }
        },
        .set => |data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            // Mark the SetData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },
        .queue => |data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            // Mark the QueueData wrapper struct itself so GC can find it
            markPtr(data, ctx);
            // Mark the items array buffer
            if (data.items.items.len > 0) {
                ctx.gc.markRecursive(data.items.items.ptr, ctx);
            }
        },

        .function => |fn_data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(fn_data)) return;
            // Mark the FnData struct itself so GC can find arities and env
            ctx.gc.markRecursive(fn_data, ctx);
            // Mark the fn's name string (if GC-allocated)
            if (fn_data.name) |name| {
                if (name.len > 0) markPtr(name.ptr, ctx);
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
        },

        .lazy_seq => |thunk| {
            if (thunk) |t| {
                ctx.gc.markRecursive(t, ctx);
            }
        },

        .cons => |data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            // Mark the ConsData struct so GC can find head and tail
            ctx.gc.markRecursive(data, ctx);
        },

        .atom => |data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            ctx.gc.markRecursive(data, ctx);
        },

        .reduced => |data| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(data)) return;
            // Scan the wrapped value
            ctx.gc.markRecursive(data, ctx);
        },

        .record => |rd| {
            // Guard against scanUnknownBlock misidentifying non-Value blocks
            if (!isValidPtr(rd)) return;
            // Mark the RecordData block itself so it survives GC sweep
            markPtr(rd, ctx);
            // Then scan its children (type_name, fields, extmap, meta)
            scanRecordData(@as(*anyopaque, @ptrCast(@constCast(rd))), ctx);
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

/// Scan an Env struct: entries (PersistentHashMap), parent, ns_manager, referred_names.
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
