// GC built-in functions for zig.core namespace
// Provides gc-sweep and gc-stats for manual GC control and monitoring.

const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const gc_mod = @import("../../gc.zig");
const gc_scan = @import("../../gc_scan.zig");
const eval_helpers = @import("eval_helpers.zig");
const eval_mod = @import("../../eval.zig");

const Allocator = std.mem.Allocator;

/// zig.core/gc-sweep — trigger a GC collection.
/// Takes no arguments. Returns nil.
/// When called from within Clojure evaluation, the mark phase runs immediately
/// but the sweep (actual freeing) is deferred to the next safe point to avoid
/// freeing in-flight values referenced only by stack-local pointers.
/// Thread-safe: skips collection if child threads are active.
pub fn core_gc_sweep(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;

    if (gc_mod.current_gc) |gc| {
        // Phase 8: Skip collection if child threads are active (gc_lock counter > 0).
        // This prevents scanning thread root frames while child threads
        // are still evaluating (their frames may be in inconsistent state).
        if (gc.gc_lock.load(.acquire) > 0) {
            // Child thread(s) active — defer sweep to safe point.
            gc.manual_sweep_pending = true;
            return vm.nilValue();
        }

        // Mark phase runs now; sweep is deferred to next safe point
        // to avoid freeing in-flight evaluation state.
        gc.setSweepEnabled(false);
        gc.collect(gc_scan.valueScanFn);
        gc.setSweepEnabled(true);
        gc.manual_sweep_pending = true;
    }
    return vm.nilValue();
}

/// zig.core/gc-stats — return a map of GC statistics.
/// Takes no arguments. Returns a map with keys:
///   :current-allocated  — bytes currently allocated by the GC
///   :peak-allocated     — highest bytes ever allocated (high-water mark)
///   :total-allocated    — cumulative bytes allocated since start
///   :total-freed        — cumulative bytes freed since start
///   :sweep-count        — number of GC sweeps performed
///   :alloc-count        — number of GC allocations performed
///   :block-count        — number of live GC blocks
pub fn core_gc_stats(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;

    const allocator = env.allocator;
    const s = if (gc_mod.current_gc) |gc| gc.stats() else gc_mod.GC.Stats{};

    // Build a map: {:current-allocated N, :peak-allocated N, ...}
    var entries: std.ArrayListUnmanaged(vm.MapEntry) = .empty;
    errdefer {
        for (entries.items) |*e| {
            vm.valueDeinit(&e.key, allocator);
            vm.valueDeinit(&e.value, allocator);
        }
        entries.deinit(allocator);
    }

    const fields = [_]struct { key: []const u8, val: usize }{
        .{ .key = "current-allocated", .val = s.current_allocated },
        .{ .key = "peak-allocated", .val = s.peak_allocated },
        .{ .key = "total-allocated", .val = s.total_allocated },
        .{ .key = "total-freed", .val = s.swept_bytes },
        .{ .key = "sweep-count", .val = s.gc_count },
        .{ .key = "alloc-count", .val = s.alloc_count },
        .{ .key = "block-count", .val = s.block_count },
    };

    for (fields) |f| {
        const key = try vm.keywordValue(allocator, f.key);
        const val = vm.intValue(@as(i64, @intCast(f.val)));
        try entries.append(allocator, .{ .key = key, .value = val });
    }

    return try vm.mapValue(allocator, entries);
}

/// zig.core/debug-alloc-enable — enable debug allocation tracking.
/// Takes no arguments. Returns nil.
pub fn core_debug_alloc_enable(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    gc_mod.debugAllocEnable();
    return vm.nilValue();
}

/// zig.core/debug-alloc-disable — disable debug allocation tracking.
/// Takes no arguments. Returns nil.
pub fn core_debug_alloc_disable(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    gc_mod.debugAllocDisable();
    return vm.nilValue();
}

/// zig.core/debug-alloc-top — print top allocation sources to stderr.
/// Takes no arguments. Returns nil.
pub fn core_debug_alloc_top(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    gc_mod.debugAllocPrintTop();
    return vm.nilValue();
}

/// zig.core/debug-alloc-capture — start capturing stack traces to /tmp/alloc_traces.log.
/// Takes one argument: max number of traces to capture.
pub fn core_debug_alloc_capture(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const limit_val = args.items[0];
    if (std.meta.activeTag(limit_val) != .integer) return error.TypeError;
    const limit: usize = @intCast(limit_val.integer);
    gc_mod.debugAllocStartCapture(limit);
    return vm.nilValue();
}

/// zig.core/debug-alloc-stop-capture — stop capturing stack traces.
pub fn core_debug_alloc_stop_capture(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    gc_mod.debugAllocStopCapture();
    return vm.nilValue();
}

/// zig.core/debug-type-snapshot — take a snapshot of GC blocks by type.
/// Takes no arguments. Returns an opaque snapshot handle (integer) that can
/// be passed to debug-type-snapshot-diff or debug-type-snapshot-print.
pub fn core_debug_type_snapshot(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    // Store snapshot in a GC-allocated struct and return its pointer as integer.
    const snapshot = gc_mod.debugTypeSnapshot();
    const ptr = try env.allocator.create(gc_mod.DebugTypeSnapshot);
    ptr.* = snapshot;
    return vm.intValue(@as(i64, @intCast(@intFromPtr(ptr))));
}

/// zig.core/debug-type-snapshot-diff — print the difference between two snapshots.
/// Takes two arguments: snapshot-before and snapshot-after (from debug-type-snapshot).
/// Returns nil.
pub fn core_debug_type_snapshot_diff(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const before_ptr: usize = @intCast(args.items[0].integer);
    const after_ptr: usize = @intCast(args.items[1].integer);
    const before: *gc_mod.DebugTypeSnapshot = @alignCast(@ptrCast(@as(*anyopaque, @ptrFromInt(before_ptr))));
    const after: *gc_mod.DebugTypeSnapshot = @alignCast(@ptrCast(@as(*anyopaque, @ptrFromInt(after_ptr))));
    gc_mod.debugTypeSnapshotDiff(before.*, after.*);
    return vm.nilValue();
}

/// zig.core/debug-type-snapshot-print — print a full type snapshot.
/// Takes two arguments: label (string) and snapshot handle.
/// Returns nil.
pub fn core_debug_type_snapshot_print(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const label = args.items[0].string;
    const snap_ptr: usize = @intCast(args.items[1].integer);
    const snapshot: *gc_mod.DebugTypeSnapshot = @alignCast(@ptrCast(@as(*anyopaque, @ptrFromInt(snap_ptr))));
    gc_mod.debugTypeSnapshotPrint(label, snapshot.*);
    return vm.nilValue();
}

/// Register GC functions in the zig.core namespace.
pub fn registerGCFunctions(env: *Env) anyerror!void {
    try env.put("gc-sweep", vm.builtinFnValue(core_gc_sweep));
    try env.put("gc-stats", vm.builtinFnValue(core_gc_stats));
    try env.put("debug-alloc-enable", vm.builtinFnValue(core_debug_alloc_enable));
    try env.put("debug-alloc-disable", vm.builtinFnValue(core_debug_alloc_disable));
    try env.put("debug-alloc-top", vm.builtinFnValue(core_debug_alloc_top));
    try env.put("debug-alloc-capture", vm.builtinFnValue(core_debug_alloc_capture));
    try env.put("debug-alloc-stop-capture", vm.builtinFnValue(core_debug_alloc_stop_capture));
    try env.put("debug-type-snapshot", vm.builtinFnValue(core_debug_type_snapshot));
    try env.put("debug-type-snapshot-diff", vm.builtinFnValue(core_debug_type_snapshot_diff));
    try env.put("debug-type-snapshot-print", vm.builtinFnValue(core_debug_type_snapshot_print));
    try env.put("debug-print-allocs-start", vm.builtinFnValue(core_debug_print_allocs_start));
    try env.put("debug-print-allocs-stop", vm.builtinFnValue(core_debug_print_allocs_stop));
    try env.put("debug-builtin-result-start", vm.builtinFnValue(core_debug_builtin_result_start));
    try env.put("debug-builtin-result-stop", vm.builtinFnValue(core_debug_builtin_result_stop));
    try env.put("debug-alloc-value-start", vm.builtinFnValue(core_debug_alloc_value_start));
    try env.put("debug-alloc-value-stop", vm.builtinFnValue(core_debug_alloc_value_stop));
}

/// zig.core/debug-print-allocs-start — start printing every allocation to stderr.
/// Takes one argument: max number of allocations to print.
pub fn core_debug_print_allocs_start(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const limit: usize = @intCast(args.items[0].integer);
    gc_mod.debugPrintAllocsStart(limit);
    return vm.nilValue();
}

/// zig.core/debug-print-allocs-stop — stop printing every allocation.
pub fn core_debug_print_allocs_stop(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    gc_mod.debugPrintAllocsStop();
    return vm.nilValue();
}

/// zig.core/debug-builtin-result-start — start printing every allocBuiltinResult call.
pub fn core_debug_builtin_result_start(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const limit: usize = @intCast(args.items[0].integer);
    eval_helpers.debugAllocBuiltinStart(limit);
    return vm.nilValue();
}

/// zig.core/debug-builtin-result-stop — stop printing every allocBuiltinResult call.
pub fn core_debug_builtin_result_stop(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    eval_helpers.debugAllocBuiltinStop();
    return vm.nilValue();
}

/// zig.core/debug-alloc-value-start — start printing every allocValue call in eval.zig.
pub fn core_debug_alloc_value_start(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const limit: usize = @intCast(args.items[0].integer);
    eval_mod.debugAllocValueStart(limit);
    return vm.nilValue();
}

/// zig.core/debug-alloc-value-stop — stop printing every allocValue call.
pub fn core_debug_alloc_value_stop(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;
    eval_mod.debugAllocValueStop();
    return vm.nilValue();
}
