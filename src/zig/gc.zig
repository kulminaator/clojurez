// gc.zig — Standalone mark-and-sweep garbage collector
//
// Design:
// - All GC-tracked allocations have a Header prepended to them
// - Headers form a doubly-linked list of all live blocks
// - Each header has a 'marked' bit for the mark phase
// - Roots are registered with the GC and considered always reachable
// - collect() clears marks, marks from roots via a scan function, sweeps unmarked blocks
// - Sweep phase can be disabled at any time for debugging
// - Verbose debug logging can be enabled
//
// Usage:
//   var gc = GC.init(underlying_allocator);
//   defer gc.deinit();
//
//   const ptr = gc.alloc(size, alignment) orelse @panic("OOM");
//   gc.addRoot(ptr);
//
//   gc.collect(myScanFn);  // mark from roots, sweep unmarked
//
// The scan function is called for each marked object and should call
// ctx.gc.markRecursive(child_ptr, ctx) for each child pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

// ============================================================
// Block header — prepended to every GC allocation
// ============================================================

const MAGIC: u32 = 0x47434D4D; // "GCM\0"

/// Type tag for GC-tracked allocations.
/// Tells the scan function how to interpret the data area.
pub const GCObjectType = enum(u8) {
    unknown = 0,   // no child pointers (strings, raw buffers, etc.)
    value_array = 1, // array of Value objects (list items, vector items, etc.)
    map_entries = 2, // array of MapEntry { key: Value, value: Value }
    set_items = 3,   // array of Value objects (set items)
    env = 13,       // Env struct (namespace environment)
    namespace_manager = 14, // NamespaceManager struct
    queue_items = 4, // array of Value objects (queue items)
    lazy_seq_thunk = 5, // LazySeqThunk { params: list.List, body: list.List, env: Env }
    atom_data = 6,  // AtomData { value: Value, ref_count: usize }
    future_data = 27, // FutureData { state: atomic u32, result: ?Value, fn_val: ?Value, error_msg: ?[]u8, allocator }
    promise_data = 28, // PromiseData { state: atomic u32, value: ?Value, allocator }
    fn_data = 8,    // FnData { arities: ArrayListUnmanaged(Arity), env: Env }
    cons_data = 9,  // ConsData { head: Value, tail: Value, allocator: Allocator }
    hash_map_node = 10, // PersistentHashMap HAMT node (Node union)
    hash_map_kvp_array = 11, // array of Kvp { key: Value, val: Value } in HAMT
    hash_map_sub_nodes = 12, // array of ?*Node (sub-node pointers in HAMT)
    record_data = 15,        // RecordData { type_name, fields, extmap, meta, allocator }
    list_data = 16,   // ListData { items: ArrayListUnmanaged(Value) }
    vector_data = 17, // VectorData { items: ArrayListUnmanaged(Value) }
    map_data = 18,    // MapData { entries: ArrayListUnmanaged(MapEntry) }
    set_data = 19,    // SetData { items: ArrayListUnmanaged(Value) }
    queue_data = 20,  // QueueData { items: ArrayListUnmanaged(Value) }
    fn_arities = 21,  // array of Arity { params: list.List, body: list.List, rest_name }
    string_data = 22, // raw string bytes (no child pointers to scan)
    bigint_limbs = 23, // array of u64 limbs (BigInt/BigDecimal/Ratio internal storage)
    bigint_data = 24,  // BigInt struct { sign, limbs, allocator, owns_limbs }
    ratio_data = 25,   // Ratio struct { num: BigInt, den: BigInt }
    decimal_data = 26, // BigDecimal struct { unscaled: BigInt, scale: i32 }
    bytecode_program = 29, // BytecodeProgram { instructions, constants, symbols, source_markers, fn_pool }
    chunk_data = 30,         // ChunkData { items, off, end }
    chunked_cons_data = 31,  // ChunkedConsData { chunk, tail }
    frame = 32,              // Frame — virtual stack frame (heap-allocated evaluation frame)
    value_cache = 33,        // ValueCache — pre-cached singleton values (nil, bool, small int, latin char)
    exception_data = 34,     // ExceptionData — runtime exception value
    ref_data = 35,           // RefData — STM reference value
    multimethod_data = 36,   // MultimethodData — multimethod dispatch
    small_map = 37,          // SmallMap — linear array for small PersistentHashMaps (≤8 entries)
};

const Header = struct {
    magic: u32 = MAGIC,
    marked: bool = false,
    obj_type: GCObjectType = .unknown,
    generation: u32 = 0, // generation this block was allocated in
    size: usize = 0,
    offset: usize = 0, // bytes from header to data area (header_size + padding)
    alignment: Alignment = Alignment.of(u8), // original allocation alignment
    next: ?*Header = null,
    prev: ?*Header = null,
};

const HEADER_SIZE: usize = @sizeOf(Header);
const HEADER_ALIGNMENT = Alignment.of(Header);

// ============================================================
// ScanContext — passed to scan functions during the mark phase
// ============================================================

pub const ScanFn = *const fn (obj: *anyopaque, ctx: *ScanContext) void;

/// Callback that returns dynamic roots at collect time.
/// Called during the mark phase to get current root pointers.
/// Receives the ScanContext so the callback can call markRecursive.
pub const RootFn = *const fn (gc: *GC, ctx: *ScanContext) void;

pub const ScanContext = struct {
    gc: *GC,
    scan_fn: ScanFn,
};

/// Entry in the thread roots list. Each child thread registers its root frame
/// here so the GC can mark it during collection even though the frame is not
/// reachable from the main thread's evaluation context.
const ThreadRootEntry = struct {
    frame: *anyopaque,
    thread_id: u64,
};

// ============================================================
// GC — the garbage collector
// ============================================================

/// Global pointer to the current GC instance (set by main).
/// Used by repl and other modules to trigger collection.
pub var current_gc: ?*GC = null;

/// REPL input history buffer — registered as a root so it survives sweeps.
pub var repl_history_buffer: []const u8 = "";

// ============================================================
// Debug allocation tracker — tracks allocations per return address
// ============================================================
const DebugAllocEntry = struct {
    addr: usize,
    count: usize,
    total_bytes: usize,
    source_file: []const u8,
    source_line: usize,
};
var debug_alloc_entries: [256]DebugAllocEntry = undefined;
var debug_alloc_count: usize = 0;
var debug_alloc_enabled: bool = false;
var debug_alloc_total: usize = 0;

// Stack trace capture state - prints to stderr
var stack_trace_capture_active: bool = false;
var stack_trace_capture_count: usize = 0;
var stack_trace_capture_limit: usize = 0;

/// Start capturing stack traces (prints to stderr).
pub fn debugAllocStartCapture(limit: usize) void {
    stack_trace_capture_active = true;
    stack_trace_capture_count = 0;
    stack_trace_capture_limit = limit;
}

/// Stop capturing stack traces.
pub fn debugAllocStopCapture() void {
    stack_trace_capture_active = false;
}

/// Write a stack trace for the current allocation to stderr.
fn debugAllocWriteStackTrace(size: usize) void {
    if (!stack_trace_capture_active) return;
    if (stack_trace_capture_count >= stack_trace_capture_limit) {
        stack_trace_capture_active = false;
        return;
    }

    var buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "\n--- Alloc #{d} size={d} ---\n", .{ stack_trace_capture_count + 1, size }) catch "";
    std.debug.print("{s}", .{header});

    // Capture stack trace (raw addresses)
    var addr_buf: [64]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{}, &addr_buf);
    var i: usize = 0;
    while (i < trace.return_addresses.len) : (i += 1) {
        const ret_addr = trace.return_addresses[i];
        std.debug.print("  0x{x}\n", .{ret_addr});
    }
    stack_trace_capture_count += 1;
}

/// Enable debug allocation tracking. Call before the code you want to measure.
pub fn debugAllocEnable() void {
    debug_alloc_enabled = true;
    debug_alloc_count = 0;
    debug_alloc_total = 0;
}

/// Disable debug allocation tracking.
pub fn debugAllocDisable() void {
    debug_alloc_enabled = false;
}

/// Record an allocation from a specific return address.
fn debugAllocRecord(addr: usize, size: usize, src: std.builtin.SourceLocation) void {
    if (!debug_alloc_enabled) return;
    // Look for existing entry
    var i: usize = 0;
    while (i < debug_alloc_count) : (i += 1) {
        if (debug_alloc_entries[i].addr == addr) {
            debug_alloc_entries[i].count += 1;
            debug_alloc_entries[i].total_bytes += size;
            return;
        }
    }
    // Add new entry
    if (debug_alloc_count < 256) {
        debug_alloc_entries[debug_alloc_count] = .{
            .addr = addr,
            .count = 1,
            .total_bytes = size,
            .source_file = src.file,
            .source_line = src.line,
        };
        debug_alloc_count += 1;
    }
}

/// Print the top 20 allocation sources by total bytes.
pub fn debugAllocPrintTop() void {
    if (!debug_alloc_enabled and debug_alloc_count == 0) return;
    std.log.err("\n=== TOP ALLOCATION SOURCES (by bytes) ===\n", .{});
    // Sort by total_bytes descending (simple insertion sort)
    var i: usize = 1;
    while (i < debug_alloc_count) : (i += 1) {
        var j = i;
        while (j > 0 and debug_alloc_entries[j - 1].total_bytes < debug_alloc_entries[j].total_bytes) : (j -= 1) {
            const tmp = debug_alloc_entries[j - 1];
            debug_alloc_entries[j - 1] = debug_alloc_entries[j];
            debug_alloc_entries[j] = tmp;
        }
    }
    const limit = if (debug_alloc_count < 20) debug_alloc_count else 20;
    var k: usize = 0;
    while (k < limit) : (k += 1) {
        const e = debug_alloc_entries[k];
        std.log.err("  #{d}: addr=0x{x} {s}:{d} count={d} bytes={d} ({d}KB)\n",
            .{ k + 1, e.addr, e.source_file, e.source_line, e.count, e.total_bytes, e.total_bytes / 1024 });
    }
    std.log.err("=== END TOP ALLOCATION SOURCES ===\n", .{});
}

// ============================================================
// Debug: print every allocation (with size and return address)
// ============================================================
var debug_print_allocs_active: bool = false;
var debug_print_allocs_count: usize = 0;
var debug_print_allocs_limit: usize = 0;

/// Start printing every allocation to stderr.
pub fn debugPrintAllocsStart(limit: usize) void {
    debug_print_allocs_active = true;
    debug_print_allocs_count = 0;
    debug_print_allocs_limit = limit;
}

/// Stop printing every allocation.
pub fn debugPrintAllocsStop() void {
    debug_print_allocs_active = false;
}

/// Print the current allocation to stderr with stack trace.
fn debugPrintAlloc(size: usize, return_addr: usize) void {
    _ = return_addr;
    if (!debug_print_allocs_active) return;
    if (debug_print_allocs_count >= debug_print_allocs_limit) {
        debug_print_allocs_active = false;
        return;
    }
    std.debug.print("[ALLOC #{d}] size={d}\n", .{ debug_print_allocs_count + 1, size });

    // Capture stack trace to find the real caller
    var addr_buf: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{}, &addr_buf);
    // Skip the first few frames (debugPrintAlloc, alloc, allocVTable, slab, etc.)
    // to find the meaningful caller.
    var i: usize = 0;
    const skip_frames: usize = 5;
    while (i < trace.return_addresses.len and i < skip_frames + 3) : (i += 1) {
        if (i >= skip_frames) {
            std.debug.print("  caller: 0x{x}\n", .{trace.return_addresses[i]});
        }
    }
    debug_print_allocs_count += 1;
}

// ============================================================
// Debug type-based allocation snapshot — counts blocks by GCObjectType
// ============================================================

/// Snapshot of block counts and bytes by GC object type.
pub const DebugTypeSnapshot = struct {
    /// Count of blocks per type (indexed by GCObjectType integer value).
    counts: [38]usize = .{0} ** 38,
    /// Total bytes per type.
    bytes: [38]usize = .{0} ** 38,
    /// Total alloc-count at time of snapshot.
    alloc_count: usize = 0,
    /// Total current-allocated at time of snapshot.
    current_allocated: usize = 0,
};

/// Take a snapshot of all GC blocks, counting by object type.
pub fn debugTypeSnapshot() DebugTypeSnapshot {
    var snapshot: DebugTypeSnapshot = .{};
    if (current_gc) |gc| {
        snapshot.alloc_count = gc.alloc_count;
        snapshot.current_allocated = gc.current_allocated;
        var block = gc.blocks;
        while (block) |b| {
            const type_idx: usize = @intFromEnum(b.obj_type);
            if (type_idx < snapshot.counts.len) {
                snapshot.counts[type_idx] += 1;
                snapshot.bytes[type_idx] += b.size;
            }
            block = b.next;
        }
    }
    return snapshot;
}

/// Print the difference between two type snapshots.
pub fn debugTypeSnapshotDiff(before: DebugTypeSnapshot, after: DebugTypeSnapshot) void {
    const type_names = [_][]const u8{
        "unknown", "value_array", "map_entries", "set_items", "queue_items",
        "lazy_seq_thunk", "atom_data", "future_data", "promise_data",
        "fn_data", "cons_data", "hash_map_node", "hash_map_kvp_array", "hash_map_sub_nodes",
        "env", "namespace_manager", "record_data", "list_data", "vector_data",
        "map_data", "set_data", "queue_data", "fn_arities", "string_data",
        "bigint_limbs", "bigint_data", "ratio_data", "decimal_data",
        "bytecode_program", "chunk_data", "chunked_cons_data", "frame",
        "value_cache", "exception_data", "ref_data", "multimethod_data",
        "small_map",
    };

    std.log.err("\n=== ALLOCATION DIFF (type | before | after | delta count | delta bytes) ===\n", .{});
    var total_delta_count: usize = 0;
    var total_delta_bytes: usize = 0;
    var i: usize = 0;
    while (i < type_names.len) : (i += 1) {
        const count_before = if (i < before.counts.len) before.counts[i] else 0;
        const count_after = if (i < after.counts.len) after.counts[i] else 0;
        const bytes_before = if (i < before.bytes.len) before.bytes[i] else 0;
        const bytes_after = if (i < after.bytes.len) after.bytes[i] else 0;
        const delta_count = if (count_after > count_before) count_after - count_before else 0;
        const delta_bytes = if (bytes_after > bytes_before) bytes_after - bytes_before else 0;
        if (delta_count > 0 or delta_bytes > 0) {
            std.log.err("  {s}: {d} -> {d}  (+{d} blocks, +{d} bytes)\n",
                .{ type_names[i], count_before, count_after, delta_count, delta_bytes });
            total_delta_count += delta_count;
            total_delta_bytes += delta_bytes;
        }
    }
    std.log.err("  TOTAL: +{d} blocks, +{d} bytes\n", .{ total_delta_count, total_delta_bytes });
    std.log.err("=== END ALLOCATION DIFF ===\n", .{});
}

/// Print a full type snapshot (not diff).
pub fn debugTypeSnapshotPrint(label: []const u8, snapshot: DebugTypeSnapshot) void {
    const type_names = [_][]const u8{
        "unknown", "value_array", "map_entries", "set_items", "queue_items",
        "lazy_seq_thunk", "atom_data", "future_data", "promise_data",
        "fn_data", "cons_data", "hash_map_node", "hash_map_kvp_array", "hash_map_sub_nodes",
        "env", "namespace_manager", "record_data", "list_data", "vector_data",
        "map_data", "set_data", "queue_data", "fn_arities", "string_data",
        "bigint_limbs", "bigint_data", "ratio_data", "decimal_data",
        "bytecode_program", "chunk_data", "chunked_cons_data", "frame",
        "value_cache", "exception_data", "ref_data", "multimethod_data",
        "small_map",
    };

    std.log.err("\n=== TYPE SNAPSHOT: {s} (alloc-count={d}, current-allocated={d}) ===\n",
        .{ label, snapshot.alloc_count, snapshot.current_allocated });
    var i: usize = 0;
    while (i < type_names.len) : (i += 1) {
        const count = if (i < snapshot.counts.len) snapshot.counts[i] else 0;
        const bytes = if (i < snapshot.bytes.len) snapshot.bytes[i] else 0;
        if (count > 0) {
            std.log.err("  {s}: {d} blocks, {d} bytes ({d}KB)\n",
                .{ type_names[i], count, bytes, bytes / 1024 });
        }
    }
    std.log.err("=== END TYPE SNAPSHOT ===\n", .{});
}

pub const GC = struct {
    const Self = @This();

    wrapped: Allocator,

    // Doubly-linked list of all allocated blocks.
    // Protected by block_mutex for thread safety.
    blocks: ?*Header = null,
    block_count: usize = 0,
    // Simple spin-lock for block list access.
    // 0 = unlocked, 1 = locked. Acquired before any block list modification.
    block_mutex: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    // Root pointers (always considered reachable)
    roots: std.ArrayListUnmanaged(*anyopaque) = .empty,
    // Permanent roots: objects that must NEVER be swept (namespaces, function defs, global constants).
    // Marked at the start of every collect cycle — always reachable, never collected.
    permanent_roots: std.ArrayListUnmanaged(*anyopaque) = .empty,
    // Optional callback that registers dynamic roots at collect time.
    // Useful for roots that change address (e.g., HashMap entries after resize).
    root_fn: ?RootFn = null,
    // Temporary roots stack: push/pop HAMT root pointers from stack-allocated Env structs.
    // These are in-use pointers the GC can't discover through normal scanning.
    // Marked during collect() to prevent sweeping of in-flight HAMT nodes.
    temp_roots: std.ArrayListUnmanaged(*anyopaque) = .empty,

    // Debug flags
    sweep_enabled: bool = true,
    verbose: bool = false,

    // GC lock counter: prevents concurrent GC collection while child threads are running.
    // Uses a counter instead of binary lock to support nested threads (e.g., nested futures).
    // Each child thread increments on start, decrements on end.
    // GC only collects when counter is 0 (no child threads active).
    gc_lock: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Active thread counter: tracks how many detached threads are still running.
    // Incremented in threadStart, decremented in threadDone.
    // Main thread waits for this to reach 0 before shutting down the GC.
    active_thread_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Thread roots: per-thread entry frames registered by child threads.
    // Protected by thread_roots_mutex (atomic spinlock) for thread safety.
    // MEMORY_MODEL.md R6: Thread root rule — register entry frame on thread start,
    // unregister on thread end. GC marks these during collection.
    thread_roots_mutex: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    thread_roots: std.ArrayListUnmanaged(ThreadRootEntry) = .empty,

    // Auto-GC: trigger collection when memory grows past threshold since last sweep.
    // Threshold = max(last_collected_memory * 20%, 1MB).
    scan_fn: ?ScanFn = null,
    last_collected_memory: usize = 0,
    auto_gc_active: bool = false,
    auto_gc_pending: bool = false,
    // Deferred sweep: when gc-sweep is called from within Clojure evaluation,
    // we can't safely free in-flight values (stack-local pointers the GC can't see).
    // Instead, we mark and defer the actual sweep to the next safe point.
    manual_sweep_pending: bool = false,

    // Generational sweep protection: blocks allocated in the current generation
    // are never swept, even if unreachable. This protects in-flight evaluation
    // state when gc-sweep is called from within Clojure code.
    generation: u32 = 0,

    // Temporary hash table for O(1) header lookup during collect.
    // Simple open-addressing hash table for *anyopaque → *Header mapping.
    header_table_keys: []?*anyopaque = &.{},
    header_table_vals: []?*Header = &.{},
    header_table_cap: usize = 0,
    header_table_len: usize = 0,

    // Statistics
    alloc_count: usize = 0,
    free_count: usize = 0,
    gc_count: usize = 0,
    total_allocated: usize = 0,
    current_allocated: usize = 0,
    peak_allocated: usize = 0,
    swept_count: usize = 0,
    swept_bytes: usize = 0,

    // Allocator vtable (stored inline so pointer stays valid)
    vtable: std.mem.Allocator.VTable,

    pub fn init(wrapped: Allocator) GC {
        return .{
            .wrapped = wrapped,
            .vtable = .{
                .alloc = allocVTable,
                .resize = resizeVTable,
                .remap = remapVTable,
                .free = freeVTable,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.freeHeaderTable();
        self.log("[GC] DEINIT: blocks={d} live={d}\n", .{ self.block_count, self.current_allocated });

        // At program exit, the OS reclaims all memory anyway.
        // Freeing blocks individually through the slab allocator is O(blocks × pages)
        // because slabFree does a linear page search for each free.
        // With hundreds of thousands of blocks, this causes ~1.5s shutdown delay.
        // Instead, skip individual block freeing and let the slab allocator's
        // deinit handle cleanup efficiently (frees all pages directly).
        // Just clean up our bookkeeping structures.
        self.blocks = null;
        self.block_count = 0;

        // Free the roots array (small allocation, not via slab)
        if (self.roots.items.len > 0) {
            self.wrapped.free(self.roots.items);
        }
        self.roots = .empty;

        // Free permanent_roots array
        if (self.permanent_roots.items.len > 0) {
            self.wrapped.free(self.permanent_roots.items);
        }
        self.permanent_roots = .empty;

        // Free temp_roots array if any
        if (self.temp_roots.items.len > 0) {
            self.wrapped.free(self.temp_roots.items);
        }
        self.temp_roots = .empty;

        // Free thread_roots array
        if (self.thread_roots.items.len > 0) {
            self.wrapped.free(self.thread_roots.items);
        }
        self.thread_roots = .empty;
    }

    /// Return a std.mem.Allocator backed by the GC.
    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &self.vtable,
        };
    }

    /// Allocate a GC-tracked object of the given size and alignment.
    pub fn alloc(self: *Self, size: usize, alignment: Alignment) ?*anyopaque {
        const actual_size: usize = if (size == 0) 1 else size;

        // Debug: track allocation source
        debugAllocRecord(@returnAddress(), actual_size, @src());
        if (debug_alloc_enabled) {
            debug_alloc_total += 1;
        }
        // Stack trace capture (writes to file)
        debugAllocWriteStackTrace(actual_size);
        // Print every allocation (when active)
        debugPrintAlloc(actual_size, @returnAddress());

        // Convert log2 alignment to actual alignment value
        const data_align: usize = @as(usize, 1) << @intFromEnum(alignment);
        const padding: usize = if (HEADER_SIZE % data_align != 0)
            data_align - (HEADER_SIZE % data_align)
        else
            0;
        const total = HEADER_SIZE + padding + actual_size;

        // Allocate memory aligned to Header alignment.
        const header_align = Alignment.of(Header);
        const mem = self.wrapped.rawAlloc(total, header_align, @returnAddress()) orelse return null;

        // Reinterpret as Header pointer.
        const header: *Header = @alignCast(@ptrCast(mem));
        header.* = .{
            .size = actual_size,
            .offset = HEADER_SIZE + padding,
            .alignment = alignment,
            .generation = self.generation,
            .next = self.blocks,
            .prev = null,
        };

        // Append to head of block list under mutex for thread safety.
        while (self.block_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        defer self.block_mutex.store(0, .release);
        header.next = self.blocks;
        header.prev = null;
        if (self.blocks) |first| first.prev = header;
        self.blocks = header;
        self.block_count += 1;

        self.alloc_count += 1;
        self.total_allocated += actual_size;
        self.current_allocated += actual_size;
        if (self.current_allocated > self.peak_allocated) self.peak_allocated = self.current_allocated;

        // Auto-GC: track whether threshold is exceeded. Actual collection
        // happens at safe points (between form evaluations), not here,
        // because in-flight allocations are not yet reachable from roots.
        if (self.auto_gc_active) {
            const growth = self.current_allocated - self.last_collected_memory;
            const percent_threshold = (self.last_collected_memory * 20) / 100;
            const min_threshold: usize = 1024 * 1024; // 1MB
            const threshold = if (percent_threshold > min_threshold) percent_threshold else min_threshold;
            if (growth >= threshold) {
                self.auto_gc_pending = true;
            }
        }

        const data_ptr = @as(*anyopaque, @ptrCast(mem + HEADER_SIZE + padding));
        self.log("[GC] ALLOC size={d} align={d} ptr={*} blocks={d} live={d}\n",
            .{ actual_size, @intFromEnum(alignment), data_ptr, self.block_count, self.current_allocated });

        return data_ptr;
    }

    /// Allocate a GC-tracked object with a type tag for scanning.
    pub fn allocTyped(self: *Self, size: usize, alignment: Alignment, obj_type: GCObjectType) ?*anyopaque {
        const ptr = self.alloc(size, alignment) orelse return null;
        // Set the type on the header
        const header = self.findHeader(ptr) orelse return ptr;
        header.obj_type = obj_type;
        return ptr;
    }

    /// Set the type of an existing GC-tracked block (e.g. after reallocation).
    pub fn setObjectType(self: *Self, ptr: *anyopaque, obj_type: GCObjectType) void {
        const header = self.findHeader(ptr) orelse return;
        header.obj_type = obj_type;
    }

    /// Free a GC-tracked object manually. Returns true if found and freed.
    pub fn free(self: *Self, ptr: ?*anyopaque) bool {
        if (ptr == null) return false;
        const real_ptr: *anyopaque = ptr.?;
        const header = self.findHeader(real_ptr) orelse return false;
        return self.freeHeader(header);
    }

    /// Internal: free a block given its header.
    fn freeHeader(self: *Self, header: *Header) bool {
        // Remove from linked list under mutex for thread safety.
        while (self.block_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        defer self.block_mutex.store(0, .release);
        if (header.prev) |prev| {
            prev.next = header.next;
        } else {
            self.blocks = header.next;
        }
        if (header.next) |next| {
            next.prev = header.prev;
        }
        self.block_count -= 1;

        // Save size before freeing
        const block_size = header.size;
        const total = header.offset + block_size;
        const block_start = @as([*]u8, @ptrCast(header));
        // Free with HEADER_ALIGNMENT to match the allocation alignment used in alloc().
        self.wrapped.rawFree(block_start[0..total], HEADER_ALIGNMENT, @returnAddress());

        self.free_count += 1;
        if (block_size > self.current_allocated) {
            self.current_allocated = 0;
        } else {
            self.current_allocated -= block_size;
        }

        return true;
    }

    /// Find the header for a data pointer.
    /// Uses hash table for O(1) lookup during collect, falls back to linear scan.
    pub fn findHeader(self: *Self, dataPtr: *anyopaque) ?*Header {
        // Fast path: use hash table if built
        if (self.header_table_len > 0) {
            const header = self.headerTableGet(dataPtr);
            if (header) |h| return h;
            // Not in table — this pointer is not a GC-tracked block
            return null;
        }
        // Slow path: linear scan
        return self.findHeaderSlow(dataPtr);
    }

    /// Build hash table from block list for O(1) lookup.
    fn buildHeaderTable(self: *Self) void {
        // Calculate needed capacity (load factor ~0.5), power of 2
        const needed = self.block_count * 2;
        var new_cap: usize = 16;
        while (new_cap < needed) : (new_cap *= 2) {}

        // Allocate if needed
        if (self.header_table_keys.len < new_cap) {
            if (self.header_table_cap > 0) {
                self.wrapped.free(self.header_table_keys);
                self.wrapped.free(self.header_table_vals);
            }
            self.header_table_keys = self.wrapped.alloc(?*anyopaque, new_cap) catch @panic("GC OOM");
            self.header_table_vals = self.wrapped.alloc(?*Header, new_cap) catch @panic("GC OOM");
        }
        self.header_table_cap = new_cap;
        self.header_table_len = 0;

        // Clear table
        var i: usize = 0;
        while (i < self.header_table_cap) : (i += 1) {
            self.header_table_keys[i] = null;
            self.header_table_vals[i] = null;
        }

        // Insert all blocks
        var block = self.blocks;
        while (block) |b| {
            const data = @as(*anyopaque, @ptrCast(@as([*]u8, @ptrCast(b)) + b.offset));
            self.headerTablePut(data, b);
            block = b.next;
        }
    }

    /// Hash function for pointers.
    fn hashPtr(self: *Self, ptr: *anyopaque) usize {
        _ = self;
        const addr: usize = @intFromPtr(ptr);
        // Simple but effective hash for pointers
        return addr ^ (addr >> 14) ^ (addr >> 28);
    }

    /// Insert into hash table.
    fn headerTablePut(self: *Self, key: *anyopaque, val: *Header) void {
        const cap = self.header_table_cap;
        const mask = cap - 1;
        var idx = self.hashPtr(key) & mask;
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            if (self.header_table_keys[idx] == null) {
                self.header_table_keys[idx] = key;
                self.header_table_vals[idx] = val;
                self.header_table_len += 1;
                return;
            }
            if (self.header_table_keys[idx] == key) {
                self.header_table_vals[idx] = val;
                return;
            }
            idx = (idx + 1) & mask;
        }
    }

    /// Lookup in hash table.
    fn headerTableGet(self: *Self, key: *anyopaque) ?*Header {
        const cap = self.header_table_cap;
        const mask = cap - 1;
        var idx = self.hashPtr(key) & mask;
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            const entry = self.header_table_keys[idx];
            if (entry == null) return null; // empty slot
            if (entry == key) return self.header_table_vals[idx];
            idx = (idx + 1) & mask;
        }
        return null;
    }

    /// Free hash table memory.
    fn freeHeaderTable(self: *Self) void {
        if (self.header_table_keys.len > 0) {
            self.wrapped.free(self.header_table_keys);
            self.wrapped.free(self.header_table_vals);
        }
        self.header_table_keys = &.{};
        self.header_table_vals = &.{};
        self.header_table_cap = 0;
        self.header_table_len = 0;
    }

    /// Walk the block list to find the header for a data pointer.
    /// Slow fallback for pointers not allocated through gc.alloc.
    fn findHeaderSlow(self: *Self, dataPtr: *anyopaque) ?*Header {
        // Hold block mutex to prevent concurrent modification.
        while (self.block_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        defer self.block_mutex.store(0, .release);
        var block = self.blocks;
        while (block) |b| {
            const data = @as(*anyopaque, @ptrCast(@as([*]u8, @ptrCast(b)) + b.offset));
            if (data == dataPtr) return b;
            block = b.next;
        }
        return null;
    }

    /// Add a root pointer (always considered reachable).
    pub fn addRoot(self: *Self, root: *anyopaque) void {
        self.roots.append(self.wrapped, root) catch {};
        self.log("[GC] ADD_ROOT ptr={*} roots={d}\n", .{ root, self.roots.items.len });
    }

    /// Remove a root pointer.
    pub fn removeRoot(self: *Self, root: *anyopaque) void {
        var i: usize = 0;
        while (i < self.roots.items.len) : (i += 1) {
            if (self.roots.items[i] == root) {
                _ = self.roots.swapRemove(i);
                self.log("[GC] REMOVE_ROOT ptr={*} roots={d}\n", .{ root, self.roots.items.len });
                return;
            }
        }
    }

    /// Add a permanent root pointer (never collected under any circumstances).
    /// Used for namespace environments, function definitions, and global constants.
    /// Permanent roots are marked at the start of every collect cycle,
    /// ensuring they and everything reachable from them are never swept.
    pub fn addPermanentRoot(self: *Self, root: *anyopaque) void {
        // Avoid duplicates
        var i: usize = 0;
        while (i < self.permanent_roots.items.len) : (i += 1) {
            if (self.permanent_roots.items[i] == root) return;
        }
        self.permanent_roots.append(self.wrapped, root) catch {};
        self.log("[GC] ADD_PERMANENT_ROOT ptr={*} perm_roots={d}\n", .{ root, self.permanent_roots.items.len });
    }

    /// Remove a permanent root pointer.
    /// Use sparingly — typically permanent roots are added at startup and never removed.
    pub fn removePermanentRoot(self: *Self, root: *anyopaque) void {
        var i: usize = 0;
        while (i < self.permanent_roots.items.len) : (i += 1) {
            if (self.permanent_roots.items[i] == root) {
                _ = self.permanent_roots.swapRemove(i);
                self.log("[GC] REMOVE_PERMANENT_ROOT ptr={*} perm_roots={d}\n", .{ root, self.permanent_roots.items.len });
                return;
            }
        }
    }

    // ============================================================
    // Thread root registration (Phase 8: Thread Safety Integration)
    // MEMORY_MODEL.md R6: Thread root rule
    // ============================================================

    /// Register a thread's entry frame as a GC root.
    /// Called by child threads before evaluation starts.
    /// Thread-safe: protected by thread_roots_mutex (atomic spinlock).
    pub fn registerThreadRoot(self: *Self, frame: *anyopaque) void {
        while (self.thread_roots_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        defer self.thread_roots_mutex.store(0, .release);
        const id = std.Thread.getCurrentId();
        self.thread_roots.append(self.wrapped, .{ .frame = frame, .thread_id = id }) catch {};
        self.log("[GC] REGISTER_THREAD_ROOT thread={any} ptr={*}\n", .{ id, frame });
    }

    /// Unregister the current thread's entry frame from GC roots.
    /// Called by child threads after evaluation completes.
    /// Thread-safe: protected by thread_roots_mutex (atomic spinlock).
    pub fn unregisterThreadRoot(self: *Self) void {
        while (self.thread_roots_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        defer self.thread_roots_mutex.store(0, .release);
        const id = std.Thread.getCurrentId();
        var i: usize = 0;
        while (i < self.thread_roots.items.len) : (i += 1) {
            if (self.thread_roots.items[i].thread_id == id) {
                _ = self.thread_roots.swapRemove(i);
                self.log("[GC] UNREGISTER_THREAD_ROOT thread={any} roots={d}\n", .{ id, self.thread_roots.items.len });
                return;
            }
        }
    }

    /// Push a temporary root pointer onto the stack.
    /// Used to protect HAMT nodes reachable from stack-allocated Env structs.
    /// Must be paired with popTempRoot (use defer for safety).
    pub fn pushTempRoot(self: *Self, root: *anyopaque) void {
        self.temp_roots.append(self.wrapped, root) catch {};
    }

    /// Pop the most recent temporary root from the stack.
    pub fn popTempRoot(self: *Self) void {
        if (self.temp_roots.items.len > 0) {
            _ = self.temp_roots.pop();
        }
    }

    /// Full mark-and-sweep collection cycle.
    pub fn collect(self: *Self, scan_fn: ScanFn) void {
        // Advance generation: blocks allocated in the new generation
        // are protected from sweeping (in-flight evaluation state).
        self.generation += 1;

        self.log("[GC] === COLLECT START blocks={d} perm_roots={d} roots={d} gen={d} ===\n",
            .{ self.block_count, self.permanent_roots.items.len, self.roots.items.len, self.generation });

        // Build O(1) header lookup table for this collection cycle.
        self.buildHeaderTable();
        defer self.freeHeaderTable();

        // Phase 1: Clear all marks under block mutex.
        while (self.block_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        var block = self.blocks;
        while (block) |b| {
            b.marked = false;
            block = b.next;
        }
        self.block_mutex.store(0, .release);

        // Phase 2: Mark from permanent roots FIRST (namespaces, function defs, globals).
        // These are always reachable — they must never be swept.
        var ctx = ScanContext{ .gc = self, .scan_fn = scan_fn };
        for (self.permanent_roots.items) |root| {
            self.markRecursive(root, &ctx);
        }

        // Phase 2.1: Mark from static roots
        for (self.roots.items) |root| {
            self.markRecursive(root, &ctx);
        }

        // Phase 2.5: Mark from temporary roots (HAMT nodes from stack-allocated Env structs)
        for (self.temp_roots.items) |root| {
            self.markRecursive(root, &ctx);
        }

        // Phase 2.7: Mark from thread roots (child thread entry frames)
        // Thread-safe: spinlock while iterating.
        while (self.thread_roots_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        for (self.thread_roots.items) |entry| {
            self.markRecursive(entry.frame, &ctx);
        }
        self.thread_roots_mutex.store(0, .release);

        // Phase 3: Call root callback for dynamic roots (marks via ScanContext)
        if (self.root_fn) |fn_ptr| {
            fn_ptr(self, &ctx);
        }

        // Phase 4: Sweep unmarked blocks
        self.sweep();

        self.gc_count += 1;
        // Record memory level after sweep for auto-GC threshold tracking.
        self.last_collected_memory = self.current_allocated;
        self.log("[GC] === COLLECT END blocks={d} live={d} ===\n",
            .{ self.block_count, self.current_allocated });
    }

    /// Mark a single object as reachable without scanning its children.
    /// Use this for raw buffers (e.g., REPL input history) that contain
    /// no child Value pointers and should simply survive sweeps.
    pub fn mark(self: *Self, ptr: ?*anyopaque) void {
        if (ptr == null) return;
        const real_ptr: *anyopaque = ptr.?;
        const header = self.findHeader(real_ptr) orelse return;
        header.marked = true;
    }

    /// Mark a single object and recursively mark its children via the scan function.
    pub fn markRecursive(self: *Self, ptr: ?*anyopaque, ctx: *ScanContext) void {
        if (ptr == null) return;
        const real_ptr: *anyopaque = ptr.?;

        const header = self.findHeader(real_ptr) orelse return;
        if (header.marked) return;

        header.marked = true;

        self.log("[GC] MARK ptr={*} size={d}\n", .{ real_ptr, header.size });

        // Scan children — the scan function calls ctx.gc.markRecursive for each child
        ctx.scan_fn(real_ptr, ctx);
    }

    /// Sweep phase: free all unmarked blocks.
    fn sweep(self: *Self) void {
        if (!self.sweep_enabled) {
            self.log("[GC] SWEEP DISABLED — skipping\n", .{});
            return;
        }

        // Hold block mutex for entire sweep to prevent concurrent alloc/free.
        while (self.block_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
        defer self.block_mutex.store(0, .release);

        var block = self.blocks;
        var swept: usize = 0;
        var swept_bytes: usize = 0;

        while (block) |b| {
            const next = b.next;
            // Generational protection: never sweep blocks from the current,
            // previous, or second-previous generation. This provides safety
            // for multithreaded access where child threads may hold references
            // to blocks that the GC's mark phase can't discover (e.g., HAMT
            // nodes reachable through stack-allocated Env structs in child threads).
            // A block must be at least 3 generations old to be swept.
            const protected_gen = if (self.generation > 1) self.generation - 2 else 0;
            if (!b.marked and b.generation < protected_gen) {
                // Remove from linked list
                if (b.prev) |prev| {
                    prev.next = b.next;
                } else {
                    self.blocks = b.next;
                }
                if (b.next) |nxt| {
                    nxt.prev = b.prev;
                }
                self.block_count -= 1;

                // Save size before freeing
                const sweep_size = b.size;
                const sweep_offset = b.offset;
                const total = sweep_offset + sweep_size;
                const block_start = @as([*]u8, @ptrCast(b));
                // Mark GC-swept memory with 0xFE so we can recognize it
                @memset(block_start[sweep_offset .. sweep_offset + sweep_size], 0xFE);
                // Free with HEADER_ALIGNMENT to match the allocation alignment used in alloc().
                self.wrapped.rawFree(block_start[0..total], HEADER_ALIGNMENT, @returnAddress());

                swept += 1;
                swept_bytes += sweep_size;
                if (sweep_size > self.current_allocated) {
                    self.current_allocated = 0;
                } else {
                    self.current_allocated -= sweep_size;
                }

                self.log("[GC] SWEEP ptr={*} size={d}\n",
                    .{ @as(*anyopaque, @ptrCast(block_start + sweep_offset)), sweep_size });
            }
            block = next;
        }

        self.swept_count += swept;
        self.swept_bytes += swept_bytes;

        self.log("[GC] SWEEP DONE: swept {d} blocks ({d} bytes) live={d}\n",
            .{ swept, swept_bytes, self.current_allocated });
    }

    /// Toggle sweep on/off (useful for debugging).
    pub fn setSweepEnabled(self: *Self, enabled: bool) void {
        self.sweep_enabled = enabled;
        self.log("[GC] SWEEP {s}\n", .{ if (enabled) "ENABLED" else "DISABLED" });
    }

    /// Aggressively free ALL GC-tracked blocks, regardless of reachability.
    /// Used by Zig unit tests to clean up GC-allocated memory at test end.
    /// Unlike normal collect(), this does NOT mark reachable objects — it
    /// simply walks the block list and frees every single block.
    /// Safe to call multiple times (idempotent after first call).
pub fn freeAllBlocks(self: *Self) void {
        // Walk the entire linked list and free every block.
        // Each iteration removes the block from the list and frees its memory.
        while (self.blocks) |header| {
            const total = header.offset + header.size;
            const block_start = @as([*]u8, @ptrCast(header));

            // Remove from linked list under mutex.
            while (self.block_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
            if (header.prev) |prev| {
                prev.next = header.next;
            } else {
                self.blocks = header.next;
            }
            if (header.next) | nxt | {
                nxt.prev = header.prev;
            }
            self.block_count -= 1;
            self.block_mutex.store(0, .release);

            // Free with HEADER_ALIGNMENT to match the allocation alignment used in alloc().
            self.wrapped.rawFree(block_start[0..total], HEADER_ALIGNMENT, @returnAddress());
            self.free_count += 1;
        }
        self.current_allocated = 0;
    }

    /// Enable automatic GC: trigger collection when memory grows by
    /// max(last_collected_memory * 20%, 1MB) since the last sweep.
    /// The scan_fn is stored so alloc() can invoke collect() without a caller.
    /// Baseline memory is captured at enable time.
    pub fn setAutoGC(self: *Self, scan_fn: ScanFn) void {
        self.scan_fn = scan_fn;
        self.last_collected_memory = self.current_allocated;
        self.auto_gc_active = true;
        self.log("[GC] AUTO-GC ENABLED baseline={d}\n", .{self.last_collected_memory});
    }

    /// Check if auto-GC threshold was exceeded and collect if so.
    /// Also handles deferred manual sweeps (from zig.core/gc-sweep called
    /// during evaluation). Call this at safe points (between form evaluations)
    /// where no in-flight allocations exist.
    /// Skips collection if child threads are active to avoid concurrent GC access.
    pub fn tryAutoCollect(self: *Self) void {
        // Check if any child threads are active (gc_lock counter > 0).
        // If so, skip collection to avoid concurrent access.
        if (self.gc_lock.load(.acquire) > 0) return;

        const need_collect = self.auto_gc_pending or self.manual_sweep_pending;
        if (need_collect) {
            if (self.scan_fn) |fn_ptr| {
                self.auto_gc_pending = false;
                self.manual_sweep_pending = false;
                self.collect(fn_ptr);
            }
        }
    }

    /// Handle only deferred manual sweeps (from zig.core/gc-sweep).
    /// Does NOT trigger auto-GC collections. This is useful for file
    /// execution where auto-GC is unnecessary overhead (OS reclaims
    /// all memory on exit), but manual sweeps still need to run.
    pub fn tryDeferredSweep(self: *Self) void {
        if (self.gc_lock.load(.acquire) > 0) return;

        if (self.manual_sweep_pending) {
            if (self.scan_fn) |fn_ptr| {
                self.manual_sweep_pending = false;
                self.collect(fn_ptr);
            }
        }
    }

    /// Lock the GC to prevent collection while a child thread runs.
    /// Increments the lock counter — supports nested threads (e.g., nested futures).
    pub fn threadStart(self: *Self) void {
        // Increment active thread count so main thread knows a thread is running.
        _ = self.active_thread_count.fetchAdd(1, .monotonic);
        // Increment the GC lock counter. This prevents GC from collecting
        // while any child thread is active. Supports nesting (multiple threads).
        _ = self.gc_lock.fetchAdd(1, .acq_rel);
    }

    /// Unlock the GC, allowing collection to proceed when all threads are done.
    pub fn threadDone(self: *Self) void {
        // Decrement the GC lock counter. When it reaches 0, GC can collect.
        _ = self.gc_lock.fetchSub(1, .release);
        // Decrement active thread count — main thread waits for this to reach 0.
        _ = self.active_thread_count.fetchSub(1, .release);
    }

    /// Wait for all detached threads to finish their cleanup.
    /// Spins with brief sleeps until active_thread_count reaches 0.
    /// Used during shutdown to prevent use-after-free of GC structures.
    pub fn waitForThreads(self: *Self) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (self.active_thread_count.load(.acquire) > 0) {
            const sleep_duration = std.Io.Duration.fromMilliseconds(1);
            std.Io.sleep(io, sleep_duration, std.Io.Clock.awake) catch {};
        }
    }

    /// Statistics snapshot.
    pub const Stats = struct {
        alloc_count: usize = 0,
        free_count: usize = 0,
        gc_count: usize = 0,
        block_count: usize = 0,
        root_count: usize = 0,
        permanent_root_count: usize = 0,
        total_allocated: usize = 0,
        current_allocated: usize = 0,
        peak_allocated: usize = 0,
        swept_count: usize = 0,
        swept_bytes: usize = 0,
    };

    pub fn stats(self: *const Self) Stats {
        return .{
            .alloc_count = self.alloc_count,
            .free_count = self.free_count,
            .gc_count = self.gc_count,
            .block_count = self.block_count,
            .root_count = self.roots.items.len,
            .permanent_root_count = self.permanent_roots.items.len,
            .total_allocated = self.total_allocated,
            .current_allocated = self.current_allocated,
            .peak_allocated = self.peak_allocated,
            .swept_count = self.swept_count,
            .swept_bytes = self.swept_bytes,
        };
    }

    // ---- Internal logging helper ----

    fn log(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.verbose) return;
        std.debug.print(fmt, args);
    }

    // ---- Allocator vtable implementations ----

    fn allocVTable(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const ptr = self.alloc(len, alignment) orelse return null;
        return @as([*]u8, @ptrCast(ptr));
    }

    fn resizeVTable(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false; // GC does not support in-place resize
    }

    fn remapVTable(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null; // GC does not support remap
    }

    fn freeVTable(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
        // No-op: GC handles all cleanup during sweep phase.
        // Individual free() calls through the allocator interface are ignored.
        // Use gc.free(ptr) for explicit manual cleanup before GC collect.
    }
};

/// Check if GC sweeping is enabled via CLJVM_GC_SWEEP env var.
/// Called exactly once at startup. Returns true (sweep enabled) by default.
/// Set CLJVM_GC_SWEEP=0 or CLJVM_GC_SWEEP=false to disable sweeping.
/// Disabling sweep is useful for debugging memory issues — unreachable
/// objects accumulate instead of being freed, making it easier to
/// identify what is (or isn't) being reached by the mark phase.
pub fn isGcSweepEnabled(environ: std.process.Environ) bool {
    var map = std.process.Environ.createMap(environ, std.heap.page_allocator) catch return true;
    defer map.deinit();
    const val = map.get("CLJVM_GC_SWEEP") orelse return true; // default: enabled
    if (val.len == 0) return true;
    if (std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false")) return false;
    return true;
}

// ============================================================
// Test object type and scan function (for standalone testing)
// ============================================================

/// A simple test object with pointers to other test objects.
pub const TestNode = struct {
    id: i32,
    next: ?*TestNode = null,
    child: ?*TestNode = null,
};

/// Scan function for TestNode objects.
pub fn testNodeScanFn(obj: *anyopaque, ctx: *ScanContext) void {
    const node: *TestNode = @ptrCast(@alignCast(obj));
    if (node.next) |n| ctx.gc.markRecursive(n, ctx);
    if (node.child) |c| ctx.gc.markRecursive(c, ctx);
}

// Helper: allocate a TestNode through the GC
fn allocNode(gc: *GC, id: i32) *TestNode {
    const ptr = gc.alloc(@sizeOf(TestNode), Alignment.of(TestNode)) orelse @panic("[GC TEST] alloc failed");
    const node: *TestNode = @alignCast(@ptrCast(ptr));
    node.* = .{ .id = id };
    return node;
}

// ============================================================
// Unit Tests — standalone, no Clojure code involved
// ============================================================

test "gc::init and deinit" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const s = gc.stats();
    try std.testing.expect(s.alloc_count == 0);
    try std.testing.expect(s.block_count == 0);
    try std.testing.expect(s.current_allocated == 0);
    try std.testing.expect(s.peak_allocated == 0);
}

test "gc::alloc and free" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const node = allocNode(&gc, 42);
    try std.testing.expect(node.id == 42);

    const s1 = gc.stats();
    try std.testing.expect(s1.alloc_count == 1);
    try std.testing.expect(s1.block_count == 1);
    try std.testing.expect(s1.current_allocated == @sizeOf(TestNode));

    _ = gc.free(node);

    const s2 = gc.stats();
    try std.testing.expect(s2.free_count == 1);
    try std.testing.expect(s2.block_count == 0);
    try std.testing.expect(s2.current_allocated == 0);
}

test "gc::alloc multiple objects" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    const c = allocNode(&gc, 3);

    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);
    try std.testing.expect(c.id == 3);

    const s = gc.stats();
    try std.testing.expect(s.block_count == 3);
    try std.testing.expect(s.alloc_count == 3);

    _ = gc.free(a);
    _ = gc.free(b);
    _ = gc.free(c);

    try std.testing.expect(gc.stats().block_count == 0);
}

test "gc::collect: reachable chain survives" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    // Chain: A -> B -> C
    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    const c = allocNode(&gc, 3);
    a.next = b;
    b.next = c;

    gc.addRoot(a);
    gc.collect(testNodeScanFn);

    // All should survive
    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);
    try std.testing.expect(c.id == 3);
    try std.testing.expect(gc.stats().block_count == 3);
}

test "gc::collect: unreachable objects swept" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    // Chain A -> B (reachable), D -> E (unreachable)
    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;

    const d = allocNode(&gc, 4);
    const e = allocNode(&gc, 5);
    d.next = e;

    gc.addRoot(a);
    // Three collects needed for 3-generation protection.
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    // Reachable objects survive
    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);

    const s = gc.stats();
    try std.testing.expect(s.block_count == 2);
    try std.testing.expect(s.swept_count > 0); // unreachable were freed
}

test "gc::collect: circular references handled" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    // Cycle: A <-> B
    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;
    b.next = a;

    gc.addRoot(a);
    gc.collect(testNodeScanFn);

    // Both survive (cycle is reachable from root A)
    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);
    try std.testing.expect(gc.stats().block_count == 2);
}

test "gc::collect: no roots sweeps everything" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;

    // No roots registered
    // Three collects needed for 3-generation protection.
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    const s = gc.stats();
    try std.testing.expect(s.block_count == 0);
    try std.testing.expect(s.swept_count > 0);
}

test "gc::collect: sweep disabled preserves everything" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;

    // No roots, but sweep disabled
    gc.setSweepEnabled(false);
    gc.collect(testNodeScanFn);

    // Nothing freed
    try std.testing.expect(gc.stats().block_count == 2);
    try std.testing.expect(gc.stats().swept_count == 0);
}

test "gc::collect: shared children from multiple roots" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    // A -> C, B -> C  (C shared)
    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    const c = allocNode(&gc, 3);
    a.child = c;
    b.child = c;

    gc.addRoot(a);
    gc.addRoot(b);
    gc.collect(testNodeScanFn);

    // All survive
    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);
    try std.testing.expect(c.id == 3);
    try std.testing.expect(gc.stats().block_count == 3);
}

test "gc::collect: tree structure" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    //       A
    //      / \
    //     B   C
    //    / \
    //   D   E
    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    const c = allocNode(&gc, 3);
    const d = allocNode(&gc, 4);
    const e = allocNode(&gc, 5);
    _ = allocNode(&gc, 6); // orphan

    a.next = b;
    a.child = c;
    b.next = d;
    b.child = e;

    gc.addRoot(a);
    // Three collects needed for 3-generation protection.
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    // A, B, C, D, E survive; orphan is swept
    try std.testing.expect(gc.stats().block_count == 5);
    try std.testing.expect(gc.stats().swept_count > 0);
}

test "gc::removeRoot then collect" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;

    gc.addRoot(a);
    gc.removeRoot(a);

    // Three collects needed for 3-generation protection.
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    // No roots — all swept
    try std.testing.expect(gc.stats().block_count == 0);
}

test "gc::manual free before collect" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;

    gc.addRoot(a);
    _ = gc.free(b); // manually free B before GC

    gc.collect(testNodeScanFn);

    // A survives, B already freed
    try std.testing.expect(a.id == 1);
    try std.testing.expect(gc.stats().block_count == 1);
}

test "gc::empty collect (no allocations)" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    gc.collect(testNodeScanFn);

    try std.testing.expect(gc.stats().gc_count == 1);
    try std.testing.expect(gc.stats().block_count == 0);
}

test "gc::deep chain (100 nodes)" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    var first: ?*TestNode = null;
    var prev: ?*TestNode = null;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const node = allocNode(&gc, @as(i32, @intCast(i)));
        if (prev) |p| p.next = node;
        if (first == null) first = node;
        prev = node;
    }

    gc.addRoot(first.?);
    gc.collect(testNodeScanFn);

    // All 100 nodes survive
    try std.testing.expect(gc.stats().block_count == 100);
}

test "gc::stats accuracy" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    _ = allocNode(&gc, 3); // orphan
    a.next = b;

    gc.addRoot(a);
    // Three collects needed for 3-generation protection.
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    const s = gc.stats();
    try std.testing.expect(s.alloc_count == 3);
    try std.testing.expect(s.free_count == 0); // no manual frees
    try std.testing.expect(s.gc_count == 3);
    try std.testing.expect(s.block_count == 2); // a, b survive
    try std.testing.expect(s.swept_count > 0); // orphan swept
    try std.testing.expect(s.swept_bytes > 0);
    try std.testing.expect(s.current_allocated > 0);
    try std.testing.expect(s.peak_allocated >= s.current_allocated);
}

test "gc::multiple collect cycles" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;
    gc.addRoot(a);

    // First collect
    gc.collect(testNodeScanFn);
    try std.testing.expect(gc.stats().block_count == 2);

    // Allocate and free a node
    const c = allocNode(&gc, 3);
    _ = gc.free(c);

    // Second collect
    gc.collect(testNodeScanFn);
    try std.testing.expect(gc.stats().block_count == 2);
    try std.testing.expect(gc.stats().gc_count == 2);
}

test "gc::allocator interface: alloc and free" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const alloc = gc.allocator();

    const ptrs = try alloc.alloc(TestNode, 1);
    ptrs[0] = .{ .id = 99 };
    const ptr: *TestNode = &ptrs[0];

    gc.addRoot(ptr);
    gc.collect(testNodeScanFn);

    try std.testing.expect(ptr.id == 99);
    try std.testing.expect(gc.stats().block_count == 1);

    // alloc.free() is a no-op (GC handles cleanup during sweep).
    // Use gc.free() for explicit manual cleanup.
    _ = gc.free(ptr);
    try std.testing.expect(gc.stats().block_count == 0);
}

test "gc::allocator interface: ArrayListUnmanaged" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const alloc = gc.allocator();

    var list: std.ArrayListUnmanaged(i32) = .empty;
    defer list.deinit(alloc);

    try list.append(alloc, 10);
    try list.append(alloc, 20);
    try list.append(alloc, 30);

    // The list's internal buffer is GC-tracked
    try std.testing.expect(list.items.len == 3);
    try std.testing.expect(list.items[0] == 10);
}

test "gc::sweep toggle: disable then re-enable" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    _ = allocNode(&gc, 1);
    _ = allocNode(&gc, 2);

    // Disable sweep
    gc.setSweepEnabled(false);
    gc.collect(testNodeScanFn);
    try std.testing.expect(gc.stats().block_count == 2); // nothing swept

    // Re-enable sweep
    // Three collects total (1 disabled + 2 enabled) for 3-generation protection.
    gc.setSweepEnabled(true);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    try std.testing.expect(gc.stats().block_count == 0); // now swept
}

test "gc::free non-GC pointer is no-op" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    // Allocate with the wrapped allocator (not through GC)
    const regular_ptr = std.heap.page_allocator.alloc(u8, 16) catch unreachable;
    defer std.heap.page_allocator.free(regular_ptr);

    // Free through GC — should be a no-op
    const freed = gc.free(regular_ptr.ptr);
    try std.testing.expect(!freed);
}

test "gc::complex graph with cycles and orphans" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    // Graph:
    //   A -> B -> C -> B  (cycle B-C)
    //   |
    //   D -> E            (linear, reachable from A)
    //
    //   F -> G -> F       (unreachable cycle)
    //   H                  (unreachable single node)

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    const c = allocNode(&gc, 3);
    const d = allocNode(&gc, 4);
    const e = allocNode(&gc, 5);
    const f = allocNode(&gc, 6);
    const g = allocNode(&gc, 7);
    _ = allocNode(&gc, 8); // orphan H

    a.next = b;
    b.next = c;
    c.next = b; // cycle
    a.child = d;
    d.next = e;

    f.next = g;
    g.next = f; // unreachable cycle

    gc.addRoot(a);
    // Three collects needed for 3-generation protection.
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    // A, B, C, D, E survive; F, G, H swept
    const s = gc.stats();
    try std.testing.expect(s.block_count == 5);
    try std.testing.expect(s.swept_count > 0);
}

test "gc::deinit cleans up live allocations" {
    var gc = GC.init(std.heap.page_allocator);

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;
    gc.addRoot(a);

    // Don't free anything manually — deinit should clean up
    gc.deinit(); // should not crash or leak
}

test "gc::alloc with different alignments" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const align_vals = [_]u29{ 0, 1, 2, 3, 4 }; // log2: 1, 2, 4, 8, 16

    for (align_vals) |av| {
        const a: Alignment = @enumFromInt(av);
        const ptr = gc.alloc(64, a) orelse @panic("alloc failed");
        const addr: usize = @intFromPtr(ptr);
        const align_val: usize = @as(usize, 1) << @as(u6, @intCast(av));
        try std.testing.expect(addr % align_val == 0);
        _ = gc.free(ptr);
    }
}

test "gc::verbose mode produces output" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    gc.verbose = true;
    const a = allocNode(&gc, 1);
    gc.addRoot(a);
    gc.collect(testNodeScanFn);
    // If verbose mode crashes, the test will fail.
    // We can't easily capture stderr in a unit test, but at least we verify
    // that verbose mode doesn't crash.
    try std.testing.expect(gc.stats().block_count == 1);
}

test "gc::permanent root survives collect (no regular roots)" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;

    // Register A as permanent root (never collected)
    gc.addPermanentRoot(a);

    // No regular roots registered — only permanent roots
    gc.collect(testNodeScanFn);

    // A and B survive because A is a permanent root
    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);
    try std.testing.expect(gc.stats().block_count == 2);
    try std.testing.expect(gc.stats().permanent_root_count == 1);
}

test "gc::permanent root protects deep chain" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    // Chain: A -> B -> C -> D
    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    const c = allocNode(&gc, 3);
    const d = allocNode(&gc, 4);
    a.next = b;
    b.next = c;
    c.next = d;

    gc.addPermanentRoot(a);

    // Multiple collects — permanent root keeps entire chain alive
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);
    try std.testing.expect(c.id == 3);
    try std.testing.expect(d.id == 4);
    try std.testing.expect(gc.stats().block_count == 4);
}

test "gc::permanent root + regular root coexist" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const perm = allocNode(&gc, 10);
    const reg = allocNode(&gc, 20);
    _ = allocNode(&gc, 30); // orphan

    gc.addPermanentRoot(perm);
    gc.addRoot(reg);

    // Three collects for 3-generation protection (orphan gets swept)
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    try std.testing.expect(perm.id == 10);
    try std.testing.expect(reg.id == 20);
    // Orphan should be swept
    try std.testing.expect(gc.stats().block_count == 2);
}

test "gc::remove permanent root allows collection" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    gc.addPermanentRoot(a);

    // First collect — A survives as permanent root
    gc.collect(testNodeScanFn);
    try std.testing.expect(gc.stats().block_count == 1);

    // Remove permanent root
    gc.removePermanentRoot(a);
    try std.testing.expect(gc.stats().permanent_root_count == 0);

    // Three collects for 3-generation protection
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    // A should now be swept (no roots)
    try std.testing.expect(gc.stats().block_count == 0);
}

test "gc::permanent root duplicate add is no-op" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    gc.addPermanentRoot(a);
    gc.addPermanentRoot(a); // duplicate
    gc.addPermanentRoot(a); // duplicate

    try std.testing.expect(gc.stats().permanent_root_count == 1);
}

test "gc::permanent root remove non-existent is no-op" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    gc.addPermanentRoot(a);

    // Try to remove B which was never added
    gc.removePermanentRoot(b);
    try std.testing.expect(gc.stats().permanent_root_count == 1);

    // Clean up
    gc.removePermanentRoot(a);
    try std.testing.expect(gc.stats().permanent_root_count == 0);
}

test "gc::permanent root with tree structure" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    //       A (permanent)
    //      / \
    //     B   C
    //    / \
    //   D   E
    //
    //   F -> G  (unreachable cycle)
    //   H        (orphan)
    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    const c = allocNode(&gc, 3);
    const d = allocNode(&gc, 4);
    const e = allocNode(&gc, 5);
    const f = allocNode(&gc, 6);
    const g = allocNode(&gc, 7);
    _ = allocNode(&gc, 8); // orphan H

    a.next = b;
    a.child = c;
    b.next = d;
    b.child = e;
    f.next = g;
    g.next = f; // unreachable cycle

    gc.addPermanentRoot(a);

    // Three collects for 3-generation protection
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);
    gc.collect(testNodeScanFn);

    // A-E survive (reachable from permanent root A)
    // F, G, H swept (unreachable)
    try std.testing.expect(gc.stats().block_count == 5);
    try std.testing.expect(gc.stats().permanent_root_count == 1);
}
