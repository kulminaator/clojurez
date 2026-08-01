// Agent built-in functions: agent creation, agent? predicate, and thread pool.
// Agents provide asynchronous, ordered state updates via a worker thread pool.
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const AgentWatchEntry = vm.AgentWatchEntry;
const list = @import("../../list.zig");
const Env = vm.Env;
const gc_mod = @import("../../gc.zig");
const eval = @import("../../eval.zig");

const timeout_mod = @import("../../timeout.zig");
const test_utils = @import("test_utils.zig");

const Allocator = std.mem.Allocator;

// ============================================================
// Agent Send Thread Pool
// ============================================================

var send_pool_initialized: bool = false;
var send_off_pool_initialized: bool = false;
var send_pool_shutdown: bool = false;
var send_off_pool_shutdown: bool = false;

/// Initialize the send thread pool (no-op for per-action threading).
pub fn initSendThreadPool(thread_count: usize) void {
    _ = thread_count;
    if (send_pool_initialized) return;
    send_pool_initialized = true;
}

/// Initialize the send-off thread pool (no-op for per-action threading).
pub fn initSendOffThreadPool(thread_count: usize) void {
    _ = thread_count;
    if (send_off_pool_initialized) return;
    send_off_pool_initialized = true;
}

/// Enqueue an agent for action processing (send pool).
/// For now, spawn a thread per action (like futures).
pub fn enqueueAgent(data: *vm.AgentData) void {
    if (send_pool_shutdown) return;

    const gc = gc_mod.current_gc orelse return;

    // Lock GC before spawning thread
    gc.threadStart();

    const config = std.Thread.SpawnConfig{
        .stack_size = 1024 * 1024 * 4, // 4MB stack
        .allocator = null,
    };
    const thread = std.Thread.spawn(config, agentActionThread, .{ data, std.heap.page_allocator }) catch {
        gc.threadDone();
        return;
    };
    thread.detach();
}

/// Enqueue an agent for action processing (send-off pool).
/// Uses the same per-action threading model but tracked separately.
pub fn enqueueAgentOff(data: *vm.AgentData) void {
    if (send_off_pool_shutdown) return;

    const gc = gc_mod.current_gc orelse return;

    // Lock GC before spawning thread
    gc.threadStart();

    const config = std.Thread.SpawnConfig{
        .stack_size = 1024 * 1024 * 4, // 4MB stack
        .allocator = null,
    };
    const thread = std.Thread.spawn(config, agentActionThread, .{ data, std.heap.page_allocator }) catch {
        gc.threadDone();
        return;
    };
    thread.detach();
}

/// Thread entry point for processing a single agent action.
fn agentActionThread(data: *vm.AgentData, allocator: Allocator) void {
    const gc = gc_mod.current_gc orelse return;
    const prev_auto_gc = gc.auto_gc_active;
    gc.auto_gc_active = false;
    defer gc.auto_gc_active = prev_auto_gc;

    defer gc.threadDone();

    // Use the GC allocator, not the page allocator
    const gc_allocator = gc.allocator();
    processAgentActions(data, gc_allocator);
    _ = allocator; // page_allocator not used
}

/// Call the error handler function with (exception, agent).
/// Result is discarded — error handler is best-effort.
fn callErrorHandler(
    data: *vm.AgentData,
    allocator: Allocator,
    handler: *const Value,
    exception: Value,
) void {
    var call_args: list.List = .empty;
    defer call_args.deinit(allocator);
    call_args.append(allocator, exception) catch return;
    call_args.append(allocator, vm.agentValueShared(data)) catch return;

    const fn_data = handler.function;
    var child_env = fn_data.env.clone(allocator) catch return;
    defer child_env.deinit(allocator);

    const root_frame = eval.createRootFrame(allocator, &child_env) catch return;
    defer root_frame.deinit(allocator);

    const saved_trampoline = eval.trampoline_allowed;
    eval.trampoline_allowed = false;
    defer eval.trampoline_allowed = saved_trampoline;

    _ = eval.call(allocator, handler, &call_args, root_frame, 0) catch {};
}

/// Process a single action, returning true if processing should continue.
fn processSingleAction(
    data: *vm.AgentData,
    allocator: Allocator,
    fn_val: *const Value,
    call_args: *const list.List,
    root_frame: *vm.Frame,
) bool {
    const old_value = data.value;
    // Disable trampolining so eval.call returns the final value directly.
    // Without this, the action function body would return .trampoline and
    // we'd incorrectly set data.value to nil.
    const saved_trampoline = eval.trampoline_allowed;
    eval.trampoline_allowed = false;
    defer eval.trampoline_allowed = saved_trampoline;

    const result = eval.call(allocator, fn_val, call_args, root_frame, 0) catch {
        // Action threw an exception — capture it and handle based on error mode
        vm.valueDeinit(&data.value, allocator);
        data.value = old_value; // restore old value on error

        // Capture the exception if one was thrown
        if (eval.hasException()) {
            if (eval.getException()) |ex_data| {
                // Create an exception value from the data
                const ex_val = vm.exceptionValueFromData(ex_data);
                const cloned_ex = vm.clone(&ex_val, allocator) catch {
                    eval.clearException();
                    if (data.error_mode == .continue_) {
                        return true;
                    } else {
                        data.failed = true;
                        return false;
                    }
                };
                // Store as most recent error
                if (data.agent_error) |old_err| {
                    var old_copy = old_err;
                    vm.valueDeinit(&old_copy, allocator);
                }
                data.agent_error = cloned_ex;
                // Append to errors list
                data.agent_errors_list.append(allocator, cloned_ex) catch {};
                eval.clearException();

                // Call error handler if set
                if (data.error_handler) |handler| {
                    callErrorHandler(data, allocator, &handler, cloned_ex);
                }

                if (data.error_mode == .continue_) {
                    return true; // skip this action and continue
                } else {
                    data.failed = true; // :fail mode, stop processing
                    return false;
                }
            }
        }

        // No exception captured (some other error)
        if (data.error_mode == .continue_) {
            return true;
        } else {
            data.failed = true;
            return false;
        }
    };

    switch (result) {
        .value => |new_val| {
            vm.valueDeinit(&data.value, allocator);
            data.value = new_val;
        },
        .trampoline => {
            // Should not happen with trampoline_allowed = false,
            // but handle gracefully just in case.
            vm.valueDeinit(&data.value, allocator);
            data.value = vm.nilValue();
        },
    }

    // Run validator check after successful action.
    // If validation fails, treat it as an agent error.
    if (data.validator) |validator| {
        const validation_ok = validateAgentValue(data, allocator, &validator);
        if (!validation_ok) {
            // Validation failed — restore old value
            vm.valueDeinit(&data.value, allocator);
            data.value = old_value;
            return false;
        }
    }

    // Fire watch functions after successful action (value has changed).
    fireWatches(data, allocator, old_value, data.value);

    return true;
}

/// Validate the agent's current value against its validator function.
/// Returns true if validation passes, false if it fails.
/// On failure, stores the validation exception and sets the failed flag.
fn validateAgentValue(
    data: *vm.AgentData,
    allocator: Allocator,
    validator: *const Value,
) bool {
    // Build arguments: (validator current_value)
    var val_args: list.List = .empty;
    defer val_args.deinit(allocator);
    val_args.append(allocator, data.value) catch return false;

    const fn_data = validator.function;
    var child_env = fn_data.env.clone(allocator) catch return false;
    defer child_env.deinit(allocator);

    const root_frame = eval.createRootFrame(allocator, &child_env) catch return false;
    defer root_frame.deinit(allocator);

    const saved_trampoline = eval.trampoline_allowed;
    eval.trampoline_allowed = false;
    defer eval.trampoline_allowed = saved_trampoline;

    const result = eval.call(allocator, validator, &val_args, root_frame, 0) catch {
        // Validator threw an exception — treat as validation failure
        if (eval.hasException()) {
            if (eval.getException()) |ex_data| {
                const ex_val = vm.exceptionValueFromData(ex_data);
                const cloned_ex = vm.clone(&ex_val, allocator) catch return false;
                storeAgentError(data, allocator, cloned_ex);
                eval.clearException();
            }
        }
        return false;
    };

    switch (result) {
        .value => |val_result| {
            // Validator must return truthy value (not nil and not false)
            if (std.meta.activeTag(val_result) == .nil or
                (std.meta.activeTag(val_result) == .bool and !val_result.bool))
            {
                // Create an IllegalArgumentException for validation failure
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Validation error (agent \"{s}\" failed validating new state)",
                    .{agentValueDescription(data)},
                ) catch return false;
                defer allocator.free(msg);
                // Create empty map for exception data
                const empty_map = vm.mapValue(allocator, std.ArrayListUnmanaged(vm.MapEntry).empty) catch return false;
                const ex_val = vm.exceptionValue(
                    allocator,
                    msg,
                    empty_map.map,
                    null,
                    "clojure.lang/IllegalArgumentException",
                ) catch return false;
                storeAgentError(data, allocator, ex_val);
                return false;
            }
        },
        .trampoline => {
            // Should not happen with trampoline_allowed = false
            return false;
        },
    }
    return true;
}

/// Helper: build a short description of the agent for error messages.
fn agentValueDescription(data: *const vm.AgentData) []const u8 {
    // Use a simple description based on the value type
    return switch (std.meta.activeTag(data.value)) {
        .nil => "nil",
        .integer => "integer",
        .float => "float",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .list => "list",
        .vector => "vector",
        .map => "map",
        .set => "set",
        else => "value",
    };
}

/// Store an exception value as the agent's most recent error.
/// Clears the old error, appends to the errors list, and calls the error handler.
fn storeAgentError(
    data: *vm.AgentData,
    allocator: Allocator,
    ex_val: Value,
) void {
    // Clear old error
    if (data.agent_error) |old_err| {
        var old_copy = old_err;
        vm.valueDeinit(&old_copy, allocator);
    }
    data.agent_error = ex_val;
    // Append to errors list (best-effort)
    data.agent_errors_list.append(allocator, ex_val) catch {};

    // Call error handler if set
    if (data.error_handler) |handler| {
        callErrorHandler(data, allocator, &handler, ex_val);
    }
}

/// Process all pending actions for a single agent.
fn processAgentActions(data: *vm.AgentData, allocator: Allocator) void {
    // Lock the agent's spinlock to serialize action processing
    data.acquire();
    defer data.release();

    // Check if agent is shut down or failed
    if (data.shutdown) return;

    while (data.action_queue.items.len > 0) {
        // Check VM-level timeout
        if (timeout_mod.checkTimeout()) return;

        // Remove the first action from the queue
        const action = data.action_queue.orderedRemove(0);

        // If agent is in failed state (error-mode :fail), stop processing
        if (data.failed) {
            // Put action back and stop
            data.action_queue.insert(allocator, 0, action) catch {};
            break;
        }

        // Build arguments: (action_fn current_value extra_args...)
        var call_args: list.List = .empty;
        errdefer call_args.deinit(allocator);
        call_args.append(allocator, data.value) catch { cleanupAction(&action, allocator); continue; };
        var ai: usize = 0;
        while (ai < action.args.items.len) : (ai += 1) {
            call_args.append(allocator, action.args.items[ai]) catch { cleanupAction(&action, allocator); continue; };
        }

        // Clone the function's env for evaluation
        const fn_data = action.fn_val.function;
        var child_env = fn_data.env.clone(allocator) catch {
            // If env clone fails, skip this action
            cleanupAction(&action, allocator);
            continue;
        };

        // Create a root frame for this evaluation
        const root_frame = eval.createRootFrame(allocator, &child_env) catch {
            child_env.deinit(allocator);
            cleanupAction(&action, allocator);
            continue;
        };

        // Evaluate the action function
        const action_ok = processSingleAction(data, allocator, &action.fn_val, &call_args, root_frame);
        call_args.deinit(allocator);

        // Clean up the action resources
        cleanupAction(&action, allocator);

        // Deinit frame and env
        root_frame.deinit(allocator);
        child_env.deinit(allocator);

        // Decrement action_count after processing each action (success or failure).
        // The action was consumed regardless of outcome, so await-for must be unblocked.
        if (data.action_count > 0) data.action_count -= 1;
        if (data.action_count == 0) {
            data.signalAll();
        }

        if (!action_ok) break; // failed in :fail mode, stop processing
    }

    // Signal waiters if all actions have been processed.
    // This wakes up any threads blocked in core_await.
    if (data.action_count == 0) {
        data.signalAll();
    }
}

/// Clean up resources held by an action.
fn cleanupAction(action: *const vm.AgentAction, allocator: Allocator) void {
    var fn_copy = action.fn_val;
    vm.valueDeinit(&fn_copy, allocator);
    var ai: usize = 0;
    while (ai < action.args.items.len) : (ai += 1) {
        var arg = action.args.items[ai];
        vm.valueDeinit(&arg, allocator);
    }
    // Cast away const to free the args buffer
    const mutable_action: *vm.AgentAction = @ptrCast(@alignCast(@constCast(action)));
    mutable_action.args.deinit(allocator);
}

/// Shutdown the send thread pool (called during VM shutdown).
pub fn shutdownSendPool() void {
    if (!send_pool_initialized) return;
    send_pool_initialized = false;
    send_pool_shutdown = true;
}

/// Shutdown the send-off thread pool (called during VM shutdown).
pub fn shutdownSendOffPool() void {
    if (!send_off_pool_initialized) return;
    send_off_pool_initialized = false;
    send_off_pool_shutdown = true;
}

// ============================================================
// (agent initial-value & options) — Create an agent.
// Options: :error-handler, :error-mode, :validator, :meta
// ============================================================

pub fn core_agent(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 1) return error.ArityError;

    const initial = args.items[0];

    // Parse optional keyword arguments.
    var error_handler: ?Value = null;
    var error_mode: vm.AgentErrorMode = .fail;
    var validator: ?Value = null;
    var meta: ?Value = null;

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const kw = args.items[i];
        if (std.meta.activeTag(kw) != .keyword) continue;
        const name = kw.keyword.slice();

        if (std.mem.eql(u8, name, "error-handler") and i + 1 < args.items.len) {
            error_handler = args.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, name, "error-mode") and i + 1 < args.items.len) {
            const val = args.items[i + 1];
            if (std.meta.activeTag(val) == .keyword) {
                const mode_name = val.keyword.slice();
                if (std.mem.eql(u8, mode_name, "continue")) {
                    error_mode = .continue_;
                } else {
                    // Default :fail
                    error_mode = .fail;
                }
            }
            i += 1;
        } else if (std.mem.eql(u8, name, "validator") and i + 1 < args.items.len) {
            validator = args.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, name, "meta") and i + 1 < args.items.len) {
            meta = args.items[i + 1];
            i += 1;
        }
    }

    // Create the agent value via the factory function.
    const agent_val = try vm.agentValue(allocator, initial);

    // Apply options to the AgentData.
    const data = agent_val.agent;
    data.error_mode = error_mode;
    data.error_handler = error_handler;
    data.validator = validator;

    // Set generation to max so agents are never swept (like futures).
    if (gc_mod.current_gc) |gc| {
        const header = gc.findHeader(@as(*anyopaque, @ptrCast(data)));
        if (header) |h| {
            h.generation = std.math.maxInt(u32);
        }
    }

    return agent_val;
}

// ============================================================
// (agent? x) — Returns true if x is an agent.
// ============================================================

pub fn core_agent_q(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .agent);
}

// ============================================================
// (send agent f & args) — Queue an action on the agent.
// The action function f is called with (current-state & args).
// The result becomes the new agent state.
// Returns the agent.
// ============================================================

pub fn core_send(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 2) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;
    const fn_val = args.items[1];

    // Lock the agent's spinlock to serialize action queuing.
    data.acquire();

    // Clone the function value for the action.
    const cloned_fn = try vm.clone(&fn_val, allocator);

    // Clone extra args (args[2..]).
    var cloned_args: std.ArrayListUnmanaged(Value) = .empty;
    errdefer cloned_args.deinit(allocator);
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        const cloned_arg = try vm.clone(&args.items[i], allocator);
        try cloned_args.append(allocator, cloned_arg);
    }

    // Create the action and append to queue.
    const action: vm.AgentAction = .{
        .fn_val = cloned_fn,
        .args = cloned_args,
    };
    try data.action_queue.append(allocator, action);
    // cloned_args ownership transferred to action - don't deinit

    // Increment action count for await tracking.
    data.action_count += 1;

    // Unlock before enqueueing to avoid potential contention with worker threads.
    data.release();
    enqueueAgent(data);

    // Return the agent value.
    return vm.agentValueShared(data);
}

// ============================================================
// (send-off agent f & args) — Queue an action on the agent.
// Like send, but uses a separate thread pool suitable for blocking I/O.
// The action function f is called with (current-state & args).
// The result becomes the new agent state.
// Returns the agent.
// ============================================================

pub fn core_send_off(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 2) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;
    const fn_val = args.items[1];

    // Lock the agent's spinlock to serialize action queuing.
    data.acquire();

    // Clone the function value for the action.
    const cloned_fn = try vm.clone(&fn_val, allocator);

    // Clone extra args (args[2..]).
    var cloned_args: std.ArrayListUnmanaged(Value) = .empty;
    errdefer cloned_args.deinit(allocator);
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        const cloned_arg = try vm.clone(&args.items[i], allocator);
        try cloned_args.append(allocator, cloned_arg);
    }

    // Create the action and append to queue.
    const action: vm.AgentAction = .{
        .fn_val = cloned_fn,
        .args = cloned_args,
    };
    try data.action_queue.append(allocator, action);
    // cloned_args ownership transferred to action - don't deinit

    // Increment action count for await tracking.
    data.action_count += 1;

    // Unlock before enqueueing to avoid potential contention with worker threads.
    data.release();
    enqueueAgentOff(data);

    // Return the agent value.
    return vm.agentValueShared(data);
}

// ============================================================
// (await agent1 agent2 ...) — Block until all agents have processed their actions.
// Returns nil.
// ============================================================

pub fn core_await(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;

    // Validate all arguments are agents.
    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        if (std.meta.activeTag(args.items[i]) != .agent) return error.TypeError;
    }

    // Collect agent data pointers.
    var agent_datas: std.ArrayListUnmanaged(*vm.AgentData) = .empty;
    defer agent_datas.deinit(env.allocator);

    // Lock each agent's mutex and check if any has pending actions.
    i = 0;
    while (i < args.items.len) : (i += 1) {
        const data = args.items[i].agent;
        data.acquire();
        try agent_datas.append(env.allocator, data);
    }

    // Wait on each agent's condition variable until action_count == 0.
    // We use a loop to check all agents and re-wait if needed.
    var all_done = false;
    while (!all_done) {
        all_done = true;
        i = 0;
        while (i < agent_datas.items.len) : (i += 1) {
            const data = agent_datas.items[i];
            // Check VM-level timeout periodically
            if (timeout_mod.checkTimeout()) {
                // Unlock all mutexes before returning
                var j: usize = 0;
                while (j < agent_datas.items.len) : (j += 1) {
                    agent_datas.items[j].release();
                }
                return timeout_mod.TimeoutExpired;
            }
            if (data.action_count > 0) {
                all_done = false;
                // Wait on this agent's condition variable (releases and re-acquires mutex)
                data.waitWhile(agentsHavePending);
            }
        }
    }

    // Unlock all mutexes.
    i = 0;
    while (i < agent_datas.items.len) : (i += 1) {
        agent_datas.items[i].release();
    }

    return vm.nilValue();
}

/// Predicate for waitWhile: returns true while agent has pending actions.
fn agentsHavePending(data: *const vm.AgentData) bool {
    return data.action_count > 0;
}

// ============================================================
// (await-for timeout-ms agent1 agent2 ...)
// Block until all agents have processed their actions, or until
// the timeout (in milliseconds) is reached.
// Returns true if all actions completed, false on timeout.
// ============================================================

pub fn core_await_for(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 2) return error.ArityError;

    // First argument: timeout in milliseconds.
    const timeout_ms: i64 = switch (args.items[0]) {
        .integer => |i| i,
        else => return error.TypeError,
    };
    if (timeout_ms < 0) return error.TypeError;

    // Remaining arguments: one or more agents.
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (std.meta.activeTag(args.items[i]) != .agent) return error.TypeError;
    }

    // Collect agent data pointers (no locking - we poll action_count).
    var agent_datas: std.ArrayListUnmanaged(*vm.AgentData) = .empty;
    defer agent_datas.deinit(allocator);

    i = 1;
    while (i < args.items.len) : (i += 1) {
        const data = args.items[i].agent;
        try agent_datas.append(allocator, data);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    const clock = std.Io.Clock.awake;

    // Record the start time and compute the deadline.
    const start_time = std.Io.Timestamp.now(io, clock);
    const deadline = std.Io.Timestamp.addDuration(
        start_time,
        std.Io.Duration.fromMilliseconds(timeout_ms),
    );

    // Poll loop: try to lock each agent briefly to check action_count.
    // If a mutex is already held (worker thread processing), assume
    // the agent still has pending actions. This avoids blocking while
    // the worker thread holds the mutex during action execution.
    while (true) {
        // Check if all agents have completed their actions.
        var all_done = true;
        i = 0;
        while (i < agent_datas.items.len) : (i += 1) {
            const data = agent_datas.items[i];
            if (data.tryAcquire()) {
                // We got the lock - check action_count
                if (data.action_count > 0) {
                    all_done = false;
                }
                data.release();
            } else {
                // Mutex held by worker thread - agent is being processed
                all_done = false;
            }
            if (!all_done) break;
        }
        if (all_done) {
            return vm.boolValue(true);
        }

        // Check VM-level timeout.
        if (timeout_mod.checkTimeout()) {
            return timeout_mod.TimeoutExpired;
        }

        // Check if our deadline has passed.
        const now = std.Io.Timestamp.now(io, clock);
        const remaining = std.Io.Timestamp.durationTo(now, deadline);
        if (remaining.toMilliseconds() <= 0) {
            return vm.boolValue(false);
        }

        // Sleep for a short interval (10ms or remaining time, whichever is less).
        const sleep_ms: i64 = if (remaining.toMilliseconds() < 10) remaining.toMilliseconds() else 10;
        const sleep_duration = std.Io.Duration.fromMilliseconds(sleep_ms);
        std.Io.sleep(io, sleep_duration, clock) catch {};
    }
}

// ============================================================
// (agent-error agent) — Returns the most recent error for the agent, or nil.
// ============================================================

pub fn core_agent_error(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Lock to safely read the error field.
    data.acquire();
    defer data.release();

    if (data.agent_error) |err| {
        return try vm.clone(&err, env.allocator);
    } else {
        return vm.nilValue();
    }
}

// ============================================================
// (agent-errors agent) — Returns all errors for the agent as a vector.
// ============================================================

pub fn core_agent_errors(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Lock to safely read the errors list.
    data.acquire();
    defer data.release();

    // Clone each error value into a new vector.
    var errors_vec: std.ArrayListUnmanaged(Value) = .empty;
    errdefer errors_vec.deinit(allocator);
    var i: usize = 0;
    while (i < data.agent_errors_list.items.len) : (i += 1) {
        const cloned = try vm.clone(&data.agent_errors_list.items[i], allocator);
        try errors_vec.append(allocator, cloned);
    }

    return try vm.vectorValue(allocator, errors_vec);
}

// ============================================================
// (error-mode agent) — Returns the error mode of the agent
// as a keyword (:fail or :continue).
// ============================================================

pub fn core_error_mode(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Lock to safely read the error_mode field.
    data.acquire();
    defer data.release();

    const mode_str = switch (data.error_mode) {
        .fail => "fail",
        .continue_ => "continue",
    };
    return try vm.keywordValue(env.allocator, mode_str);
}

// ============================================================
// (error-handler agent) — Returns the error handler of the agent, or nil.
// ============================================================

pub fn core_error_handler(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Lock to safely read the error_handler field.
    data.acquire();
    defer data.release();

    if (data.error_handler) |handler| {
        return try vm.clone(&handler, env.allocator);
    } else {
        return vm.nilValue();
    }
}

// ============================================================
// (set-error-mode! agent mode) — Set the error mode of the agent.
// mode must be :fail or :continue. Returns the agent.
// ============================================================

pub fn core_set_error_mode_bang(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 2) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Second argument must be a keyword :fail or :continue.
    const mode_val = args.items[1];
    if (std.meta.activeTag(mode_val) != .keyword) return error.TypeError;
    const mode_name = mode_val.keyword.slice();

    const new_mode: vm.AgentErrorMode = if (std.mem.eql(u8, mode_name, "continue")) .continue_ else .fail;

    data.acquire();
    defer data.release();
    data.error_mode = new_mode;

    return vm.agentValueShared(data);
}

// ============================================================
// (set-error-handler! agent handler) — Set the error handler of the agent.
// handler is a function or nil to remove the handler. Returns nil.
// ============================================================

pub fn core_set_error_handler_bang(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 2) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    const handler_val = args.items[1];

    data.acquire();
    defer data.release();

    // Clone the new handler and deinit the old one.
    if (data.error_handler) |old_handler| {
        var old_copy = old_handler;
        vm.valueDeinit(&old_copy, allocator);
    }

    if (std.meta.activeTag(handler_val) == .nil) {
        data.error_handler = null;
    } else {
        data.error_handler = try vm.clone(&handler_val, allocator);
    }

    return vm.nilValue();
}

// ============================================================
// (clear-agent-errors agent) — Clear the errors of the agent and allow it to process again.
// Resets agent_error, agent_errors_list, and failed flag. Returns the agent.
// ============================================================

pub fn core_clear_agent_errors(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    data.acquire();
    defer data.release();

    // Clear agent_error (deinit old value if present).
    if (data.agent_error) |old_err| {
        var err_copy = old_err;
        vm.valueDeinit(&err_copy, allocator);
        data.agent_error = null;
    }

    // Clear agent_errors_list (deinit each error, then clear the list).
    var i: usize = 0;
    while (i < data.agent_errors_list.items.len) : (i += 1) {
        var err = data.agent_errors_list.items[i];
        vm.valueDeinit(&err, allocator);
    }
    data.agent_errors_list.deinit(allocator);
    data.agent_errors_list = .empty;

    // Reset the failed flag so the agent can process actions again.
    data.failed = false;

    return vm.agentValueShared(data);
}

// ============================================================
// (restart-agent agent new-value & options)
// Restart a failed agent with a new value.
// Options: :clear-actions true/false (default false)
// If :clear-actions true, the pending action queue is cleared.
// If :clear-actions false, remaining actions are re-queued for processing.
// Clears agent_error, agent_errors_list, and resets failed to false.
// Returns the agent.
// ============================================================

pub fn core_restart_agent(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 2) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;
    const new_value = args.items[1];

    // Parse optional keyword arguments.
    // Default: :clear-actions false (re-queue remaining actions).
    var clear_actions: bool = false;
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        const kw = args.items[i];
        if (std.meta.activeTag(kw) != .keyword) continue;
        const name = kw.keyword.slice();

        if (std.mem.eql(u8, name, "clear-actions") and i + 1 < args.items.len) {
            const val = args.items[i + 1];
            if (std.meta.activeTag(val) == .bool) {
                clear_actions = val.bool;
            }
            i += 1;
        }
    }

    // Replace the agent's value with the new value (clone it).
    const cloned_new = try vm.clone(&new_value, allocator);

    // Lock the agent mutex.
    data.acquire();
    errdefer data.release();

    // Set the new value.
    vm.valueDeinit(&data.value, allocator);
    data.value = cloned_new;

    // Clear agent_error (deinit old value if present).
    if (data.agent_error) |old_err| {
        var err_copy = old_err;
        vm.valueDeinit(&err_copy, allocator);
        data.agent_error = null;
    }

    // Clear agent_errors_list (deinit each error, then clear the list).
    var j: usize = 0;
    while (j < data.agent_errors_list.items.len) : (j += 1) {
        var err = data.agent_errors_list.items[j];
        vm.valueDeinit(&err, allocator);
    }
    data.agent_errors_list.deinit(allocator);
    data.agent_errors_list = .empty;

    // Reset the failed flag so the agent can process actions again.
    data.failed = false;

    // Track if we need to re-queue the agent (outside the lock).
    var needs_requeue: bool = false;

    if (clear_actions) {
        // Clear the action queue (deinit each action).
        var k: usize = 0;
        while (k < data.action_queue.items.len) : (k += 1) {
            cleanupAction(&data.action_queue.items[k], allocator);
        }
        data.action_queue.deinit(allocator);
        data.action_queue = .empty;
        // Reset action_count since all actions are cleared.
        data.action_count = 0;
        // Signal any waiters that actions are done.
        data.signalAll();
    } else if (data.action_queue.items.len > 0) {
        // Action queue remains intact — mark for re-queueing after unlock.
        needs_requeue = true;
    }

    // Unlock before enqueueing to avoid deadlock with worker threads.
    data.release();

    // Re-queue the agent for processing remaining actions (if needed).
    if (needs_requeue) {
        enqueueAgent(data);
    }

    return vm.agentValueShared(data);
}

// ============================================================
// (set-validator! agent validator)
// Set the validator for the agent. Validator is a function that takes
// the current value and returns truthy if valid. nil removes the validator.
// Validates the current value before setting the new validator.
// Returns nil.
// ============================================================

pub fn core_set_validator_bang(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 2) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    const validator_arg = args.items[1];

    // Lock the agent mutex.
    data.acquire();
    defer data.release();

    // If the new validator is not nil, validate the current value first.
    if (std.meta.activeTag(validator_arg) != .nil) {
        const validation_ok = validateAgentValue(data, allocator, &validator_arg);
        if (!validation_ok) {
            // Validation failed — throw IllegalArgumentException
            const empty_map = try vm.mapValue(allocator, std.ArrayListUnmanaged(vm.MapEntry).empty);
            const ex_val = try vm.exceptionValue(
                allocator,
                "Validation error (agent failed validating new state)",
                empty_map.map,
                null,
                "clojure.lang/IllegalArgumentException",
            );
            eval.current_exception = ex_val.exception;
            eval.exception_thrown = true;
            return eval.EvalError.Exception;
        }
    }

    // Replace the old validator with the new one.
    if (data.validator) |old_validator| {
        var old_copy = old_validator;
        vm.valueDeinit(&old_copy, allocator);
    }

    if (std.meta.activeTag(validator_arg) == .nil) {
        data.validator = null;
    } else {
        data.validator = try vm.clone(&validator_arg, allocator);
    }

    return vm.nilValue();
}

// ============================================================
// (get-validator agent) — Returns the validator of the agent, or nil.
// ============================================================

pub fn core_get_validator(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Lock to safely read the validator field.
    data.acquire();
    defer data.release();

    if (data.validator) |validator| {
        return try vm.clone(&validator, env.allocator);
    } else {
        return vm.nilValue();
    }
}

// ============================================================
// (add-watch agent key f)
// Add a watch function to the agent. The watch function is called with
// (key agent old-value new-value) after each successful state change.
// Returns the agent.
// ============================================================

pub fn core_add_watch(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 3) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Second argument must be a keyword (the watch key).
    const key_val = args.items[1];
    if (std.meta.activeTag(key_val) != .keyword) return error.TypeError;
    const key_str = key_val.keyword.slice();

    // Third argument is the watch function.
    const watch_fn = args.items[2];

    // Lock the agent mutex.
    data.acquire();
    defer data.release();

    // Clone the watch function for storage.
    const cloned_fn = try vm.clone(&watch_fn, allocator);

    // Check if there's an existing watch for this key and remove it.
    const existing = data.watches.get(key_str);
    if (existing) |old_entry| {
        var old_fn = old_entry.fn_val;
        vm.valueDeinit(&old_fn, allocator);
    }

    // Store the watch function in the watches map.
    const entry: AgentWatchEntry = .{ .fn_val = cloned_fn };
    try data.watches.put(allocator, try allocator.dupe(u8, key_str), entry);

    return vm.agentValueShared(data);
}

// ============================================================
// (remove-watch agent key)
// Remove a watch function from the agent.
// Returns the agent.
// ============================================================

pub fn core_remove_watch(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 2) return error.ArityError;

    const agent_val = args.items[0];
    if (std.meta.activeTag(agent_val) != .agent) return error.TypeError;
    const data = agent_val.agent;

    // Second argument must be a keyword (the watch key).
    const key_val = args.items[1];
    if (std.meta.activeTag(key_val) != .keyword) return error.TypeError;
    const key_str = key_val.keyword.slice();

    // Lock the agent mutex.
    data.acquire();
    defer data.release();

    // Remove the watch entry if it exists.
    if (data.watches.get(key_str)) |old_entry| {
        var old_fn = old_entry.fn_val;
        vm.valueDeinit(&old_fn, allocator);
        _ = data.watches.remove(key_str);
    }

    return vm.agentValueShared(data);
}

// ============================================================
// Call all registered watch functions with (key agent old-value new-value).
// Called from the worker thread after a successful action.
// ============================================================

fn fireWatches(
    data: *vm.AgentData,
    allocator: Allocator,
    old_value: Value,
    new_value: Value,
) void {
    const agent_shared = vm.agentValueShared(data);

    var it = data.watches.iterator();
    while (it.next()) |entry| {
        const key_str = entry.key_ptr.*;
        const watch_fn = entry.value_ptr.fn_val;

        // Create the key keyword value for the watch call.
        const key_kw = vm.keywordValue(allocator, key_str) catch continue;
        const old_val_clone = vm.clone(&old_value, allocator) catch continue;
        const new_val_clone = vm.clone(&new_value, allocator) catch continue;

        // Build arguments: (key agent old-value new-value)
        var call_args: list.List = .empty;
        errdefer call_args.deinit(allocator);
        call_args.append(allocator, key_kw) catch continue;
        call_args.append(allocator, agent_shared) catch continue;
        call_args.append(allocator, old_val_clone) catch continue;
        call_args.append(allocator, new_val_clone) catch continue;

        // Clone the watch function's env for evaluation.
        const fn_data = watch_fn.function;
        var child_env = fn_data.env.clone(allocator) catch continue;
        defer child_env.deinit(allocator);

        const root_frame = eval.createRootFrame(allocator, &child_env) catch continue;
        defer root_frame.deinit(allocator);

        const saved_trampoline = eval.trampoline_allowed;
        eval.trampoline_allowed = false;
        defer eval.trampoline_allowed = saved_trampoline;

        // Call the watch function (best-effort, errors are ignored).
        _ = eval.call(allocator, &watch_fn, &call_args, root_frame, 0) catch {
            // Clean up args on error
            var ai: usize = 0;
            while (ai < call_args.items.len) : (ai += 1) {
                var arg = call_args.items[ai];
                vm.valueDeinit(&arg, allocator);
            }
            call_args.deinit(allocator);
            continue;
        };

        // Clean up cloned values.
        var ai: usize = 0;
        while (ai < call_args.items.len) : (ai += 1) {
            var arg = call_args.items[ai];
            vm.valueDeinit(&arg, allocator);
        }
        call_args.deinit(allocator);
    }
}

// ============================================================
// (shutdown-agents)
// Shut down all agent thread pools. No new actions will be processed.
// Already-running actions will complete. Idempotent — safe to call multiple times.
// Returns nil.
// ============================================================

pub fn core_shutdown_agents(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = args;
    _ = env;

    // Set shutdown flags on both pools. This prevents any new threads from being
    // spawned for send or send-off actions. Already-running action threads will
    // complete naturally. Calling this multiple times is safe (idempotent).
    send_pool_shutdown = true;
    send_off_pool_shutdown = true;
    send_pool_initialized = false;
    send_off_pool_initialized = false;

    return vm.nilValue();
}

// ============================================================
// Registration
// ============================================================

pub fn registerAgentFunctions(env: *Env) anyerror!void {
    // Initialize thread pools
    initSendThreadPool(0);
    initSendOffThreadPool(2); // send-off uses a small fixed pool (2 threads)

    try env.put("agent", vm.builtinFnValue(core_agent));
    try env.put("agent?", vm.builtinFnValue(core_agent_q));
    try env.put("send", vm.builtinFnValue(core_send));
    try env.put("send-off", vm.builtinFnValue(core_send_off));
    try env.put("await", vm.builtinFnValue(core_await));
    try env.put("await-for", vm.builtinFnValue(core_await_for));
    try env.put("agent-error", vm.builtinFnValue(core_agent_error));
    try env.put("agent-errors", vm.builtinFnValue(core_agent_errors));
    try env.put("error-mode", vm.builtinFnValue(core_error_mode));
    try env.put("error-handler", vm.builtinFnValue(core_error_handler));
    try env.put("set-error-mode!", vm.builtinFnValue(core_set_error_mode_bang));
    try env.put("set-error-handler!", vm.builtinFnValue(core_set_error_handler_bang));
    try env.put("clear-agent-errors", vm.builtinFnValue(core_clear_agent_errors));
    try env.put("restart-agent", vm.builtinFnValue(core_restart_agent));
    try env.put("set-validator!", vm.builtinFnValue(core_set_validator_bang));
    try env.put("get-validator", vm.builtinFnValue(core_get_validator));
    try env.put("add-watch", vm.builtinFnValue(core_add_watch));
    try env.put("remove-watch", vm.builtinFnValue(core_remove_watch));
    try env.put("shutdown-agents", vm.builtinFnValue(core_shutdown_agents));
}

// ===== Unit Tests =====

const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "agents::agent: creates agent with initial value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_agent(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .agent);
    try std.testing.expectEqual(vm.Type.integer, std.meta.activeTag(result.agent.value));
    try std.testing.expectEqual(@as(i64, 42), result.agent.value.integer);
}

test "agents::agent_q: returns true for agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var agent_val = try vm.agentValue(std.heap.page_allocator, vm.intValue(1));
    defer vm.valueDeinit(&agent_val, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_agent_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "agents::agent_q: returns false for non-agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_agent_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "agents::agent: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_agent(testSelf(), &args, &a));
}

test "agents::agent_q: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_agent_q(testSelf(), &args, &a));
}

test "agents::send: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_send(testSelf(), &args, &a));
}

test "agents::send: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42), vm.intValue(0) });
    try std.testing.expectError(error.TypeError, core_send(testSelf(), &args, &a));
}

test "agents::send: queues action on agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    // Create an agent with initial value 0
    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Manually queue an action (simulating what core_send does)
    // to test the queue structure without triggering the worker thread.
    const fn_val = vm.builtinFnValue(core_agent_q);
    var cloned_fn = try vm.clone(&fn_val, allocator);
    defer vm.valueDeinit(&cloned_fn, allocator);

    const action: vm.AgentAction = .{
        .fn_val = cloned_fn,
        .args = .empty,
    };
    try data.action_queue.append(allocator, action);
    data.action_count += 1;

    // Action should be queued
    try std.testing.expectEqual(@as(usize, 1), data.action_queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), data.action_count);
}

test "agents::send: queues action with extra args" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Manually queue an action with extra args
    var cloned_fn = try vm.clone(&vm.builtinFnValue(core_agent_q), allocator);
    defer vm.valueDeinit(&cloned_fn, allocator);

    var extra_args: std.ArrayListUnmanaged(Value) = .empty;
    defer extra_args.deinit(allocator);
    try extra_args.append(allocator, vm.intValue(10));
    try extra_args.append(allocator, vm.intValue(20));

    const action: vm.AgentAction = .{
        .fn_val = cloned_fn,
        .args = extra_args,
    };
    try data.action_queue.append(allocator, action);
    data.action_count += 1;

    try std.testing.expectEqual(@as(usize, 1), data.action_queue.items.len);
    try std.testing.expectEqual(@as(usize, 2), data.action_queue.items[0].args.items.len);
}

test "agents::send: queues action on failed agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Mark agent as failed
    data.failed = true;

    const fn_val = vm.builtinFnValue(core_agent_q);
    const args = makeArgs(&[_]Value{ agent_val, fn_val });

    // Sending to a failed agent should still queue the action (not throw)
    _ = try core_send(testSelf(), &args, &a);
    try std.testing.expect(data.action_queue.items.len == 1);
}

test "agents::send_off: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_send_off(testSelf(), &args, &a));
}

test "agents::send_off: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42), vm.intValue(0) });
    try std.testing.expectError(error.TypeError, core_send_off(testSelf(), &args, &a));
}

test "agents::send_off: queues action on agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    // Create an agent with initial value 0
    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Manually queue an action (simulating what core_send_off does)
    // to test the queue structure without triggering the worker thread.
    const fn_val = vm.builtinFnValue(core_agent_q);
    var cloned_fn = try vm.clone(&fn_val, allocator);
    defer vm.valueDeinit(&cloned_fn, allocator);

    const action: vm.AgentAction = .{
        .fn_val = cloned_fn,
        .args = .empty,
    };
    try data.action_queue.append(allocator, action);
    data.action_count += 1;

    // Action should be queued
    try std.testing.expectEqual(@as(usize, 1), data.action_queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), data.action_count);
}

test "agents::send_off: queues action on failed agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Mark agent as failed
    data.failed = true;

    const fn_val = vm.builtinFnValue(core_agent_q);
    const args = makeArgs(&[_]Value{ agent_val, fn_val });

    // Sending to a failed agent should still queue the action (not throw)
    _ = try core_send_off(testSelf(), &args, &a);
    try std.testing.expect(data.action_queue.items.len == 1);
}

test "agents::await: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_await(testSelf(), &args, &a));
}

test "agents::await: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_await(testSelf(), &args, &a));
}

test "agents::await: returns nil for agent with no pending actions" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_await(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "agents::await: returns nil for multiple agents with no pending actions" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent1 = try vm.agentValue(allocator, vm.intValue(1));
    defer vm.valueDeinit(&agent1, allocator);
    var agent2 = try vm.agentValue(allocator, vm.intValue(2));
    defer vm.valueDeinit(&agent2, allocator);

    const args = makeArgs(&[_]Value{ agent1, agent2 });
    var result = core_await(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "agents::await_for: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    // Need at least 2 args: timeout + one agent
    const args = makeArgs(&[_]Value{ vm.intValue(1000) });
    try std.testing.expectError(error.ArityError, core_await_for(testSelf(), &args, &a));
}

test "agents::await_for: wrong timeout type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var agent_val = try vm.agentValue(std.heap.page_allocator, vm.intValue(1));
    defer vm.valueDeinit(&agent_val, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.stringValue(std.heap.page_allocator, "not_a_number") catch unreachable, agent_val });
    try std.testing.expectError(error.TypeError, core_await_for(testSelf(), &args, &a));
}

test "agents::await_for: negative timeout returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var agent_val = try vm.agentValue(std.heap.page_allocator, vm.intValue(1));
    defer vm.valueDeinit(&agent_val, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-1), agent_val });
    try std.testing.expectError(error.TypeError, core_await_for(testSelf(), &args, &a));
}

test "agents::await_for: wrong agent type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1000), vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_await_for(testSelf(), &args, &a));
}

test "agents::await_for: returns true for agent with no pending actions" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ vm.intValue(2000), agent_val });
    var result = core_await_for(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bool);
    try std.testing.expect(result.bool == true);
}

test "agents::await_for: returns false on timeout with pending action" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Set action_count > 0 to simulate pending actions
    data.action_count = 1;

    // Use a very short timeout so it returns false quickly
    const args = makeArgs(&[_]Value{ vm.intValue(1), agent_val });
    var result = core_await_for(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bool);
    try std.testing.expect(result.bool == false);

    // Reset action_count for cleanup
    data.action_count = 0;
}

test "agents::agent_error: returns nil when no error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_agent_error(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "agents::agent_error: returns error when set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Manually set an error value
    const err_val = try vm.stringValue(allocator, "test error");
    data.agent_error = err_val;

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_agent_error(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .string);
    try std.testing.expect(std.mem.eql(u8, result.string.slice(), "test error"));
}

test "agents::agent_error: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_agent_error(testSelf(), &args, &a));
}

test "agents::agent_error: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_agent_error(testSelf(), &args, &a));
}

test "agents::agent_errors: returns empty vector when no errors" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_agent_errors(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .vector);
    try std.testing.expectEqual(@as(usize, 0), result.vector.items.items.len);
}

test "agents::agent_errors: returns errors vector" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Manually add some error values to the errors list
    const err1 = try vm.stringValue(allocator, "error 1");
    const err2 = try vm.stringValue(allocator, "error 2");
    try data.agent_errors_list.append(allocator, err1);
    try data.agent_errors_list.append(allocator, err2);

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_agent_errors(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .vector);
    try std.testing.expectEqual(@as(usize, 2), result.vector.items.items.len);
    try std.testing.expect(std.meta.activeTag(result.vector.items.items[0]) == .string);
    try std.testing.expect(std.mem.eql(u8, result.vector.items.items[0].string.slice(), "error 1"));
    try std.testing.expect(std.mem.eql(u8, result.vector.items.items[1].string.slice(), "error 2"));
}

test "agents::agent_errors: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_agent_errors(testSelf(), &args, &a));
}

test "agents::agent_errors: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_agent_errors(testSelf(), &args, &a));
}

test "agents::error_mode: returns :fail by default" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_error_mode(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.keyword.slice(), "fail"));
}

test "agents::error_mode: returns :continue when set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;
    data.error_mode = .continue_;

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_error_mode(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.keyword.slice(), "continue"));
}

test "agents::error_mode: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_error_mode(testSelf(), &args, &a));
}

test "agents::error_mode: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_error_mode(testSelf(), &args, &a));
}

test "agents::error_handler: returns nil when none set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_error_handler(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "agents::error_handler: returns handler when set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Set an error handler (a builtin function as a simple handler)
    const handler = vm.builtinFnValue(core_agent_q);
    data.error_handler = handler;

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_error_handler(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .builtin_fn);
}

test "agents::error_handler: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_error_handler(testSelf(), &args, &a));
}

test "agents::error_handler: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_error_handler(testSelf(), &args, &a));
}

test "agents::set_error_mode_bang: sets mode to :continue" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;
    // Default is :fail
    try std.testing.expectEqual(vm.AgentErrorMode.fail, data.error_mode);

    const continue_kw = try vm.keywordValue(allocator, "continue");
    const args = makeArgs(&[_]Value{ agent_val, continue_kw });
    var result = core_set_error_mode_bang(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    // Returns the agent
    try std.testing.expect(std.meta.activeTag(result) == .agent);
    // Mode is now :continue
    try std.testing.expectEqual(vm.AgentErrorMode.continue_, data.error_mode);
}

test "agents::set_error_mode_bang: sets mode to :fail" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;
    data.error_mode = .continue_;

    const fail_kw = try vm.keywordValue(allocator, "fail");
    const args = makeArgs(&[_]Value{ agent_val, fail_kw });
    var result = core_set_error_mode_bang(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    try std.testing.expect(std.meta.activeTag(result) == .agent);
    try std.testing.expectEqual(vm.AgentErrorMode.fail, data.error_mode);
}

test "agents::set_error_mode_bang: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_set_error_mode_bang(testSelf(), &args, &a));
}

test "agents::set_error_mode_bang: wrong agent type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const continue_kw = try vm.keywordValue(std.heap.page_allocator, "continue");
    const args = makeArgs(&[_]Value{ vm.intValue(42), continue_kw });
    try std.testing.expectError(error.TypeError, core_set_error_mode_bang(testSelf(), &args, &a));
}

test "agents::set_error_mode_bang: wrong mode type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;
    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const args = makeArgs(&[_]Value{ agent_val, vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_set_error_mode_bang(testSelf(), &args, &a));
}

test "agents::set_error_handler_bang: sets handler" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;
    // Default is null
    try std.testing.expect(data.error_handler == null);

    const handler = vm.builtinFnValue(core_agent_q);
    const args = makeArgs(&[_]Value{ agent_val, handler });
    var result = core_set_error_handler_bang(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    // Returns nil
    try std.testing.expect(std.meta.activeTag(result) == .nil);
    // Handler is now set
    try std.testing.expect(data.error_handler != null);
}

test "agents::set_error_handler_bang: nil removes handler" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // First set a handler
    const handler = vm.builtinFnValue(core_agent_q);
    data.error_handler = handler;
    try std.testing.expect(data.error_handler != null);

    // Now remove it with nil
    const args = makeArgs(&[_]Value{ agent_val, vm.nilValue() });
    var result = core_set_error_handler_bang(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    try std.testing.expect(std.meta.activeTag(result) == .nil);
    try std.testing.expect(data.error_handler == null);
}

test "agents::set_error_handler_bang: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_set_error_handler_bang(testSelf(), &args, &a));
}

test "agents::set_error_handler_bang: wrong agent type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42), vm.nilValue() });
    try std.testing.expectError(error.TypeError, core_set_error_handler_bang(testSelf(), &args, &a));
}

test "agents::clear_agent_errors: clears error and failed flag" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Set up error state
    const err_val = try vm.stringValue(allocator, "test error");
    data.agent_error = err_val;
    try data.agent_errors_list.append(allocator, try vm.stringValue(allocator, "error 1"));
    try data.agent_errors_list.append(allocator, try vm.stringValue(allocator, "error 2"));
    data.failed = true;

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_clear_agent_errors(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    // Returns the agent
    try std.testing.expect(std.meta.activeTag(result) == .agent);
    // Error cleared
    try std.testing.expect(data.agent_error == null);
    // Errors list cleared
    try std.testing.expectEqual(@as(usize, 0), data.agent_errors_list.items.len);
    // Failed flag reset
    try std.testing.expectEqual(false, data.failed);
}

test "agents::clear_agent_errors: works on clean agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Agent starts clean
    try std.testing.expect(data.agent_error == null);
    try std.testing.expectEqual(@as(usize, 0), data.agent_errors_list.items.len);
    try std.testing.expectEqual(false, data.failed);

    const args = makeArgs(&[_]Value{ agent_val });
    var result = core_clear_agent_errors(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    try std.testing.expect(std.meta.activeTag(result) == .agent);
    // Still clean after clearing
    try std.testing.expect(data.agent_error == null);
    try std.testing.expectEqual(@as(usize, 0), data.agent_errors_list.items.len);
    try std.testing.expectEqual(false, data.failed);
}

test "agents::clear_agent_errors: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_clear_agent_errors(testSelf(), &args, &a));
}

test "agents::clear_agent_errors: wrong type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_clear_agent_errors(testSelf(), &args, &a));
}

test "agents::restart_agent: resets value and clears errors" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Set up error state
    const err_val = try vm.stringValue(allocator, "test error");
    data.agent_error = err_val;
    try data.agent_errors_list.append(allocator, try vm.stringValue(allocator, "error 1"));
    data.failed = true;

    // Restart with new value 100
    const new_val = vm.intValue(100);
    const args = makeArgs(&[_]Value{ agent_val, new_val });
    var result = core_restart_agent(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    // Returns the agent
    try std.testing.expect(std.meta.activeTag(result) == .agent);
    // Value is updated
    try std.testing.expectEqual(vm.Type.integer, std.meta.activeTag(data.value));
    try std.testing.expectEqual(@as(i64, 100), data.value.integer);
    // Error cleared
    try std.testing.expect(data.agent_error == null);
    // Errors list cleared
    try std.testing.expectEqual(@as(usize, 0), data.agent_errors_list.items.len);
    // Failed flag reset
    try std.testing.expectEqual(false, data.failed);
}

test "agents::restart_agent: with clear-actions true clears action queue" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Queue a pending action
    const fn_val = vm.builtinFnValue(core_agent_q);
    const cloned_fn = try vm.clone(&fn_val, allocator);
    const action: vm.AgentAction = .{
        .fn_val = cloned_fn,
        .args = .empty,
    };
    try data.action_queue.append(allocator, action);
    data.action_count = 1;
    data.failed = true;

    // Restart with clear-actions true
    const new_val = vm.intValue(10);
    const clear_kw = try vm.keywordValue(allocator, "clear-actions");
    const args = makeArgs(&[_]Value{ agent_val, new_val, clear_kw, vm.boolValue(true) });
    var result = core_restart_agent(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    try std.testing.expect(std.meta.activeTag(result) == .agent);
    // Action queue cleared
    try std.testing.expectEqual(@as(usize, 0), data.action_queue.items.len);
    // Action count reset
    try std.testing.expectEqual(@as(usize, 0), data.action_count);
    // Failed flag reset
    try std.testing.expectEqual(false, data.failed);
}

test "agents::restart_agent: without clear-actions keeps action queue" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Queue a pending action
    const fn_val = vm.builtinFnValue(core_agent_q);
    const cloned_fn = try vm.clone(&fn_val, allocator);
    const action: vm.AgentAction = .{
        .fn_val = cloned_fn,
        .args = .empty,
    };
    try data.action_queue.append(allocator, action);
    data.action_count = 1;
    data.failed = true;

    // Restart without clear-actions (default: false)
    const new_val = vm.intValue(10);
    const args = makeArgs(&[_]Value{ agent_val, new_val });
    var result = core_restart_agent(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    try std.testing.expect(std.meta.activeTag(result) == .agent);
    // Action queue should still have the action (not cleared)
    try std.testing.expectEqual(@as(usize, 1), data.action_queue.items.len);
    // Failed flag reset
    try std.testing.expectEqual(false, data.failed);
    // Clean up the remaining action
    cleanupAction(&data.action_queue.items[0], allocator);
    data.action_queue.deinit(allocator);
    data.action_queue = .empty;
}

test "agents::restart_agent: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_restart_agent(testSelf(), &args, &a));
}

test "agents::restart_agent: wrong agent type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42), vm.intValue(10) });
    try std.testing.expectError(error.TypeError, core_restart_agent(testSelf(), &args, &a));
}

test "agents::restart_agent: works on clean agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Agent starts clean
    try std.testing.expect(data.agent_error == null);
    try std.testing.expectEqual(false, data.failed);

    // Restart with new value
    const new_val = vm.intValue(999);
    const args = makeArgs(&[_]Value{ agent_val, new_val });
    var result = core_restart_agent(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    try std.testing.expect(std.meta.activeTag(result) == .agent);
    try std.testing.expectEqual(vm.Type.integer, std.meta.activeTag(data.value));
    try std.testing.expectEqual(@as(i64, 999), data.value.integer);
}

test "agents::set_validator_bang: nil removes validator" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(42));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Set a validator directly (simulating it was set via agent creation)
    const validator = vm.builtinFnValue(core_agent_q);
    data.validator = validator;
    try std.testing.expect(data.validator != null);

    // Now remove it with nil
    const agent_arg = vm.agentValueShared(data);
    const args = makeArgs(&[_]Value{ agent_arg, vm.nilValue() });
    var result = core_set_validator_bang(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, allocator);

    try std.testing.expect(std.meta.activeTag(result) == .nil);
    try std.testing.expect(data.validator == null);
}

test "agents::set_validator_bang: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_set_validator_bang(testSelf(), &args, &a));
}

test "agents::set_validator_bang: wrong agent type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42), vm.nilValue() });
    try std.testing.expectError(error.TypeError, core_set_validator_bang(testSelf(), &args, &a));
}

test "agents::add_watch: adds watch to agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    const key = try vm.keywordValue(allocator, "test");
    const watch_fn = vm.builtinFnValue(core_agent_q);
    const args = makeArgs(&[_]Value{ agent_val, key, watch_fn });

    var result = try core_add_watch(testSelf(), &args, &a);
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .agent);
    try std.testing.expectEqual(@as(usize, 1), data.watches.count());
}

test "agents::add_watch: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_add_watch(testSelf(), &args, &a));
}

test "agents::add_watch: wrong agent type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const key = vm.keywordValue(a.allocator, "test") catch unreachable;
    const args = makeArgs(&[_]Value{ vm.intValue(42), key, vm.builtinFnValue(core_agent_q) });
    try std.testing.expectError(error.TypeError, core_add_watch(testSelf(), &args, &a));
}

test "agents::add_watch: wrong key type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ agent_val, vm.intValue(42), vm.builtinFnValue(core_agent_q) });
    try std.testing.expectError(error.TypeError, core_add_watch(testSelf(), &args, &a));
}

test "agents::remove_watch: removes watch from agent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // First add a watch
    const key = try vm.keywordValue(allocator, "test");
    const watch_fn = vm.builtinFnValue(core_agent_q);
    var add_args = makeArgs(&[_]Value{ agent_val, key, watch_fn });
    var add_result = try core_add_watch(testSelf(), &add_args, &a);
    defer vm.valueDeinit(&add_result, allocator);
    try std.testing.expectEqual(@as(usize, 1), data.watches.count());

    // Now remove it
    const rm_args = makeArgs(&[_]Value{ agent_val, key });
    var rm_result = try core_remove_watch(testSelf(), &rm_args, &a);
    defer vm.valueDeinit(&rm_result, allocator);
    try std.testing.expect(std.meta.activeTag(rm_result) == .agent);
    try std.testing.expectEqual(@as(usize, 0), data.watches.count());
}

test "agents::remove_watch: wrong arity returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    try std.testing.expectError(error.ArityError, core_remove_watch(testSelf(), &args, &a));
}

test "agents::remove_watch: wrong agent type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const key = vm.keywordValue(a.allocator, "test") catch unreachable;
    const args = makeArgs(&[_]Value{ vm.intValue(42), key });
    try std.testing.expectError(error.TypeError, core_remove_watch(testSelf(), &args, &a));
}

test "agents::remove_watch: wrong key type returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);

    const args = makeArgs(&[_]Value{ agent_val, vm.intValue(42) });
    try std.testing.expectError(error.TypeError, core_remove_watch(testSelf(), &args, &a));
}

test "agents::remove_watch: removing non-existent watch is safe" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // Remove a watch that doesn't exist
    const key = try vm.keywordValue(allocator, "nonexistent");
    const args = makeArgs(&[_]Value{ agent_val, key });
    var result = try core_remove_watch(testSelf(), &args, &a);
    defer vm.valueDeinit(&result, allocator);
    try std.testing.expect(std.meta.activeTag(result) == .agent);
    try std.testing.expectEqual(@as(usize, 0), data.watches.count());
}

test "agents::shutdown_agents: returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);

    // Ensure clean state for this test
    send_pool_shutdown = false;
    send_off_pool_shutdown = false;
    send_pool_initialized = true;
    send_off_pool_initialized = true;
    defer {
        // Restore state for other tests
        send_pool_shutdown = false;
        send_off_pool_shutdown = false;
        send_pool_initialized = true;
        send_off_pool_initialized = true;
    }

    const args = makeArgs(&[_]Value{});
    var result = core_shutdown_agents(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
    try std.testing.expect(send_pool_shutdown == true);
    try std.testing.expect(send_off_pool_shutdown == true);
}

test "agents::shutdown_agents: idempotent" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);

    // Ensure clean state
    send_pool_shutdown = false;
    send_off_pool_shutdown = false;
    send_pool_initialized = true;
    send_off_pool_initialized = true;
    defer {
        send_pool_shutdown = false;
        send_off_pool_shutdown = false;
        send_pool_initialized = true;
        send_off_pool_initialized = true;
    }

    // Call shutdown twice — should not error
    const args = makeArgs(&[_]Value{});
    var result1 = core_shutdown_agents(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result1, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result1) == .nil);

    var result2 = core_shutdown_agents(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result2, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result2) == .nil);
}

test "agents::shutdown_agents: prevents new sends" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const allocator = std.heap.page_allocator;

    // Ensure clean state
    send_pool_shutdown = false;
    send_off_pool_shutdown = false;
    send_pool_initialized = true;
    send_off_pool_initialized = true;
    defer {
        send_pool_shutdown = false;
        send_off_pool_shutdown = false;
        send_pool_initialized = true;
        send_off_pool_initialized = true;
    }

    // Shutdown the pools
    const empty_args = makeArgs(&[_]Value{});
    var shutdown_result = core_shutdown_agents(testSelf(), &empty_args, &a) catch unreachable;
    defer vm.valueDeinit(&shutdown_result, allocator);

    // After shutdown, enqueueAgent should not spawn threads
    var agent_val = try vm.agentValue(allocator, vm.intValue(0));
    defer vm.valueDeinit(&agent_val, allocator);
    const data = agent_val.agent;

    // enqueueAgent should be a no-op after shutdown
    enqueueAgent(data);
    // No thread should have been spawned (no crash, no action processed)
    try std.testing.expect(send_pool_shutdown == true);
}
