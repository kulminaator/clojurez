// Timeout watchdog for clojurez --timeout flag.
// Spawns a watchdog thread that fires after N seconds.
// On expiry: sets a global flag, prints error, kills child processes, exits with code 124.
const std = @import("std");
const gc_mod = @import("gc.zig");

// ============================================================
// Error set
// ============================================================

/// Error set for timeout-related errors.
pub const TimeoutError = error{TimeoutExpired};

/// The TimeoutExpired error value (for comparison in catch blocks).
pub const TimeoutExpired = TimeoutError.TimeoutExpired;

/// Check if an error is the TimeoutExpired error.
/// Works around Zig 0.16's capture restrictions in catch blocks.
pub fn isTimeoutError(err: anyerror) bool {
    return err == TimeoutExpired;
}

// ============================================================
// Global state
// ============================================================

/// Atomic flag: set to true when timeout expires.
/// Checked periodically by the evaluator and blocking operations.
var timeout_expired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// The configured timeout in seconds (0 = no timeout).
var timeout_seconds: usize = 0;

/// The watchdog thread handle (null if no timeout configured).
var watchdog_thread: ?std.Thread = null;

// ============================================================
// Process tracking (for cleanup on timeout)
// ============================================================

/// Callback function type for killing a tracked process handle.
/// Receives the anyopaque pointer stored when the process was registered.
pub const ProcessKillFn = *const fn (handle: *anyopaque) void;

/// Track active subprocess handles so the watchdog can kill them.
/// Each entry is an anyopaque pointer to a ProcessHandle + a kill callback.
const TrackedProcess = struct {
    handle: *anyopaque,
    kill_fn: ProcessKillFn,
};

var process_handles_mutex = std.Io.Mutex.init;
var process_handles: std.ArrayListUnmanaged(TrackedProcess) = .empty;

/// Register a subprocess for tracking (called from io_shell.zig).
/// handle: pointer to the process handle (e.g. *ProcessHandle)
/// kill_fn: function to call to kill the process
pub fn registerProcess(handle: *anyopaque, kill_fn: ProcessKillFn) void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (!process_handles_mutex.tryLock()) return;
    defer process_handles_mutex.unlock(io);
    process_handles.append(allocator, .{ .handle = handle, .kill_fn = kill_fn }) catch {};
}

/// Unregister a subprocess (called when process finishes normally).
pub fn unregisterProcess(handle: *anyopaque) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (!process_handles_mutex.tryLock()) return;
    defer process_handles_mutex.unlock(io);
    var i: usize = 0;
    while (i < process_handles.items.len) : (i += 1) {
        if (process_handles.items[i].handle == handle) {
            _ = process_handles.swapRemove(i);
            return;
        }
    }
}

/// Kill all tracked subprocesses.
pub fn killAllProcesses() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (!process_handles_mutex.tryLock()) return;
    defer process_handles_mutex.unlock(io);

    for (process_handles.items) |tp| {
        tp.kill_fn(tp.handle);
    }
    process_handles.clearRetainingCapacity();
}

// ============================================================
// Watchdog thread
// ============================================================

fn watchdogMain() void {
    // Wait for the timeout duration
    const io = std.Io.Threaded.global_single_threaded.io();
    const duration = std.Io.Duration.fromSeconds(@as(i64, @intCast(timeout_seconds)));
    std.Io.sleep(io, duration, std.Io.Clock.awake) catch {};

    // Timeout expired — set the flag first so the evaluator can see it
    timeout_expired.store(true, .release);

    // Give a brief grace period for voluntary shutdown
    const grace_duration = std.Io.Duration.fromMilliseconds(500);
    std.Io.sleep(io, grace_duration, std.Io.Clock.awake) catch {};

    // If we're still here, force cleanup
    std.debug.print("Error: execution timed out after {d} seconds\n", .{timeout_seconds});

    // Kill all tracked child processes
    killAllProcesses();

    // Force exit with code 124 (GNU timeout convention)
    std.process.exit(124);
}

// ============================================================
// Public API
// ============================================================

/// Initialize the timeout watchdog.
/// seconds: timeout in seconds (0 = no timeout, do nothing).
/// Returns the watchdog thread handle if created, null otherwise.
pub fn initTimeout(seconds: usize) ?std.Thread {
    if (seconds == 0) return null;

    timeout_seconds = seconds;
    timeout_expired.store(false, .release);

    const config = std.Thread.SpawnConfig{
        .stack_size = 64 * 1024, // 64KB is plenty for a watchdog
        .allocator = null,
    };
    const thread = std.Thread.spawn(config, watchdogMain, .{}) catch null;
    if (thread) |t| {
        t.detach();
        watchdog_thread = t;
        return t;
    }
    return null;
}

/// Check if the timeout has expired.
/// Returns true if the watchdog has fired.
pub fn isExpired() bool {
    return timeout_expired.load(.acquire);
}

/// Check and optionally handle timeout.
/// Returns true if timeout has expired (caller should abort).
/// Used by the evaluator and blocking operations.
pub fn checkTimeout() bool {
    return isExpired();
}

/// Cleanup: called on normal exit (before timeout fires).
/// The watchdog thread will see the process exit and terminate naturally.
pub fn cleanupTimeout() void {
    // Nothing to do — watchdog thread detaches and will be cleaned up by OS.
    // On normal exit, the process exits before the watchdog fires.
    _ = watchdog_thread;
}

/// Get the configured timeout in seconds.
pub fn getTimeoutSeconds() usize {
    return timeout_seconds;
}
