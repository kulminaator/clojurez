// Threading built-in functions: sleep, future-call, deref-future, realized
// Phase 2-4 of multithreading support.
//
// Design: Uses atomic state + sleep-based polling for thread safety.
// No mutex needed — FutureData.result is written once (after completion),
// and the atomic state guards visibility.
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;
const eval = @import("../../eval.zig");
const gc_mod = @import("../../gc.zig");
const gc_scan = @import("../../gc_scan.zig");
const timeout_mod = @import("../../timeout.zig");

/// State values for FutureData.state atomic.
const FutureState = struct {
    pub const running: u32 = 0;
    pub const done: u32 = 1;
    pub const error_state: u32 = 2;
};

/// State values for PromiseData.state atomic.
const PromiseState = struct {
    pub const pending: u32 = 0;
    pub const delivered: u32 = 1;
};

/// Thread entry point for future computation.
/// Receives: fn_val (Value), future_data (*FutureData)
/// The function's captured environment is accessed via fn_val.FnData.env.
fn futureThreadEntry(fn_val: Value, future_data: *vm.FutureData) void {
    const allocator = future_data.allocator;
    const gc = gc_mod.current_gc orelse return;

    // The GC lock counter was incremented BEFORE Thread.spawn in core_future_call.
    // We decrement it when the thread finishes via threadDone().
    // Disable auto-GC in child threads since they're short-lived.
    const prev_auto_gc = gc.auto_gc_active;
    gc.auto_gc_active = false;

    var result: Value = undefined;

    errhandler: {
        // Get the function's captured environment and clone it for this thread.
        // The fn_val is a .function with FnData that contains the captured Env.
        const fn_data = fn_val.function;
        const parent_env = fn_data.env;

        // Clone the parent env for this thread's evaluation
        var child_env = parent_env.clone(allocator) catch {
            future_data.error_msg = allocator.dupe(u8, "failed to clone env") catch null;
            future_data.state.store(FutureState.error_state, .release);
            break :errhandler;
        };

        // Phase 8: Create a root Frame for this thread and register it as a thread root.
        // This ensures the frame chain is visible to GC during collection.
        const root_frame = eval.createRootFrame(allocator, &child_env) catch {
            child_env.deinit(allocator);
            future_data.error_msg = allocator.dupe(u8, "failed to create root frame") catch null;
            future_data.state.store(FutureState.error_state, .release);
            break :errhandler;
        };
        gc.registerThreadRoot(@as(*anyopaque, @ptrCast(root_frame)));

        // Call the function with no arguments using eval.call (Frame-based)
        // Disable trampolining so callFunction evaluates body directly.
        // trampoline_allowed is thread-local so this doesn't affect other threads.
        const saved_trampoline = eval.trampoline_allowed;
        eval.trampoline_allowed = false;
        defer eval.trampoline_allowed = saved_trampoline;
        const empty_args: list.List = .empty;
        const call_result = eval.call(allocator, &fn_val, &empty_args, root_frame, 0) catch {
            future_data.error_msg = allocator.dupe(u8, "evaluation error") catch null;
            future_data.state.store(FutureState.error_state, .release);
            // Cleanup in error path: deinit frame, unregister, deinit env
            root_frame.deinit(allocator);
            gc.unregisterThreadRoot();
            child_env.deinit(allocator);
            break :errhandler;
        };
        result = call_result.value.*;

        // Store result and mark done
        future_data.result = result;
        future_data.state.store(FutureState.done, .release);

        // Cleanup: deinit frame BEFORE unregistering thread root.
        // This ensures the frame is fully cleaned up while still protected
        // by gc_lock counter (main thread can't collect while counter > 0).
        root_frame.deinit(allocator);
        gc.unregisterThreadRoot();
        child_env.deinit(allocator);
    }

    // Restore auto-GC setting
    gc.auto_gc_active = prev_auto_gc;
    // Decrement GC lock counter — main thread can collect when counter reaches 0.
    gc.threadDone();
}

/// Helper: get an Io instance for sleep calls.
fn getIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// zig.core/future-call — spawn a future from a zero-arg function.
/// Args: (future-call fn)
/// fn must be a .function or .builtin_fn value.
/// Returns a .future value that will contain the result when done.
pub fn core_future_call(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const fn_val = args.items[0];
    const allocator = env_env.allocator;

    // Validate that fn_val is callable
    const tag = std.meta.activeTag(fn_val);
    if (tag != .function and tag != .builtin_fn) return error.TypeError;

    // Clone the function value for the child thread.
    // This deep-clones the FnData and its captured Env, so the child thread
    // gets an independent copy of the closure environment.
    const cloned_fn = try vm.shallowClone(&fn_val, allocator);

    // Create the FutureData and store the cloned function in it.
    // Storing fn_val in FutureData is critical: the GC scans FutureData.fn_val
    // to discover the function and its captured environment, keeping them alive
    // while the future thread is running.
    const future_data = try allocator.create(vm.FutureData);
    future_data.* = .{ .allocator = allocator, .fn_val = cloned_fn };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(future_data)), gc_mod.GCObjectType.future_data);
        // Set generation to max so FutureData is never swept by generational protection.
        // The FutureData is detached from the main thread's evaluation stack,
        // so the GC can't discover it through normal root scanning.
        // It stays alive until the process exits (threads are detached).
        if (gc.findHeader(@as(*anyopaque, @ptrCast(future_data)))) |hdr| {
            hdr.generation = std.math.maxInt(u32);
        }
        // Lock GC BEFORE spawning the thread. This prevents the main thread's
        // GC from sweeping the captured Env/HAMT between spawn and when the
        // child thread starts running. The child thread will release the lock
        // via threadDone() when it finishes.
        gc.threadStart();
    }

    // Spawn the thread — pass only fn_val and future_data.
    // The thread derives its environment from fn_val.FnData.env.
    const config = std.Thread.SpawnConfig{
        .stack_size = 1024 * 1024 * 8, // 8MB stack
        .allocator = null,
    };
    const thread = std.Thread.spawn(config, futureThreadEntry, .{ cloned_fn, future_data }) catch {
        // Thread spawn failed — unlock GC and clean up
        if (gc_mod.current_gc) |gc| gc.threadDone();
        var fn_copy = cloned_fn;
        vm.valueDeinit(&fn_copy, allocator);
        future_data.fn_val = null;
        future_data.error_msg = allocator.dupe(u8, "thread spawn failed") catch null;
        future_data.state.store(FutureState.error_state, .release);
        return try vm.futureValue(allocator);
    };

    // Detach the thread — it manages its own lifecycle.
    // The FutureData will be cleaned up when the future value is GC'd.
    thread.detach();

    // Create the future value wrapping our FutureData
    return Value{ .future = future_data };
}

/// zig.core/deref-future — dereference a future (blocking with sleep-based polling).
/// Args: (deref-future future) or (deref-future future timeout-ms timeout-val)
/// Blocks until the future completes, then returns the result.
/// With timeout: returns timeout-val if the future doesn't complete in time.
pub fn core_deref_future(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1 or args.items.len > 3) return error.ArityError;

    const future_val = args.items[0];
    if (std.meta.activeTag(future_val) != .future) return error.TypeError;
    // Cast away const for atomic operations — safe: we only read state, result is written once
    const data: *vm.FutureData = @ptrCast(@alignCast(@constCast(future_val.future)));
    const allocator = env_env.allocator;

    // Root the FutureData during the polling loop so the GC doesn't sweep it
    // (and its captured FnData, Env, and HAMT nodes) while the child thread
    // is still using them. The future Value is in a stack-allocated args buffer
    // that the GC can't discover, so without this root the FutureData becomes
    // unreachable during GC collection.
    if (gc_mod.current_gc) |gc| {
        gc.addRoot(@as(*anyopaque, @ptrCast(@constCast(data))));
        defer gc.removeRoot(@as(*anyopaque, @ptrCast(@constCast(data))));
    }

    const has_timeout = args.items.len == 3;
    const timeout_ms: i64 = if (has_timeout) switch (args.items[1]) {
        .integer => |i| i,
        else => return error.TypeError,
    } else 0;
    const timeout_val = if (has_timeout) &args.items[2] else null;

    const io = getIo();
    var elapsed_ms: i64 = 0;

    // Poll until done or timeout
    while (data.state.load(.acquire) == FutureState.running) {
        if (has_timeout and elapsed_ms >= timeout_ms) {
            if (timeout_val) |tv| return try vm.shallowClone(tv, allocator);
            return vm.nilValue();
        }
        // Check VM-level timeout
        if (timeout_mod.checkTimeout()) return timeout_mod.TimeoutExpired;
        // Sleep 1ms between polls
        const sleep_duration = std.Io.Duration.fromMilliseconds(1);
        std.Io.sleep(io, sleep_duration, std.Io.Clock.awake) catch {};
        elapsed_ms += 1;
    }

    const state = data.state.load(.monotonic);
    return switch (state) {
        FutureState.done => {
            if (data.result) |*r| return try vm.shallowClone(r, allocator);
            return vm.nilValue();
        },
        FutureState.error_state => {
            _ = data.error_msg;
            return error.FutureError;
        },
        else => error.FutureError,
    };
}

/// zig.core/realized — check if a future or promise is realized.
/// Args: (realized value)
/// Returns true if the future/promise has completed.
pub fn core_realized(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const val = args.items[0];
    return switch (val) {
        .future => |data| {
            // Cast away const for atomic load — safe because we're only reading
            const mutable_data: *vm.FutureData = @ptrCast(@alignCast(@constCast(data)));
            const state = mutable_data.state.load(.monotonic);
            return vm.boolValue(state != FutureState.running);
        },
        .promise => |data| {
            const mutable_data: *vm.PromiseData = @ptrCast(@alignCast(@constCast(data)));
            const state = mutable_data.state.load(.monotonic);
            return vm.boolValue(state == PromiseState.delivered);
        },
        .lazy_seq => |thunk| {
            // For lazy_seq, realized means it has been forced (thunk is null)
            return vm.boolValue(thunk == null);
        },
        else => vm.boolValue(false),
    };
}

/// zig.core/sleep — sleep for N milliseconds.
/// Args: (sleep milliseconds)
/// milliseconds must be a non-negative integer.
/// Checks for timeout expiry every 100ms during sleep.
pub fn core_sleep(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const ms: i64 = switch (args.items[0]) {
        .integer => |i| i,
        else => return error.TypeError,
    };
    if (ms < 0) return error.TypeError;

    const io = std.Io.Threaded.global_single_threaded.io();
    var remaining: i64 = ms;
    while (remaining > 0) {
        // Check timeout every 100ms
        const slice = if (remaining < 100) remaining else @as(i64, 100);
        const duration = std.Io.Duration.fromMilliseconds(slice);
        std.Io.sleep(io, duration, std.Io.Clock.awake) catch {};
        remaining -= slice;
        if (timeout_mod.checkTimeout()) return timeout_mod.TimeoutExpired;
    }

    return vm.nilValue();
}

/// zig.core/promise — create a new promise.
/// Args: (promise)
/// Returns a .promise value.
pub fn core_promise(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = args;
    return try vm.promiseValue(env_env.allocator);
}

/// zig.core/deliver — deliver a value to a promise (one-time write).
/// Args: (deliver promise value)
/// If already delivered, no-op. Returns the promise itself.
pub fn core_deliver(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;

    const promise_val = args.items[0];
    if (std.meta.activeTag(promise_val) != .promise) return error.TypeError;
    const data: *vm.PromiseData = @ptrCast(@alignCast(@constCast(promise_val.promise)));
    const allocator = env_env.allocator;

    // Clone the value first.
    const cloned = try vm.shallowClone(&args.items[1], allocator);

    // Atomically transition state from pending to delivered.
    // Only the first deliver succeeds; subsequent delivers are no-ops.
    // cmpxchgStrong returns null on success, some(prev) on failure.
    const expected: u32 = PromiseState.pending;
    const prev = data.state.cmpxchgStrong(expected, PromiseState.delivered, .acq_rel, .monotonic);
    if (prev == null) {
        // We won the race — store the value
        data.value = cloned;
    }
    // If we lost the race (prev != null), the cloned value will be cleaned up by GC.
    // The promise already has a value from the first deliver.

    return promise_val;
}

/// zig.core/deref-promise — dereference a promise (blocking with sleep-based polling).
/// Args: (deref-promise promise) or (deref-promise promise timeout-ms timeout-val)
/// Blocks until the promise is delivered, then returns the value.
pub fn core_deref_promise(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1 or args.items.len > 3) return error.ArityError;

    const promise_val = args.items[0];
    if (std.meta.activeTag(promise_val) != .promise) return error.TypeError;
    const data: *vm.PromiseData = @ptrCast(@alignCast(@constCast(promise_val.promise)));
    const allocator = env_env.allocator;

    // Root the PromiseData during the polling loop so the GC doesn't sweep it
    // while waiting for delivery. The promise Value is in a stack-allocated
    // args buffer that the GC can't discover.
    if (gc_mod.current_gc) |gc| {
        gc.addRoot(@as(*anyopaque, @ptrCast(@constCast(data))));
        defer gc.removeRoot(@as(*anyopaque, @ptrCast(@constCast(data))));
    }

    const has_timeout = args.items.len == 3;
    const timeout_ms: i64 = if (has_timeout) switch (args.items[1]) {
        .integer => |i| i,
        else => return error.TypeError,
    } else 0;
    const timeout_val = if (has_timeout) &args.items[2] else null;

    const io = getIo();
    var elapsed_ms: i64 = 0;

    // Poll until delivered or timeout
    while (data.state.load(.acquire) == PromiseState.pending) {
        if (has_timeout and elapsed_ms >= timeout_ms) {
            if (timeout_val) |tv| return try vm.shallowClone(tv, allocator);
            return vm.nilValue();
        }
        // Check VM-level timeout
        if (timeout_mod.checkTimeout()) return timeout_mod.TimeoutExpired;
        const sleep_duration = std.Io.Duration.fromMilliseconds(1);
        std.Io.sleep(io, sleep_duration, std.Io.Clock.awake) catch {};
        elapsed_ms += 1;
    }

    // Delivered — return the value
    if (data.value) |*v| return try vm.shallowClone(v, allocator);
    return vm.nilValue();
}

/// Register threading functions in zig.core namespace.
pub fn registerThreadingFunctions(env: *Env) anyerror!void {
    try env.put("sleep", vm.builtinFnValue(core_sleep));
    try env.put("future-call", vm.builtinFnValue(core_future_call));
    try env.put("deref-future", vm.builtinFnValue(core_deref_future));
    try env.put("promise", vm.builtinFnValue(core_promise));
    try env.put("deliver", vm.builtinFnValue(core_deliver));
    try env.put("deref-promise", vm.builtinFnValue(core_deref_promise));
    try env.put("realized", vm.builtinFnValue(core_realized));
}

// ===== Unit Tests =====

const test_utils = @import("test_utils.zig");

test "threading::sleep: accepts zero milliseconds" {
    var e = test_utils.testEnv();
    defer e.deinit(std.heap.page_allocator);
    const args = test_utils.makeArgs(&[_]Value{ vm.intValue(0) });
    var result = core_sleep(test_utils.testSelf(), &args, &e) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "threading::sleep: accepts positive milliseconds" {
    var e = test_utils.testEnv();
    defer e.deinit(std.heap.page_allocator);
    const args = test_utils.makeArgs(&[_]Value{ vm.intValue(1) });
    var result = core_sleep(test_utils.testSelf(), &args, &e) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "threading::sleep: rejects negative milliseconds" {
    var e = test_utils.testEnv();
    defer e.deinit(std.heap.page_allocator);
    const args = test_utils.makeArgs(&[_]Value{ vm.intValue(-1) });
    try std.testing.expectError(error.TypeError, core_sleep(test_utils.testSelf(), &args, &e));
}

test "threading::sleep: rejects wrong arity" {
    var e = test_utils.testEnv();
    defer e.deinit(std.heap.page_allocator);
    const args = test_utils.makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_sleep(test_utils.testSelf(), &args, &e));
}

test "threading::sleep: rejects non-integer" {
    var e = test_utils.testEnv();
    defer e.deinit(std.heap.page_allocator);
    const args = test_utils.makeArgs(&[_]Value{ vm.boolValue(true) });
    try std.testing.expectError(error.TypeError, core_sleep(test_utils.testSelf(), &args, &e));
}
