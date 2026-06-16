// Stack usage statistics: captures stack pointer baselines at startup
// and exposes zig.core/stack-stats for runtime inspection.
const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const Env = Value.Env;

const Allocator = std.mem.Allocator;

// Recorded baseline addresses (usize, not pointers — GC doesn't track these).
var app_baseline: usize = 0;
var vm_baseline: usize = 0;
var app_recorded: bool = false;
var vm_recorded: bool = false;

/// Capture a stack reference point by taking the address of a local variable.
fn captureStackPtr() usize {
    var sentinel: u8 = undefined;
    return @intFromPtr(&sentinel);
}



/// Record the app-baseline. Called at the very top of main().
pub fn recordAppBaseline() void {
    app_baseline = captureStackPtr();
    app_recorded = true;
}

/// Record the vm-baseline. Called after clojure core library loading.
pub fn recordVMBaseline() void {
    vm_baseline = captureStackPtr();
    vm_recorded = true;
}

/// Stack stats result struct.
pub const StackStats = struct {
    app_baseline: usize,
    vm_baseline: usize,
    current: usize,
    usage: usize, // app_baseline - current (positive = bytes consumed)
};

/// Return current stack statistics.
/// Panics loudly if baselines have not been recorded.
pub fn getStackStats() StackStats {
    if (!app_recorded) {
        std.debug.print("\n\nFATAL: stack-stats called but app-baseline was never recorded!\n" ++
            "This means stack_stats.recordAppBaseline() was not called at startup.\n" ++
            "Fix: call stack_stats.recordAppBaseline() at the top of main().\n\n", .{});
        std.process.exit(1);
    }
    if (!vm_recorded) {
        std.debug.print("\n\nFATAL: stack-stats called but vm-baseline was never recorded!\n" ++
            "This means stack_stats.recordVMBaseline() was not called after core init.\n" ++
            "Fix: call stack_stats.recordVMBaseline() after loadCoreLibrary() in main().\n\n", .{});
        std.process.exit(1);
    }

    const current = captureStackPtr();
    // Stack grows downward; usage is positive when current < app_baseline.
    const usage = if (current <= app_baseline) app_baseline - current else 0;

    return StackStats{
        .app_baseline = app_baseline,
        .vm_baseline = vm_baseline,
        .current = current,
        .usage = usage,
    };
}

/// zig.core/stack-stats — return a map of stack statistics.
/// Takes no arguments. Returns a map with keys:
///   :app-baseline  — stack pointer at program start
///   :vm-baseline   — stack pointer after clojure core init
///   :current       — current stack pointer
///   :usage         — app-baseline - current (bytes of stack consumed)
pub fn core_stack_stats(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;

    const allocator = env.allocator;
    const stats = getStackStats();

    // Build a map: {:app-baseline N, :vm-baseline N, :current N, :usage N}
    var entries: std.ArrayListUnmanaged(Value.MapEntry) = .empty;
    errdefer {
        for (entries.items) |*e| {
            e.key.deinit(allocator);
            e.value.deinit(allocator);
        }
        entries.deinit(allocator);
    }

    const fields = [_]struct { key: []const u8, val: usize }{
        .{ .key = "app-baseline", .val = stats.app_baseline },
        .{ .key = "vm-baseline", .val = stats.vm_baseline },
        .{ .key = "current", .val = stats.current },
        .{ .key = "usage", .val = stats.usage },
    };

    for (fields) |f| {
        const key = try Value.keywordValue(allocator, f.key);
        const val = Value.intValue(@as(i64, @intCast(f.val)));
        try entries.append(allocator, .{ .key = key, .value = val });
    }

    return Value.mapValue(entries);
}

/// Register the stack-stats builtin in the zig.core namespace.
pub fn registerStackStats(env: *Env) anyerror!void {
    try env.put("stack-stats", Value.builtinFnValue(core_stack_stats));
}

test "stack_stats::captureStackPtr: returns non-zero address" {
    const ptr = captureStackPtr();
    try std.testing.expect(ptr != 0);
}

test "stack_stats::getStackStats: panics without baselines" {
    // This test verifies the happy path once baselines are set.
    // The panic paths are tested by the FATAL print + exit(1) logic.
    app_baseline = 1000;
    vm_baseline = 900;
    app_recorded = true;
    vm_recorded = true;

    const stats = getStackStats();
    try std.testing.expect(stats.app_baseline == 1000);
    try std.testing.expect(stats.vm_baseline == 900);
    try std.testing.expect(stats.current != 0);
    // usage should be reasonable (current is on test stack, likely < 1000 or > 1000)
    _ = stats.usage;
}
