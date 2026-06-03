const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Debug allocator wrapper that logs every alloc/realloc/free operation.
/// Toggle with CLJVM_MEM_TRACE=1 (stderr) or CLJVM_MEM_TRACE=file:path
pub const DebugAllocator = struct {
    const Self = @This();

    wrapped: Allocator,
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
            .active = log_path != null,
        };

        if (log_path) |path| {
            if (!std.mem.eql(u8, path, "stderr")) {
                const cwd = std.Io.Dir.cwd();
                self.log_file = std.Io.Dir.openFile(cwd, std.Options.debug_io, path, .{ .mode = .write_only }) catch null;
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
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.wrapped.rawAlloc(len, alignment, @returnAddress()) orelse {
            if (self.active) logMsg(self, "ALLOC FAIL  size={d}\n", .{len});
            return null;
        };
        self.alloc_count += 1;
        self.total_allocated += len;
        self.current_memory += len;
        if (self.current_memory > self.peak_memory) self.peak_memory = self.current_memory;
        if (self.active) logMsg(self, "ALLOC       size={d:<10} ptr={*} live={d}\n", .{ len, result, self.current_memory });
        return result;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const result = self.wrapped.rawResize(memory, alignment, new_len, @returnAddress());
        if (result and self.active) {
            self.total_freed += old_len;
            self.total_allocated += new_len;
            self.current_memory = self.current_memory - old_len + new_len;
            if (self.current_memory > self.peak_memory) self.peak_memory = self.current_memory;
            logMsg(self, "RESIZE OK   old={d:<10} new={d:<10} ptr={*} live={d}\n", .{ old_len, new_len, memory.ptr, self.current_memory });
        }
        return result;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
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
            if (self.active) logMsg(self, "REMAP       old={d:<10} new={d:<10} ptr={*} live={d}\n", .{ old_len, new_len, ptr, self.current_memory });
        } else if (self.active) {
            logMsg(self, "REMAP FAIL  old={d:<10} new={d:<10}\n", .{ old_len, new_len });
        }
        return result;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const n = memory.len;
        self.wrapped.rawFree(memory, alignment, @returnAddress());
        self.free_count += 1;
        self.total_freed += n;
        if (n > self.current_memory) self.current_memory = 0 else self.current_memory -= n;
        if (self.active) logMsg(self, "FREE        size={d:<10} ptr={*} live={d}\n", .{ n, memory.ptr, self.current_memory });
    }

    fn emitRaw(self: *const Self, msg: []const u8) void {
        self.writeRaw(msg);
    }

    fn writeRaw(self: *const Self, msg: []const u8) void {
        if (self.log_file) |f| {
            var buf: [1]u8 = undefined;
            var w = f.writer(std.Options.debug_io, &buf);
            w.interface.writeAll(msg) catch {};
        } else {
            var buf: [1]u8 = undefined;
            var w = std.Io.File.stderr().writer(std.Options.debug_io, &buf);
            w.interface.writeAll(msg) catch {};
        }
    }
};

fn logMsg(self: *const DebugAllocator, comptime fmt: []const u8, args: anytype) void {
    if (!self.active) return;
    const inner = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(inner);
    const full = std.fmt.allocPrint(std.heap.page_allocator, "MEM_TRACE: {s}", .{inner}) catch return;
    defer std.heap.page_allocator.free(full);
    self.writeRaw(full);
}

/// Check if memory tracing is enabled via CLJVM_MEM_TRACE env var.
/// Returns null if disabled, or the log target ("stderr" or file path) if enabled.
pub fn getMemTraceConfig(environ: std.process.Environ) ?[]const u8 {
    const val = std.process.Environ.getPosix(environ, "CLJVM_MEM_TRACE") orelse return null;
    if (val.len == 0) return null;
    if (std.mem.eql(u8, val, "1")) {
        return std.heap.page_allocator.dupe(u8, "stderr") catch null;
    }
    return std.heap.page_allocator.dupe(u8, val) catch null;
}
