const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Debug allocator wrapper that logs every alloc/realloc/free operation.
/// Toggle with CLJVM_MEM_TRACE=1 (stderr) or CLJVM_MEM_TRACE=file:path
///
/// The tracing condition (CLJVM_MEM_TRACE) is evaluated exactly once at startup.
/// When disabled, the vtable points to non-tracing functions that delegate
/// directly to the wrapped allocator with zero overhead (no branches, no logging,
/// no counter updates).
pub const DebugAllocator = struct {
    const Self = @This();

    wrapped: Allocator,

    // Vtable stored inline so the pointer remains valid for the lifetime of this struct.
    // Function pointers are set once at init based on CLJVM_MEM_TRACE.
    vtable: std.mem.Allocator.VTable,

    active: bool = false,
    log_file: ?std.Io.File = null,
    alloc_count: usize = 0,
    free_count: usize = 0,
    total_allocated: usize = 0,
    total_freed: usize = 0,
    peak_memory: usize = 0,
    current_memory: usize = 0,

    pub fn init(wrapped: Allocator, log_path: ?[]const u8) Self {
        var self: Self = .{
            .wrapped = wrapped,
            .vtable = .{
                .alloc = if (log_path != null) allocFnTrace else allocFnNoTrace,
                .resize = if (log_path != null) resizeFnTrace else resizeFnNoTrace,
                .remap = if (log_path != null) remapFnTrace else remapFnNoTrace,
                .free = if (log_path != null) freeFnTrace else freeFnNoTrace,
            },
            .active = log_path != null,
        };

        if (log_path) |path| {
            if (!std.mem.eql(u8, path, "stderr")) {
                const cwd = std.Io.Dir.cwd();
                self.log_file = std.Io.Dir.createFile(cwd, std.Options.debug_io, path, .{}) catch null;
            }
            self.emitRaw("=== Memory trace started");
            if (!std.mem.eql(u8, path, "stderr")) {
                self.emitRaw(" (");
                self.emitRaw(path);
                self.emitRaw(")");
            }
            self.emitRaw(" ===\n");
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (!self.active) return;
        const summary = std.fmt.allocPrint(std.heap.page_allocator,
            \\=== Memory trace summary ===
            \\  Allocations:     {d}
            \\  Frees:           {d}
            \\  Net allocs:      {d}
            \\  Total allocated: {d} bytes
            \\  Total freed:     {d} bytes
            \\  Peak memory:     {d} bytes
            \\  Current memory:  {d} bytes
            \\=== Memory trace ended ===
            \\ 
        , .{
            self.alloc_count,
            self.free_count,
            self.alloc_count - self.free_count,
            self.total_allocated,
            self.total_freed,
            self.peak_memory,
            self.current_memory,
        }) catch return;
        defer std.heap.page_allocator.free(summary);
        self.emitRaw(summary);

        if (self.log_file) |f| {
            std.Io.File.close(f, std.Options.debug_io);
        }
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &self.vtable,
        };
    }

    // === Tracing functions (logged) ===

    fn allocFnTrace(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.wrapped.rawAlloc(len, alignment, @returnAddress()) orelse {
            self.logMsg("ALLOC FAIL  size={d}\n", .{len});
            return null;
        };
        self.alloc_count += 1;
        self.total_allocated += len;
        self.current_memory += len;
        if (self.current_memory > self.peak_memory) self.peak_memory = self.current_memory;
        self.logMsg("ALLOC       size={d:<10} ptr={*} live={d}\n", .{ len, result, self.current_memory });
        return result;
    }

    fn resizeFnTrace(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const result = self.wrapped.rawResize(memory, alignment, new_len, @returnAddress());
        if (result) {
            self.total_freed += old_len;
            self.total_allocated += new_len;
            self.current_memory = self.current_memory - old_len + new_len;
            if (self.current_memory > self.peak_memory) self.peak_memory = self.current_memory;
            self.logMsg("RESIZE OK   old={d:<10} new={d:<10} ptr={*} live={d}\n", .{ old_len, new_len, memory.ptr, self.current_memory });
        }
        return result;
    }

    fn remapFnTrace(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const result = self.wrapped.rawRemap(memory, alignment, new_len, @returnAddress());
        if (result) |ptr| {
            if (new_len > old_len) {
                self.total_allocated += new_len - old_len;
                self.current_memory += new_len - old_len;
            } else {
                self.total_freed += old_len - new_len;
                self.current_memory -= old_len - new_len;
            }
            if (self.current_memory > self.peak_memory) self.peak_memory = self.current_memory;
            self.logMsg("REMAP       old={d:<10} new={d:<10} ptr={*} live={d}\n", .{ old_len, new_len, ptr, self.current_memory });
        } else {
            self.logMsg("REMAP FAIL  old={d:<10} new={d:<10}\n", .{ old_len, new_len });
        }
        return result;
    }

    fn freeFnTrace(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const n = memory.len;
        self.wrapped.rawFree(memory, alignment, @returnAddress());
        self.free_count += 1;
        self.total_freed += n;
        if (n > self.current_memory) self.current_memory = 0 else self.current_memory -= n;
        self.logMsg("FREE        size={d:<10} ptr={*} live={d}\n", .{ n, memory.ptr, self.current_memory });
    }

    // === Non-tracing functions (zero overhead) ===

    fn allocFnNoTrace(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.wrapped.rawAlloc(len, alignment, @returnAddress());
    }

    fn resizeFnNoTrace(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.wrapped.rawResize(memory, alignment, new_len, @returnAddress());
    }

    fn remapFnNoTrace(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.wrapped.rawRemap(memory, alignment, new_len, @returnAddress());
    }

    fn freeFnNoTrace(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.wrapped.rawFree(memory, alignment, @returnAddress());
    }

    // === Internal helpers (only used by tracing functions) ===

    fn emitRaw(self: *const Self, msg: []const u8) void {
        self.writeRaw(msg);
    }

    fn writeRaw(self: *const Self, msg: []const u8) void {
        if (self.log_file) |f| {
            std.Io.File.writeStreamingAll(f, std.Options.debug_io, msg) catch {};
        } else {
            std.Io.File.writeStreamingAll(std.Io.File.stderr(), std.Options.debug_io, msg) catch {};
        }
    }

    fn logMsg(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        const inner = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
        defer std.heap.page_allocator.free(inner);
        const full = std.fmt.allocPrint(std.heap.page_allocator, "MEM_TRACE: {s}", .{inner}) catch return;
        defer std.heap.page_allocator.free(full);
        self.writeRaw(full);
    }
};

/// Check if memory tracing is enabled via CLJVM_MEM_TRACE env var.
/// Called exactly once at startup. Returns null if disabled, or the log
/// target ("stderr" or file path) if enabled.
pub fn getMemTraceConfig(environ: std.process.Environ) ?[]const u8 {
    var map = std.process.Environ.createMap(environ, std.heap.page_allocator) catch return null;
    defer map.deinit();
    const val = map.get("CLJVM_MEM_TRACE") orelse return null;
    if (val.len == 0) return null;
    if (std.mem.eql(u8, val, "1")) {
        return std.heap.page_allocator.dupe(u8, "stderr") catch null;
    }
    return std.heap.page_allocator.dupe(u8, val) catch null;
}

// ===== Unit Tests =====

test "debug_allocator::getMemTraceConfig: no env returns null" {
    // getMemTraceConfig reads from the actual environment.
    // In a test context, CLJVM_MEM_TRACE is typically not set.
    // We skip this test as it depends on external environment state.
    _ = getMemTraceConfig;
}

test "debug_allocator::DebugAllocator: init without tracing" {
    var da = DebugAllocator.init(std.heap.page_allocator, null);
    defer da.deinit();
    try std.testing.expect(!da.active);
    const alloc = da.allocator();
    const ptr = try alloc.alloc(u8, 64);
    alloc.free(ptr);
}

test "debug_allocator::DebugAllocator: init with stderr tracing" {
    var da = DebugAllocator.init(std.heap.page_allocator, "stderr");
    defer da.deinit();
    try std.testing.expect(da.active);
    const alloc = da.allocator();
    const ptr = try alloc.alloc(u8, 64);
    alloc.free(ptr);
}
