// GC built-in functions for zig.core namespace
// Provides gc-sweep and gc-stats for manual GC control and monitoring.

const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const gc_mod = @import("../../gc.zig");
const gc_scan = @import("../../gc_scan.zig");

const Allocator = std.mem.Allocator;

/// zig.core/gc-sweep — trigger a GC collection.
/// Takes no arguments. Returns nil.
/// When called from within Clojure evaluation, the mark phase runs immediately
/// but the sweep (actual freeing) is deferred to the next safe point to avoid
/// freeing in-flight values referenced only by stack-local pointers.
pub fn core_gc_sweep(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;

    if (gc_mod.current_gc) |gc| {
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

/// Register GC functions in the zig.core namespace.
pub fn registerGCFunctions(env: *Env) anyerror!void {
    try env.put("gc-sweep", vm.builtinFnValue(core_gc_sweep));
    try env.put("gc-stats", vm.builtinFnValue(core_gc_stats));
}
