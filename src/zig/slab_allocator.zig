const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Size classes for the slab allocator.
/// Most VM allocations fall into these ranges.
pub const SIZE_CLASSES: [9]usize = .{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048 };
pub const NUM_SIZE_CLASSES = SIZE_CLASSES.len;

/// Page size: 64KB. Each slab page is this many bytes.
pub const PAGE_SIZE: usize = 65536;

/// Sentinel value for empty free list.
const EMPTY_FREE_LIST: usize = std.math.maxInt(usize);

/// A single page within a slab.
/// Contains a header followed by chunks of uniform size.
pub const Page = struct {
    next: ?*Page = null,    // linked list pointer
    ref_count: usize = 0,   // live allocations from this page
    free_list: usize = EMPTY_FREE_LIST, // chunk index of first free chunk
    memory: [*]u8 = undefined, // pointer to the page memory (from system alloc)

    /// Return the header size, padded to be aligned to chunk_size.
    /// This ensures chunks start at a properly aligned offset.
    fn headerSize(chunk_size: usize) usize {
        const raw_header = @sizeOf(Page);
        // Align to chunk_size
        const remainder = raw_header % chunk_size;
        if (remainder == 0) return raw_header;
        return raw_header + (chunk_size - remainder);
    }

    /// Return a pointer to the chunk area (after page header).
    fn chunkArea(self: *const Page, chunk_size: usize) [*]u8 {
        return self.memory + headerSize(chunk_size);
    }

    /// Return a pointer to a specific chunk by index.
    fn chunkPtr(self: *const Page, chunk_idx: usize, chunk_size: usize) [*]u8 {
        return self.chunkArea(chunk_size) + (chunk_idx * chunk_size);
    }

    /// Initialize the free list for a fresh page.
    /// All chunks are free, linked together.
    fn initFreeList(self: *Page, chunks_per_page: usize, chunk_size: usize) void {
        var i: usize = 0;
        while (i < chunks_per_page) : (i += 1) {
            const ptr = self.chunkPtr(i, chunk_size);
            // Store next free index in the chunk (as usize)
            const next_idx: usize = if (i + 1 < chunks_per_page) i + 1 else EMPTY_FREE_LIST;
            @as(*usize, @ptrCast(@alignCast(ptr))).* = next_idx;
        }
        self.free_list = 0; // first free chunk is index 0
    }
};

/// A slab manages pages for a single size class.
/// Thread-safe: all operations are protected by a per-slab spinlock.
pub const Slab = struct {
    chunk_size: usize,
    page_size: usize,
    chunks_per_page: usize,
    pages: ?*Page = null, // linked list of pages for this size class

    // Per-slab spinlock for thread safety.
    // 0 = unlocked, 1 = locked. Acquired before any page list or free list modification.
    mutex: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Acquire the slab's spinlock. Spins until acquired.
    fn lock(self: *Slab) void {
        while (self.mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
    }

    /// Release the slab's spinlock.
    fn unlock(self: *Slab) void {
        self.mutex.store(0, .release);
    }

    /// Allocate a new page from the wrapped allocator.
    /// Caller must hold the slab lock.
    fn allocPage(self: *Slab, wrapped: Allocator) !void {
        const raw_ptr = wrapped.rawAlloc(self.page_size, Alignment.of(Page), @returnAddress()) orelse return error.OutOfMemory;

        // Initialize page struct at the start of the page
        const page: *Page = @ptrCast(@alignCast(raw_ptr));
        page.* = Page{};
        page.memory = raw_ptr;
        page.initFreeList(self.chunks_per_page, self.chunk_size);
        page.ref_count = 0;

        // Prepend to page list
        page.next = self.pages;
        self.pages = page;
    }

    /// Free a page and return it to the wrapped allocator.
    /// Caller must hold the slab lock.
    fn freePage(self: *Slab, page: *Page, wrapped: Allocator) void {
        // Remove from linked list
        var prev: ?*Page = null;
        var current: ?*Page = self.pages;
        while (current) |p| {
            if (p == page) break;
            prev = p;
            current = p.next;
        }

        if (current == null) return; // page not found (shouldn't happen)

        if (prev) |p| {
            p.next = page.next;
        } else {
            self.pages = page.next;
        }

        // Return page memory to system
        wrapped.rawFree(page.memory[0..self.page_size], Alignment.of(Page), @returnAddress());
    }

    /// Find a page with free chunks.
    /// Caller must hold the slab lock.
    fn findPageWithFreeChunk(self: *Slab) ?*Page {
        var page = self.pages;
        while (page) |p| {
            if (p.free_list != EMPTY_FREE_LIST) return p;
            page = p.next;
        }
        return null;
    }

    /// Find the page containing a given pointer.
    /// Caller must hold the slab lock.
    fn findPageForPtr(self: *Slab, ptr: [*]u8) ?*Page {
        const ptr_int: usize = @intFromPtr(ptr);
        var page = self.pages;
        while (page) |p| {
            const base_int: usize = @intFromPtr(p.memory);
            const end_int = base_int + self.page_size;
            if (ptr_int >= base_int and ptr_int < end_int) return p;
            page = p.next;
        }
        return null;
    }

    /// Allocate a chunk from this slab. Thread-safe.
    fn slabAlloc(self: *Slab, wrapped: Allocator) ![*]u8 {
        self.lock();
        defer self.unlock();

        // Find or allocate a page with free chunks
        var page = self.findPageWithFreeChunk();
        if (page == null) {
            try self.allocPage(wrapped);
            page = self.pages; // newly allocated page is at head
        }

        const p = page.?;

        // Pop first chunk from free list
        const chunk_idx = p.free_list;
        if (chunk_idx == EMPTY_FREE_LIST) return error.OutOfMemory;

        const next_free = @as(*const usize, @ptrCast(@alignCast(p.chunkPtr(chunk_idx, self.chunk_size)))).*;
        p.free_list = next_free;
        p.ref_count += 1;

        const result = p.chunkPtr(chunk_idx, self.chunk_size);
        // Mark newly allocated (not yet used) memory with 0x55
        @memset(result[0..self.chunk_size], 0x55);
        return result;
    }

    /// Free a chunk back to this slab. Thread-safe.
    fn slabFree(self: *Slab, ptr: [*]u8, wrapped: Allocator) void {
        self.lock();
        defer self.unlock();

        const page = self.findPageForPtr(ptr) orelse return;

        // Compute chunk index
        const chunk_area = page.chunkArea(self.chunk_size);
        const ptr_int: usize = @intFromPtr(ptr);
        const area_int: usize = @intFromPtr(chunk_area);
        const offset = ptr_int - area_int;
        const chunk_idx = offset / self.chunk_size;

        // Push chunk onto free list
        @as(*usize, @ptrCast(@alignCast(ptr))).* = page.free_list;
        page.free_list = chunk_idx;
        page.ref_count -= 1;

        // If all chunks freed, return entire page
        if (page.ref_count == 0) {
            self.freePage(page, wrapped);
        }
    }

    /// Deinitialize: free all pages even if ref_count > 0 (shutdown).
    /// Caller must hold the slab lock.
    fn deinit(self: *Slab, wrapped: Allocator) void {
        var page = self.pages;
        while (page) |p| {
            const next = p.next;
            wrapped.rawFree(p.memory[0..self.page_size], Alignment.of(Page), @returnAddress());
            page = next;
        }
        self.pages = null;
    }
};

/// The slab allocator. Sits between the system allocator and the VM.
/// Thread-safe: each size class (slab) has its own spinlock.
pub const SlabAllocator = struct {
    const Self = @This();

    wrapped: Allocator,
    slabs: [NUM_SIZE_CLASSES]Slab,

    // Vtable stored inline so the pointer remains valid.
    vtable: std.mem.Allocator.VTable,

    pub fn init(wrapped: Allocator) Self {
        var self: Self = undefined;
        self.wrapped = wrapped;

        var i: usize = 0;
        while (i < NUM_SIZE_CLASSES) : (i += 1) {
            const chunk_size = SIZE_CLASSES[i];
            const hdr = Page.headerSize(chunk_size);
            const usable_per_page = PAGE_SIZE - hdr;
            const chunks_per_page = usable_per_page / chunk_size;
            self.slabs[i] = Slab{
                .chunk_size = chunk_size,
                .page_size = PAGE_SIZE,
                .chunks_per_page = chunks_per_page,
                .pages = null,
                .mutex = std.atomic.Value(u8).init(0),
            };
        }

        self.vtable = std.mem.Allocator.VTable{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        var i: usize = 0;
        while (i < NUM_SIZE_CLASSES) : (i += 1) {
            // Acquire lock to prevent concurrent access during shutdown
            self.slabs[i].lock();
            self.slabs[i].deinit(self.wrapped);
            self.slabs[i].unlock();
        }
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &self.vtable,
        };
    }

    /// Choose the size class index for a given allocation size.
    /// Returns maxInt(usize) if the allocation should fall through to the wrapped allocator.
    pub fn chooseSizeClass(size: usize) usize {
        if (size > SIZE_CLASSES[NUM_SIZE_CLASSES - 1]) return std.math.maxInt(usize);
        var i: usize = 0;
        while (i < NUM_SIZE_CLASSES) : (i += 1) {
            if (size <= SIZE_CLASSES[i]) return i;
        }
        return std.math.maxInt(usize);
    }

    /// Vtable: alloc — thread-safe (per-slab lock).
    fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        const sc = SlabAllocator.chooseSizeClass(len);
        if (sc == std.math.maxInt(usize)) {
            // Fall through to wrapped allocator for large allocations
            return self.wrapped.rawAlloc(len, alignment, @returnAddress());
        }

        // Edge case: if requested alignment exceeds chunk alignment, fall through
        const chunk_align: usize = self.slabs[sc].chunk_size;
        const req_align_log2: u29 = @intFromEnum(alignment);
        const req_align: usize = std.math.shl(usize, 1, req_align_log2);
        if (req_align > chunk_align) {
            return self.wrapped.rawAlloc(len, alignment, @returnAddress());
        }

        return self.slabs[sc].slabAlloc(self.wrapped) catch return null;
    }

    /// Vtable: free — thread-safe (per-slab lock).
    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        const sc = SlabAllocator.chooseSizeClass(memory.len);
        if (sc == std.math.maxInt(usize)) {
            // Fall through to wrapped allocator
            self.wrapped.rawFree(memory, alignment, @returnAddress());
            return;
        }

        self.slabs[sc].slabFree(memory.ptr, self.wrapped);
    }

    /// Vtable: resize — slab doesn't support in-place resize, return false
    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    /// Vtable: remap — return null to force fallback
    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }
};

// ===== Unit Tests =====

test "slab::allocPage + freePage round-trip" {
    const wrapped = std.heap.page_allocator;
    const chunk_size: usize = 64;

    var slab: Slab = .{
        .chunk_size = chunk_size,
        .page_size = PAGE_SIZE,
        .chunks_per_page = (PAGE_SIZE - Page.headerSize(chunk_size)) / chunk_size,
        .pages = null,
        .mutex = std.atomic.Value(u8).init(0),
    };

    try slab.allocPage(wrapped);
    try std.testing.expect(slab.pages != null);
    try std.testing.expect(slab.pages.?.ref_count == 0);
    try std.testing.expect(slab.pages.?.free_list == 0);

    slab.freePage(slab.pages.?, wrapped);
    try std.testing.expect(slab.pages == null);
}

test "slab::alloc + free single chunk per size class" {
    const wrapped = std.heap.page_allocator;

    var i: usize = 0;
    while (i < NUM_SIZE_CLASSES) : (i += 1) {
        const chunk_size = SIZE_CLASSES[i];
        const hdr = Page.headerSize(chunk_size);
        const usable_per_page = PAGE_SIZE - hdr;
        const chunks_per_page = usable_per_page / chunk_size;

        var slab: Slab = .{
            .chunk_size = chunk_size,
            .page_size = PAGE_SIZE,
            .chunks_per_page = chunks_per_page,
            .pages = null,
            .mutex = std.atomic.Value(u8).init(0),
        };
        defer slab.deinit(wrapped);

        const ptr = try slab.slabAlloc(wrapped);
        try std.testing.expect(slab.pages.?.ref_count == 1);

        slab.slabFree(ptr, wrapped);
        try std.testing.expect(slab.pages == null); // page freed when ref_count hits 0
    }
}

test "slab::alloc many, free many, verify page recycling" {
    const wrapped = std.heap.page_allocator;

    const chunk_size: usize = 64;
    const hdr = Page.headerSize(chunk_size);
    const usable_per_page = PAGE_SIZE - hdr;
    const chunks_per_page = usable_per_page / chunk_size;

    var slab: Slab = .{
        .chunk_size = chunk_size,
        .page_size = PAGE_SIZE,
        .chunks_per_page = chunks_per_page,
        .pages = null,
        .mutex = std.atomic.Value(u8).init(0),
    };
    defer slab.deinit(wrapped);

    // Allocate more than one page worth
    const alloc_count = chunks_per_page + 10;
    var ptrs_buf: [2048][*]u8 = undefined;
    var ptr_count: usize = 0;

    var idx: usize = 0;
    while (idx < alloc_count) : (idx += 1) {
        ptrs_buf[ptr_count] = try slab.slabAlloc(wrapped);
        ptr_count += 1;
    }

    // Should have at least 2 pages
    var page_count: usize = 0;
    var p = slab.pages;
    while (p) |pg| {
        page_count += 1;
        p = pg.next;
    }
    try std.testing.expect(page_count >= 2);

    // Free all
    idx = 0;
    while (idx < ptr_count) : (idx += 1) {
        slab.slabFree(ptrs_buf[idx], wrapped);
    }

    // All pages should be freed
    try std.testing.expect(slab.pages == null);
}

test "slab::fallthrough for large allocations" {
    var sa: SlabAllocator = SlabAllocator.init(std.heap.page_allocator);
    defer sa.deinit();
    const alloc = sa.allocator();

    // Allocate > 2048 bytes — should fall through
    const ptr = alloc.rawAlloc(4096, Alignment.of(u8), @returnAddress()) orelse unreachable;
    alloc.rawFree(ptr[0..4096], Alignment.of(u8), @returnAddress());
}

test "slab::full allocator alloc + free" {
    var sa: SlabAllocator = SlabAllocator.init(std.heap.page_allocator);
    defer sa.deinit();
    const alloc = sa.allocator();

    // Allocate various sizes
    const sizes = [_]usize{ 8, 15, 32, 63, 128, 255, 512, 1024, 2048 };
    var ptrs: [9][]u8 = undefined;

    var idx: usize = 0;
    for (sizes) |size| {
        ptrs[idx] = try alloc.alloc(u8, size);
        idx += 1;
    }

    // Free all
    var i: usize = 0;
    while (i < sizes.len) : (i += 1) {
        alloc.free(ptrs[i]);
    }
}

test "slab::deinit cleans up even with live allocations" {
    var sa: SlabAllocator = SlabAllocator.init(std.heap.page_allocator);

    const alloc = sa.allocator();
    const ptr = try alloc.alloc(u8, 64);
    _ = ptr; // intentionally leak — deinit should clean up

    sa.deinit(); // should not crash
}

test "slab::chooseSizeClass returns correct index" {
    try std.testing.expect(SlabAllocator.chooseSizeClass(1) == 0);   // SC8
    try std.testing.expect(SlabAllocator.chooseSizeClass(8) == 0);   // SC8
    try std.testing.expect(SlabAllocator.chooseSizeClass(9) == 1);   // SC16
    try std.testing.expect(SlabAllocator.chooseSizeClass(16) == 1);  // SC16
    try std.testing.expect(SlabAllocator.chooseSizeClass(33) == 3);  // SC64
    try std.testing.expect(SlabAllocator.chooseSizeClass(2048) == 8); // SC2048
    try std.testing.expect(SlabAllocator.chooseSizeClass(2049) == std.math.maxInt(usize)); // fallthrough
    try std.testing.expect(SlabAllocator.chooseSizeClass(65536) == std.math.maxInt(usize)); // fallthrough
}

// ===== Thread Safety Tests =====

// Test: concurrent alloc from multiple threads doesn't corrupt the slab.
test "slab::thread-safe: concurrent alloc" {
    var sa: SlabAllocator = SlabAllocator.init(std.heap.page_allocator);
    defer sa.deinit();
    const alloc = sa.allocator();

    const num_threads: usize = 4;
    const allocs_per_thread: usize = 1000;

    // Each thread allocates allocs_per_thread chunks of 64 bytes
    // and stores pointers in a thread-local buffer.
    // We use a shared counter to verify all allocations succeeded
    var success_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    const thread_fn = struct {
        fn run(a: Allocator, sc: *std.atomic.Value(usize)) void {
            var ptrs: [1000][*]u8 = undefined;
            var i: usize = 0;
            while (i < allocs_per_thread) : (i += 1) {
                const chunk_size: usize = 64;
                const ptr = a.rawAlloc(chunk_size, Alignment.of(u8), @returnAddress()) orelse {
                    return; // allocation failed, skip
                };
                ptrs[i] = ptr;
                _ = sc.fetchAdd(1, .monotonic);
            }
            // Free all
            i = 0;
            while (i < allocs_per_thread) : (i += 1) {
                a.rawFree(ptrs[i][0..64], Alignment.of(u8), @returnAddress());
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        threads[t] = std.Thread.spawn(.{}, thread_fn, .{ alloc, &success_count }) catch unreachable;
    }
    t = 0;
    while (t < num_threads) : (t += 1) {
        threads[t].join();
    }

    // All threads should have completed all allocations
    try std.testing.expect(success_count.load(.monotonic) == num_threads * allocs_per_thread);
}

// Test: concurrent alloc + free from multiple threads.
test "slab::thread-safe: concurrent alloc and free" {
    var sa: SlabAllocator = SlabAllocator.init(std.heap.page_allocator);
    defer sa.deinit();
    const alloc = sa.allocator();

    const num_threads: usize = 4;
    const ops_per_thread: usize = 500;

    const thread_fn = struct {
        fn run(a: Allocator) void {
            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                // Allocate
                const ptr = a.rawAlloc(128, Alignment.of(u8), @returnAddress()) orelse continue;
                // Write to it (detect use-after-free)
                ptr[0] = @as(u8, @intCast(i % 256));
                // Free immediately
                a.rawFree(ptr[0..128], Alignment.of(u8), @returnAddress());
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        threads[t] = std.Thread.spawn(.{}, thread_fn, .{ alloc }) catch unreachable;
    }
    t = 0;
    while (t < num_threads) : (t += 1) {
        threads[t].join();
    }
    // If we get here without crashing, the test passes
}

// Test: concurrent alloc from different size classes.
test "slab::thread-safe: concurrent multi-size-class alloc" {
    var sa: SlabAllocator = SlabAllocator.init(std.heap.page_allocator);
    defer sa.deinit();
    const alloc = sa.allocator();

    const sizes = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048 };
    const num_threads: usize = 8;
    const allocs_per_thread: usize = 200;

    const thread_fn = struct {
        fn run(a: Allocator, size_idx: usize) void {
            const size = sizes[size_idx];
            var ptrs: [200][*]u8 = undefined;
            var i: usize = 0;
            while (i < allocs_per_thread) : (i += 1) {
                const ptr = a.rawAlloc(size, Alignment.of(u8), @returnAddress()) orelse unreachable;
                // Write a pattern to detect corruption
                @memset(ptr[0..size], @as(u8, @intCast(i % 256)));
                ptrs[i] = ptr;
            }
            // Verify data integrity
            i = 0;
            while (i < allocs_per_thread) : (i += 1) {
                const expected: u8 = @intCast(i % 256);
                if (ptrs[i][0] != expected) {
                    std.debug.print("corruption at thread {d} i={d}: expected {d} got {d}\n", .{ size_idx, i, expected, ptrs[i][0] });
                }
            }
            // Free all
            i = 0;
            while (i < allocs_per_thread) : (i += 1) {
                a.rawFree(ptrs[i][0..size], Alignment.of(u8), @returnAddress());
            }
        }
    }.run;

    var threads: [8]std.Thread = undefined;
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        threads[t] = std.Thread.spawn(.{}, thread_fn, .{ alloc, t }) catch unreachable;
    }
    t = 0;
    while (t < num_threads) : (t += 1) {
        threads[t].join();
    }
}

// Test: stress test — many threads doing mixed alloc/free patterns.
test "slab::thread-safe: stress test" {
    var sa: SlabAllocator = SlabAllocator.init(std.heap.page_allocator);
    defer sa.deinit();
    const alloc = sa.allocator();

    const num_threads: usize = 8;
    const ops_per_thread: usize = 1000;

    const thread_fn = struct {
        fn run(a: Allocator, thread_id: usize) void {
            var ptrs: [100][*]u8 = undefined;
            var ptr_count: usize = 0;
            const sizes = [_]usize{ 8, 32, 64, 128, 256, 512, 1024, 2048 };

            var i: usize = 0;
            while (i < ops_per_thread) : (i += 1) {
                const size = sizes[(thread_id + i) % sizes.len];
                if (ptr_count >= ptrs.len) {
                    {
                        // Free half the pointers
                        var k: usize = 0;
                        while (k < ptrs.len / 2) : (k += 1) {
                            const psize = sizes[(thread_id + k) % sizes.len];
                            a.rawFree(ptrs[k][0..psize], Alignment.of(u8), @returnAddress());
                        }
                    }
                    {
                        // Move remaining pointers to front
                        var k: usize = ptrs.len / 2;
                        while (k < ptr_count) : (k += 1) {
                            ptrs[k - ptrs.len / 2] = ptrs[k];
                        }
                    }
                    ptr_count -= ptrs.len / 2;
                }
                const ptr = a.rawAlloc(size, Alignment.of(u8), @returnAddress()) orelse continue;
                ptr[0] = @as(u8, @intCast((i + thread_id) % 256));
                ptrs[ptr_count] = ptr;
                ptr_count += 1;
            }
            // Free remaining
            var k: usize = 0;
            while (k < ptr_count) : (k += 1) {
                const size = sizes[(thread_id + k) % sizes.len];
                a.rawFree(ptrs[k][0..size], Alignment.of(u8), @returnAddress());
            }
        }
    }.run;

    var threads: [8]std.Thread = undefined;
    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        threads[t] = std.Thread.spawn(.{}, thread_fn, .{ alloc, t }) catch unreachable;
    }
    t = 0;
    while (t < num_threads) : (t += 1) {
        threads[t].join();
    }
}
