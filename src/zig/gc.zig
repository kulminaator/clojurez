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
    queue_items = 4, // array of Value objects (queue items)
    env_entries = 5, // array of StringArrayHashMap Entry{ key: []u8, value: Value }
    lazy_seq_thunk = 6, // LazySeqThunk { params: list.List, body: list.List, env: Env }
    atom_data = 7,  // AtomData { value: Value, ref_count: usize }
    fn_data = 8,    // FnData { arities: ArrayListUnmanaged(Arity), env: Env }
};

const Header = struct {
    magic: u32 = MAGIC,
    marked: bool = false,
    obj_type: GCObjectType = .unknown,
    size: usize = 0,
    offset: usize = 0, // bytes from header to data area (header_size + padding)
    next: ?*Header = null,
    prev: ?*Header = null,
};

const HEADER_SIZE: usize = @sizeOf(Header);

// ============================================================
// ScanContext — passed to scan functions during the mark phase
// ============================================================

pub const ScanFn = *const fn (obj: *anyopaque, ctx: *ScanContext) void;

/// Callback that returns dynamic roots at collect time.
/// Called during the mark phase to get current root pointers.
pub const RootFn = *const fn (gc: *GC) void;

pub const ScanContext = struct {
    gc: *GC,
    scan_fn: ScanFn,
};

// ============================================================
// GC — the garbage collector
// ============================================================

pub const GC = struct {
    const Self = @This();

    wrapped: Allocator,

    // Doubly-linked list of all allocated blocks
    blocks: ?*Header = null,
    block_count: usize = 0,

    // Root pointers (always considered reachable)
    roots: std.ArrayListUnmanaged(*anyopaque) = .empty,
    // Optional callback that registers dynamic roots at collect time.
    // Useful for roots that change address (e.g., HashMap entries after resize).
    root_fn: ?RootFn = null,

    // Debug flags
    sweep_enabled: bool = true,
    verbose: bool = false,

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
        self.log("[GC] DEINIT: blocks={d} live={d}\n", .{ self.block_count, self.current_allocated });

        // Free all remaining blocks
        var block = self.blocks;
        while (block) |b| {
            const next = b.next;
            const total = b.offset + b.size;
            const block_start = @as([*]u8, @ptrCast(b));
            self.wrapped.free(block_start[0..total]);
            block = next;
        }
        self.blocks = null;
        self.block_count = 0;
        self.wrapped.free(self.roots.items);
        self.roots = .empty;
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
            .next = self.blocks,
            .prev = null,
        };

        if (self.blocks) |first| first.prev = header;
        self.blocks = header;
        self.block_count += 1;

        self.alloc_count += 1;
        self.total_allocated += actual_size;
        self.current_allocated += actual_size;
        if (self.current_allocated > self.peak_allocated) self.peak_allocated = self.current_allocated;

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

        // Remove from linked list
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
        self.wrapped.free(block_start[0..total]);

        self.free_count += 1;
        if (block_size > self.current_allocated) {
            self.current_allocated = 0;
        } else {
            self.current_allocated -= block_size;
        }

        self.log("[GC] FREE  size={d} ptr={*} blocks={d} live={d}\n",
            .{ block_size, real_ptr, self.block_count, self.current_allocated });

        return true;
    }

    /// Walk the block list to find the header for a data pointer.
    pub fn findHeader(self: *Self, dataPtr: *anyopaque) ?*Header {
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

    /// Full mark-and-sweep collection cycle.
    pub fn collect(self: *Self, scan_fn: ScanFn) void {
        self.log("[GC] === COLLECT START blocks={d} roots={d} ===\n",
            .{ self.block_count, self.roots.items.len });

        // Phase 1: Clear all marks
        var block = self.blocks;
        while (block) |b| {
            b.marked = false;
            block = b.next;
        }

        // Phase 2: Mark from static roots
        var ctx = ScanContext{ .gc = self, .scan_fn = scan_fn };
        for (self.roots.items) |root| {
            self.markRecursive(root, &ctx);
        }

        // Phase 3: Call root callback for dynamic roots (marks directly)
        if (self.root_fn) |fn_ptr| {
            fn_ptr(self);
        }

        // Phase 4: Sweep unmarked blocks
        self.sweep();

        self.gc_count += 1;
        self.log("[GC] === COLLECT END blocks={d} live={d} ===\n",
            .{ self.block_count, self.current_allocated });
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

        var block = self.blocks;
        var swept: usize = 0;
        var swept_bytes: usize = 0;

        while (block) |b| {
            const next = b.next;
            if (!b.marked) {
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
                self.wrapped.free(block_start[0..total]);

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

    /// Statistics snapshot.
    pub const Stats = struct {
        alloc_count: usize = 0,
        free_count: usize = 0,
        gc_count: usize = 0,
        block_count: usize = 0,
        root_count: usize = 0,
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
    gc.collect(testNodeScanFn);

    try std.testing.expect(a.id == 1);
    try std.testing.expect(b.id == 2);

    const s = gc.stats();
    try std.testing.expect(s.block_count == 2);
    try std.testing.expect(s.swept_count == 2);
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
    gc.collect(testNodeScanFn);

    const s = gc.stats();
    try std.testing.expect(s.block_count == 0);
    try std.testing.expect(s.swept_count == 2);
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
    gc.collect(testNodeScanFn);

    // A, B, C, D, E survive; orphan is swept
    try std.testing.expect(gc.stats().block_count == 5);
    try std.testing.expect(gc.stats().swept_count == 1);
}

test "gc::removeRoot then collect" {
    var gc = GC.init(std.heap.page_allocator);
    defer gc.deinit();

    const a = allocNode(&gc, 1);
    const b = allocNode(&gc, 2);
    a.next = b;

    gc.addRoot(a);
    gc.removeRoot(a);

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
    gc.collect(testNodeScanFn);

    const s = gc.stats();
    try std.testing.expect(s.alloc_count == 3);
    try std.testing.expect(s.free_count == 0); // no manual frees
    try std.testing.expect(s.gc_count == 1);
    try std.testing.expect(s.block_count == 2); // a, b survive
    try std.testing.expect(s.swept_count == 1); // orphan swept
    try std.testing.expect(s.swept_bytes == @sizeOf(TestNode));
    try std.testing.expect(s.current_allocated == 2 * @sizeOf(TestNode));
    try std.testing.expect(s.peak_allocated == 3 * @sizeOf(TestNode));
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
    gc.setSweepEnabled(true);
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
    gc.collect(testNodeScanFn);

    // A, B, C, D, E survive; F, G, H swept
    const s = gc.stats();
    try std.testing.expect(s.block_count == 5);
    try std.testing.expect(s.swept_count == 3);
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
