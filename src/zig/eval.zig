const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = vm.Env;
const phm = @import("persistent_hash_map.zig");
const parser = @import("parser.zig");
const eval_helpers = @import("namespaces/core/eval_helpers.zig");
const helpers = @import("namespaces/core/helpers.zig");
const sequences = @import("namespaces/core/sequences.zig");
const eval_thread = @import("eval_thread.zig");
const eval_try = @import("eval_try.zig");
const eval_macro = @import("eval_macro.zig");
const eval_ns = @import("eval_ns.zig");
const protocols = @import("namespaces/core/protocols.zig");
const records = @import("namespaces/core/records.zig");
const gc_mod = @import("gc.zig");
const threading = @import("namespaces/core/threading.zig");
const bytecode_mod = @import("bytecode.zig");
const eval_meta = @import("eval_meta.zig");
const eval_multi = @import("eval_multi.zig");
const ref_mod = @import("ref.zig");
const timeout_mod = @import("timeout.zig");

const Allocator = std.mem.Allocator;

// Debug: track allocValue calls
var debug_alloc_active: bool = false;
var debug_alloc_count: usize = 0;
var debug_alloc_limit: usize = 0;

pub fn debugAllocValueStart(limit: usize) void {
    debug_alloc_active = true;
    debug_alloc_count = 0;
    debug_alloc_limit = limit;
}
pub fn debugAllocValueStop() void {
    debug_alloc_active = false;
}

// Re-export SourceLoc from value.zig for backward compatibility
pub const SourceLoc = vm.SourceLoc;

/// Result of evalRec: either a Value (by copy) or a Trampoline marker.
/// Phase 1: Changed from *Value to Value — eliminates allocValue in every evalRec branch.
/// The single allocation happens at the boundary (evalRecV, eval return).
pub const EvalResult = union(enum) {
    value: Value,
    trampoline, // signals that a frame was pushed, caller should continue loop
};

/// Allocate a Value on the GC heap and initialize it from a stack Value.
pub fn allocValue(allocator: Allocator, val: Value) anyerror!*Value {
    if (debug_alloc_active) {
        if (debug_alloc_count < debug_alloc_limit) {
            const src = @src();
            std.debug.print("[ALLOC_VALUE #{d}] {s}:{d} type={s}\n",
                .{ debug_alloc_count + 1, src.file, src.line, @tagName(std.meta.activeTag(val)) });
            debug_alloc_count += 1;
        }
    }
    const ptr = try allocator.create(Value);
    ptr.* = val;
    return ptr;
}

/// Dereference and deinit a *Value, used for intermediate results that won't be returned.
/// In a GC system, we just null out the Value — the GC handles all cleanup.
pub fn deallocValue(allocator: Allocator, ptr: *Value) void {
    _ = allocator;
    ptr.* = vm.nilValue();  // Null out — GC will collect when unreachable
    // Don't destroy — GC manages the *Value memory too
}

/// Unified special form handler signature.
const SpecialFormFn = *const fn (Allocator, *const list.List, *vm.Frame, usize) anyerror!EvalResult;

/// Evaluation context for GC root tracking (Phase 5: Frame Lifecycle and Root Graph).
/// Tracks active frames so the GC's root_fn can mark them during collection.
/// This prevents active evaluation frames from being swept even when they're
/// detached from their parent's children list during trampoline processing.
pub const EvalContext = struct {
    root_frame: ?*vm.Frame = null,
    current_frame: ?*vm.Frame = null,
};

pub var eval_context: EvalContext = .{};

/// Evaluate a body slice directly without creating a temporary list Value.
/// Phase 2: The body is part of the function definition (immutable, permanently rooted).
/// Non-tail forms are evaluated synchronously; the last form is in tail position
/// (uses evalRec for trampoline support).
/// Handles both "do" bodies (from evalFn/evalDefn) and direct bodies (from partial/comp/fnil/juxt).
pub fn evalRecSlice(allocator: Allocator, items: []const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    // Skip leading "do" symbol if present (common case from evalFn/evalDefn).
    // Functions from partial/comp/fnil/juxt have bodies that ARE a single list form
    // (not wrapped in do) — the body items are the elements of that single form.
    const body_start: usize = if (items.len > 0 and
        std.meta.activeTag(items[0]) == .symbol and
        std.mem.eql(u8, items[0].symbol, "do"))
        1
    else
        0;
    const body_items = items[body_start..];

    if (body_items.len == 0) return .{ .value = vm.nilValue() };

    // For non-do bodies (partial/comp/fnil/juxt), the body_items are the elements
    // of a SINGLE list form. We need to wrap them back into a list Value and
    // evaluate that form. This is a rare case — the common "do" path below
    // evaluates body_items as a sequence of forms.
    if (body_start == 0) {
        // Wrap body_items into a stack-allocated list Value.
        // The body_items are permanently rooted (part of function definition),
        // so we just need a wrapper for evalRec to dispatch correctly.
        const mutable_items = @constCast(body_items);
        var list_data: vm.ListData = .{ .items = std.ArrayListUnmanaged(Value){ .items = mutable_items, .capacity = body_items.len }, .src_line = 0 };
        const body_list_val: Value = .{ .list = &list_data };
        return evalRec(allocator, &body_list_val, frame, depth);
    }

    // Common case: "do" body — evaluate body_items as a sequence of forms.
    // Phase 3: Non-tail forms use evalRecDirect (Value by copy, no *Value allocation)
    for (body_items[0 .. body_items.len - 1]) |form| {
        _ = try evalRecDirect(allocator, &form, frame, depth);
    }
    // Last form in tail position — use evalRec for trampoline support
    return evalRec(allocator, &body_items[body_items.len - 1], frame, depth);
}

// Phase 9: When false, callFunction evaluates body directly instead of trampolining.
// Used by evalRecV to prevent interference with the main eval loop.
// Thread-local to avoid race conditions when multiple futures evaluate concurrently.
pub threadlocal var trampoline_allowed: bool = true;

// Phase 3: Thread-local exception state for try/catch/throw.
// Each OS thread (including future threads) has independent exception state.
pub threadlocal var current_exception: ?*vm.ExceptionData = null;
pub threadlocal var exception_thrown: bool = false;

/// Clear the exception state (called after try/catch handles it)
pub fn clearException() void {
    current_exception = null;
    exception_thrown = false;
}

/// Check if an exception is currently in flight
pub fn hasException() bool {
    return exception_thrown;
}

/// Get the current exception data
pub fn getException() ?*vm.ExceptionData {
    return current_exception;
}

/// GC root callback for frame lifecycle (Phase 5/9).
/// Marks all active evaluation frames so they survive GC collection.
///
/// Called during GC collect() via the root_fn mechanism.
pub fn markFrameRoots(gc_inst: *gc_mod.GC, ctx: *gc_mod.ScanContext) void {
    // Mark root frame (entry point for the frame chain)
    if (eval_context.root_frame) |frame| {
        gc_inst.markRecursive(frame, ctx);
    }
    // Mark the current evaluation frame (set by callFunction for trampoline)
    if (eval_context.current_frame) |frame| {
        gc_inst.markRecursive(frame, ctx);
    }
    // Phase 3: Mark in-flight exception so GC doesn't sweep it between throw and catch
    if (current_exception) |ex| {
        gc_inst.markRecursive(ex, ctx);
    }
}

/// Dispatch table: static array of special form names → handler functions.
/// Linear search over ~42 entries is trivial and avoids any allocation.
const special_forms = [_]struct { name: []const u8, fn_ptr: SpecialFormFn }{
    .{ .name = "quit", .fn_ptr = evalQuit },
    .{ .name = "exit", .fn_ptr = evalQuit },
    .{ .name = "quote", .fn_ptr = evalQuote },
    .{ .name = "quasiquote", .fn_ptr = evalQuasiquote },
    .{ .name = "def", .fn_ptr = evalDef },
    .{ .name = "let", .fn_ptr = evalLet },
    .{ .name = "letfn", .fn_ptr = evalLetFn },
    .{ .name = "if", .fn_ptr = evalIf },
    .{ .name = "when", .fn_ptr = evalWhen },
    .{ .name = "cond", .fn_ptr = evalCond },
    .{ .name = "defn", .fn_ptr = evalDefn },
    .{ .name = "defn-", .fn_ptr = evalDefn },
    .{ .name = "fn", .fn_ptr = evalFn },
    .{ .name = "defmacro", .fn_ptr = evalDefmacro },
    .{ .name = "do", .fn_ptr = evalDo },
    .{ .name = "set!", .fn_ptr = evalSetBang },
    .{ .name = "recur", .fn_ptr = evalRecur },
    .{ .name = "loop", .fn_ptr = evalLoop },
    .{ .name = "var", .fn_ptr = evalVar },
    .{ .name = "deref", .fn_ptr = evalDeref },
    .{ .name = "@", .fn_ptr = evalDeref },
    .{ .name = "or", .fn_ptr = evalOr },
    .{ .name = "and", .fn_ptr = evalAnd },
    .{ .name = "binding", .fn_ptr = evalBinding },
    .{ .name = "lazy-seq", .fn_ptr = evalLazySeq },
    .{ .name = "dorun", .fn_ptr = evalDorun },
    .{ .name = "doall", .fn_ptr = evalDoall },
    .{ .name = "extend", .fn_ptr = evalExtend },
    .{ .name = "ns", .fn_ptr = evalNsForm },
    .{ .name = "in-ns", .fn_ptr = evalInNsForm },
    .{ .name = "defprotocol", .fn_ptr = evalDefprotocolForm },
    .{ .name = "extend-type", .fn_ptr = evalExtendTypeForm },
    .{ .name = "extend-protocol", .fn_ptr = evalExtendProtocolForm },
    .{ .name = "defrecord", .fn_ptr = evalDefrecordForm },
    .{ .name = "alter-meta!", .fn_ptr = eval_meta.evalAlterMetaBang },
    .{ .name = "->>", .fn_ptr = evalThreadLastForm },
    .{ .name = "->", .fn_ptr = evalThreadFirstForm },
    .{ .name = "cond->", .fn_ptr = evalCondThreadFirstForm },
    .{ .name = "cond->>", .fn_ptr = evalCondThreadLastForm },
    .{ .name = "case", .fn_ptr = evalCaseForm },
    .{ .name = "throw", .fn_ptr = evalThrow },
    .{ .name = "try", .fn_ptr = eval_try.evalTry },
    .{ .name = "dosync", .fn_ptr = ref_mod.evalDosync },
    .{ .name = "defmulti", .fn_ptr = eval_multi.evalDefmulti },
    .{ .name = "defmethod", .fn_ptr = eval_multi.evalDefmethod },
};

/// Look up a special form handler by name. Returns null if not a special form.
fn findSpecialForm(name: []const u8) ?SpecialFormFn {
    for (special_forms) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.fn_ptr;
        }
    }
    return null;
}

// Re-export findNsManager for use by main.zig and other modules
pub const findNsManager = eval_ns.findNsManager;

// Bind a symbol in the current namespace's env.
// If the env is the root env (has ns_manager), bind directly.
// Otherwise, bind in the current namespace's env.
pub fn bindInCurrentNamespace(env: *Env, name: []const u8, value: Value) anyerror!void {
    if (findNsManager(env)) |ns_mgr| {
        if (env.ns_manager != null) {
            try env.put(name, value);
            try env.markOwned(name);
        } else {
            const current_ns = ns_mgr.getCurrentNamespace();
            const ns_env = ns_mgr.getNamespace(current_ns) orelse env;
            try ns_env.put(name, value);
            try ns_env.markOwned(name);
        }
    } else {
        try env.put(name, value);
    }
}

pub const EvalError = error{
    UndefinedSymbol,
    NotCallable,
    TypeError,
    ArityError,
    RecursionLimit,
    ReplExit,
    Recur, // internal: used by recur to signal loop/fn tail call
    Exception, // A Clojure exception was thrown and needs to propagate
};

const MAX_RECURSION = 1000000;

/// Extract the function name from a body form (typically a (do ...) list).
/// Returns the symbol name or "<anonymous>" if not available.
fn extractFnName(body: *const Value) []const u8 {
    // The body is typically a list like (do body...)
    // We look for the function name in the environment or use the body form
    if (std.meta.activeTag(body.*) == .list) {
        const items = body.*.list.items.items;
        if (items.len > 0 and std.meta.activeTag(items[0]) == .symbol) {
            const sym = items[0].symbol;
            // Skip "do" and internal markers
            if (!std.mem.eql(u8, sym, "do") and
                !std.mem.eql(u8, sym, "__protocol_dispatch__"))
            {
                return sym;
            }
        }
    }
    return "<anonymous>";
}

/// Format a user-friendly error message with source location and stack trace.
///
fn formatEvalError(allocator: Allocator, err: anyerror, file: []const u8, form: *const Value) ![]const u8 {
    const err_name = @errorName(err);
    var msg: std.ArrayList(u8) = .empty;
    errdefer msg.deinit(allocator);

    // Get source line from the form if it's a list
    var src_line: usize = 0;
    if (std.meta.activeTag(form.*) == .list) {
        src_line = form.*.list.src_line;
    }

    // Print the error with source location
    if (src_line > 0) {
        try msg.appendSlice(allocator, "Runtime error at ");
        try msg.appendSlice(allocator, file);
        try msg.appendSlice(allocator, ":");
        var line_buf: [20]u8 = undefined;
        try msg.appendSlice(allocator, std.fmt.bufPrint(&line_buf, "{d}", .{src_line}) catch "?");
        try msg.appendSlice(allocator, ": ");
        try msg.appendSlice(allocator, err_name);
    } else {
        try msg.appendSlice(allocator, "Runtime error: ");
        try msg.appendSlice(allocator, err_name);
    }

    // Add stack trace from Frame chain (Phase 9)
    if (eval_context.current_frame) |top_frame| {
        var frames: std.ArrayListUnmanaged(*vm.Frame) = .empty;
        errdefer frames.deinit(allocator);
        var current: ?*vm.Frame = eval_context.root_frame;
        while (current) |frame| : (current = frame.parent) {
            if (frame.function_ref != null or frame.body_form_items != null) {
                try frames.append(allocator, frame);
            }
        }
        if (frames.items.len > 0) {
            const last = frames.items[frames.items.len - 1];
            if (last != top_frame) try frames.append(allocator, top_frame);
        }
        if (frames.items.len > 0) {
            try msg.appendSlice(allocator, "\n\nStack trace:");
            var i: usize = 0;
            while (i < frames.items.len) : (i += 1) {
                const frame = frames.items[i];
                const fn_name = if (frame.function_ref) |ref| extractFnNameFromValue(&ref) else "<frame>";
                const loc = frame.src_loc;
                try msg.appendSlice(allocator, "\n  at ");
                try msg.appendSlice(allocator, fn_name);
                if (loc.line > 0) {
                    var loc_buf: [20]u8 = undefined;
                    try msg.appendSlice(allocator, " (at ");
                    if (loc.file.len > 0) {
                        try msg.appendSlice(allocator, loc.file);
                        try msg.appendSlice(allocator, ":");
                    }
                    try msg.appendSlice(allocator, std.fmt.bufPrint(&loc_buf, "{d}", .{loc.line}) catch "?");
                    try msg.appendSlice(allocator, ")");
                }
            }
        }
    }

    return msg.toOwnedSlice(allocator);
}

/// Extract function name from a Value for stack traces.
fn extractFnNameFromValue(val: *const Value) []const u8 {
    if (std.meta.activeTag(val.*) == .function) {
        const fn_data = val.*.function;
        if (fn_data.name) |name| return name;
    }
    return "<anonymous>";
}

/// Format an uncaught Clojure exception for display.
/// Phase 4: Used when throw propagates past all try/catch handlers.
fn formatExceptionError(allocator: Allocator, ex: *vm.ExceptionData, file: []const u8) ![]const u8 {
    var msg: std.ArrayList(u8) = .empty;
    errdefer msg.deinit(allocator);

    try msg.appendSlice(allocator, "Exception ");
    try msg.appendSlice(allocator, ex.type_kw);
    try msg.appendSlice(allocator, ": ");
    if (ex.message.len > 0) {
        try msg.appendSlice(allocator, ex.message);
    }

    // Add source location if available
    if (file.len > 0) {
        try msg.appendSlice(allocator, " (at ");
        try msg.appendSlice(allocator, file);
        try msg.appendSlice(allocator, ")");
    }

    // Add stack trace from Frame chain
    if (eval_context.current_frame) |top_frame| {
        var frames: std.ArrayListUnmanaged(*vm.Frame) = .empty;
        errdefer frames.deinit(allocator);
        var current: ?*vm.Frame = eval_context.root_frame;
        while (current) |frame| : (current = frame.parent) {
            if (frame.function_ref != null or frame.body_form_items != null) {
                try frames.append(allocator, frame);
            }
        }
        if (frames.items.len > 0) {
            const last = frames.items[frames.items.len - 1];
            if (last != top_frame) try frames.append(allocator, top_frame);
        }
        if (frames.items.len > 0) {
            try msg.appendSlice(allocator, "\n\nStack trace:");
            var i: usize = 0;
            while (i < frames.items.len) : (i += 1) {
                const frame = frames.items[i];
                const fn_name = if (frame.function_ref) |ref| extractFnNameFromValue(&ref) else "<frame>";
                const loc = frame.src_loc;
                try msg.appendSlice(allocator, "\n  at ");
                try msg.appendSlice(allocator, fn_name);
                if (loc.line > 0) {
                    var loc_buf: [20]u8 = undefined;
                    try msg.appendSlice(allocator, " (at ");
                    if (loc.file.len > 0) {
                        try msg.appendSlice(allocator, loc.file);
                        try msg.appendSlice(allocator, ":");
                    }
                    try msg.appendSlice(allocator, std.fmt.bufPrint(&loc_buf, "{d}", .{loc.line}) catch "?");
                    try msg.appendSlice(allocator, ")");
                }
            }
        }
    }

    return msg.toOwnedSlice(allocator);
}

/// Main entry point for evaluation.
/// Uses trampolining: function body evaluations are pushed onto a heap stack
/// instead of recursing on the C stack. This enables unlimited Clojure recursion depth.
pub fn eval(allocator: Allocator, form: Value, env: *Env) anyerror!*Value {
    return evalWithFile(allocator, form, env, "");
}

/// Main entry point for evaluation with source file tracking.
pub fn evalWithFile(allocator: Allocator, form: Value, env: *Env, file: []const u8) anyerror!*Value {
    // Create root Frame from namespace Env
    const root_frame = try createRootFrame(allocator, env);
    defer root_frame.deinit(allocator);

    // Phase 5/9: Register evaluation context for GC root tracking.
    //
    eval_context.root_frame = root_frame;
    eval_context.current_frame = null;
    defer {
        eval_context.root_frame = null;
        eval_context.current_frame = null;
    }

    // Evaluate the initial form
    var result: ?EvalResult = evalRec(allocator, &form, root_frame, 0) catch |err| {
        // Don't format internal control errors like ReplExit
        if (err == EvalError.ReplExit) return err;
        // Phase 4: Handle uncaught Clojure exceptions
        if (err == EvalError.Exception) {
            if (current_exception) |ex| {
                const ex_msg = formatExceptionError(allocator, ex, file) catch {
                    clearException();
                    return err;
                };
                defer allocator.free(ex_msg);
                std.debug.print("{s}\n", .{ex_msg});
                clearException();
            }
            return err;
        }
        const msg = formatEvalError(allocator, err, file, &form) catch {
            return err;
        };
        defer allocator.free(msg);
        std.debug.print("{s}\n", .{msg});
        return err;
    };

    // Trampoline loop using Frame chain.
    // When callFunction creates a child Frame, it sets eval_context.current_frame.
    // We read current_frame to get the next frame to evaluate.
    while (true) {
        // Timeout check: abort if the watchdog has fired.
        if (timeout_mod.checkTimeout()) return timeout_mod.TimeoutExpired;

        const current = result orelse {
            return try allocValue(allocator, vm.nilValue());
        };

        switch (current) {
            .value => |v| return try allocValue(allocator, v),
            .trampoline => {},
        }

        // Get the child Frame set by callFunction
        const child_frame = eval_context.current_frame orelse {
            return try allocValue(allocator, vm.nilValue());
        };

        // Phase 2: Evaluate the child's body_form_items directly (no clone needed).
        const body_items = child_frame.body_form_items orelse {
            child_frame.detachFromParent();
            eval_context.current_frame = child_frame.parent;
            return try allocValue(allocator, vm.nilValue());
        };

        result = evalRecSlice(allocator, body_items, child_frame, 0) catch |err| {
            // Don't format internal control errors like ReplExit
            if (err == EvalError.ReplExit) {
                child_frame.detachFromParent();
                eval_context.current_frame = child_frame.parent;
                return err;
            }
            // Phase 4: Handle uncaught Clojure exceptions
            if (err == EvalError.Exception) {
                if (current_exception) |ex| {
                    const ex_msg = formatExceptionError(allocator, ex, file) catch {
                        child_frame.detachFromParent();
                        eval_context.current_frame = child_frame.parent;
                        clearException();
                        return err;
                    };
                    defer allocator.free(ex_msg);
                    std.debug.print("{s}\n", .{ex_msg});
                }
                child_frame.detachFromParent();
                eval_context.current_frame = child_frame.parent;
                clearException();
                return err;
            }
            // Use first body item for error reporting (or a nil placeholder if empty).
            // The source line is available from body_form_src_line.
            const err_form: Value = if (body_items.len > 0) body_items[0] else vm.nilValue();
            const msg = formatEvalError(allocator, err, file, &err_form) catch {
                child_frame.detachFromParent();
                eval_context.current_frame = child_frame.parent;
                return err;
            };
            defer allocator.free(msg);
            std.debug.print("{s}\n", .{msg});
            child_frame.detachFromParent();
            eval_context.current_frame = child_frame.parent;
            return err;
        };

        // Phase 4: Check if an exception was thrown during evaluation (trampoline)
        if (exception_thrown) {
            child_frame.detachFromParent();
            eval_context.current_frame = child_frame.parent;
            return EvalError.Exception;
        }

        // Clean up the frame based on result type.
        // If .trampoline: callFunction already set current_frame to the next child.
        //   Detach this frame but keep current_frame pointing to the child.
        // If .value: this frame is done. Set current_frame to parent.
        switch (result.?) {
            .trampoline => {
                child_frame.detachFromParent();
                // current_frame was already set by callFunction to the next child
            },
            .value => {
                const parent = child_frame.parent;
                child_frame.detachFromParent();
                eval_context.current_frame = parent;
            },
        }
    }
}

/// Wrapper: evalRec that extracts .value from EvalResult.
/// Phase 9: Disables trampolining to avoid interfering with the main eval loop.
/// callFunction evaluates body directly when trampoline_allowed is false.
pub fn evalRecV(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!*Value {
    // Disable trampolining: callFunction will evaluate body directly
    const saved_trampoline = trampoline_allowed;
    trampoline_allowed = false;
    defer trampoline_allowed = saved_trampoline;

    // With trampolining disabled, evalRec always returns .value
    const result = try evalRec(allocator, form, frame, depth);
    return switch (result) {
        // Phase 1: ONE allocation at the boundary — evalRec returns Value by copy
        .value => |v| try allocValue(allocator, v),
        .trampoline => unreachable, // should not happen with trampoline_allowed = false
    };
}

/// Phase 3: Evaluate a form, returning Value by copy — no *Value allocation.
/// Disables trampolining (like evalRecV) but returns Value directly.
/// Use this instead of evalRecV when the result is immediately consumed
/// (read as ptr.* and then valueDeinit'd), eliminating the boundary allocation.
pub fn evalRecDirect(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!Value {
    const saved_trampoline = trampoline_allowed;
    trampoline_allowed = false;
    defer trampoline_allowed = saved_trampoline;

    const result = try evalRec(allocator, form, frame, depth);
    return switch (result) {
        .value => |v| v,        // Value by copy — no allocation
        .trampoline => unreachable,
    };
}

/// Phase 3: Like evalRecDirect but creates a temporary root frame from an Env.
pub fn evalRecDirectWithEnv(allocator: Allocator, form: *const Value, env: *Env, depth: usize) anyerror!Value {
    const frame = try createRootFrame(allocator, env);
    defer frame.releaseFromParent(allocator);
    return evalRecDirect(allocator, form, frame, depth);
}

/// Internal recursive evaluator with trampoline support.
/// When a function body needs evaluation, returns .trampoline instead of recursing.
pub fn evalRec(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    switch (form.*) {
        // Phase 1: Literals — return by copy, no allocation. The form is AST (immutable, rooted).
        .nil, .bool, .integer, .float, .bigint, .ratio, .decimal, .string, .regex, .character, .keyword, .set, .queue, .chunk, .chunked_cons, .atom, .future, .promise, .reduced, .wrapped, .record, .exception, .ref, .multimethod => {
            return .{ .value = form.* };
        },
        .symbol => {
            if (std.mem.eql(u8, form.*.symbol, "quote") or
                std.mem.eql(u8, form.*.symbol, "quasiquote") or
                std.mem.eql(u8, form.*.symbol, "unquote") or
                std.mem.eql(u8, form.*.symbol, "unquote-splicing"))
            {
                return .{ .value = form.* };
            }
            // Handle qualified symbols: alias/name or namespace/name
            if (std.mem.indexOfScalar(u8, form.*.symbol, '/')) |slash_idx| {
                const alias = form.*.symbol[0..slash_idx];
                const name = form.*.symbol[slash_idx + 1 ..];
                const ns_mgr = findNsManager(frame.root_env) orelse {
                    const val2 = frame.get(form.*.symbol);
                    if (val2) |v| return .{ .value = v };
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
                    return error.UndefinedSymbol;
                };
                const current_ns = ns_mgr.getCurrentNamespace();
                const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
                const target_env = ns_mgr.getNamespace(target_ns) orelse {
                    const val3 = frame.get(form.*.symbol);
                    if (val3) |v| return .{ .value = v };
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
                    return error.UndefinedSymbol;
                };
                const val4 = target_env.get(name);
                if (val4) |v| return .{ .value = v };
                std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
                return error.UndefinedSymbol;
            }
            const val = frame.get(form.*.symbol);
            if (val) |v| return .{ .value = v };
            std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
            return error.UndefinedSymbol;
        },
        .list => {
            return try evalList(allocator, form, frame, depth);
        },
        .vector => {
            return try evalVector(allocator, form, frame, depth);
        },
        .map => {
            return try evalMap(allocator, form, frame, depth);
        },
        // Phase 1: Functions, builtins, lazy-seqs — return by copy, no allocation.
        .function, .builtin_fn => return .{ .value = form.* },
        .lazy_seq => return .{ .value = form.* },
        .cons => {
            return try evalCons(allocator, form, frame, depth);
        },
    }
    unreachable;
}

// Parse ([params] body...)+ pairs from a list slice.
// Returns an ArrayListUnmanaged(vm.Arity) and updates *idx to point past the last consumed item.
// Handles both flattened form: (fn [x] body) and wrapped form: (fn ([x] body))
fn parseArityForms(allocator: Allocator, items: []const Value, end: usize, idx: *usize) anyerror!std.ArrayListUnmanaged(vm.Arity) {
    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }

    while (idx.* < end) {
        const form = items[idx.*];
        idx.* += 1;

        var params_list: list.List = undefined;
        var body_forms: []const Value = undefined;

        if (std.meta.activeTag(form) == .vector) {
            // Flattened form: (fn [x] body1 body2 [y] body3)
            // params = [x], body = body1 body2
            params_list = try helpers.listFromVector(allocator, form.vector.items);

            // Collect body forms until next [params] or end.
            // Only vectors are valid param lists in flattened form.
            // (Lists like (greet) are function calls, not param lists.)
            const body_start = idx.*;
            while (idx.* < end) {
                const next = items[idx.*];
                if (std.meta.activeTag(next) == .vector and
                    looksLikeParamList(next) and
                    idx.* + 1 < end)
                {
                    break;
                }
                idx.* += 1;
            }
            body_forms = items[body_start..idx.*];
        } else if (std.meta.activeTag(form) == .list) {
            // Wrapped form: (fn ([x] body1 body2) ([y] body3))
            // Or: (fn (x y) body) from macro-generated code where (list x y) creates (x y)
            // Extract params and body from within the list
            if (form.list.items.items.len == 0) return error.TypeError;
            const inner_first = form.list.items.items[0];
            if (std.meta.activeTag(inner_first) == .vector) {
                // Standard: (fn ([x] body))
                params_list = try helpers.listFromVector(allocator, inner_first.vector.items);
                body_forms = form.list.items.items[1..];
            } else if (std.meta.activeTag(inner_first) == .list) {
                // Nested list params: (fn ((x y) body)) - treat inner list as params
                params_list = inner_first.list.items;
                body_forms = form.list.items.items[1..];
            } else {
                // Macro-generated: (fn (x) body) where (list x) created (x)
                // The entire list is the params form: (x) means params = [x]
                // Body forms come from the parent list after this form
                params_list = form.list.items;

                // Collect body forms from the parent list.
                // Only vectors are valid param list markers.
                const body_start = idx.*;
                while (idx.* < end) {
                    const next = items[idx.*];
                    if (std.meta.activeTag(next) == .vector and
                        looksLikeParamList(next) and
                        idx.* + 1 < end)
                    {
                        break;
                    }
                    idx.* += 1;
                }
                body_forms = items[body_start..idx.*];
            }
        } else {
            return error.TypeError;
        }

        // Wrap body in a do block
        var body_list: list.List = .empty;
        errdefer body_list.deinit(allocator);
        try body_list.append(allocator, try vm.symValue(allocator, "do"));
        for (body_forms) |form_item| {
            try body_list.append(allocator, try vm.shallowClone(&form_item, allocator));
        }

        // Parse params for variadic support (& rest)
        var parsed = try parseParams(allocator, params_list);
        defer {
            parsed.params.deinit(allocator);
            if (parsed.rest_name) |rn| allocator.free(rn);
        }

        const cloned_params = try list.clone(&parsed.params, allocator);
        const cloned_body = try list.clone(&body_list, allocator);
        const cloned_rest = if (parsed.rest_name) |rn| try allocator.dupe(u8, rn) else null;
        try arities.append(allocator, vm.Arity{
            .params = cloned_params,
            .body = cloned_body,
            .rest_name = cloned_rest,
        });
    }

    return arities;
}

// Result of parsing a parameter list (may include variadic rest parameter)
const ParsedParams = struct {
    params: list.List,      // regular parameters (without & symbol)
    rest_name: ?[]const u8, // name of rest parameter, or null
};

// Parse a parameter list, extracting regular params and optional rest param.
// E.g., [a b & rest] => { params: (a b), rest_name: "rest" }
// E.g., [& args]     => { params: (), rest_name: "args" }
// E.g., [a b]        => { params: (a b), rest_name: null }
fn parseParams(allocator: Allocator, params: list.List) anyerror!ParsedParams {
    var regular_params: list.List = .empty;
    errdefer regular_params.deinit(allocator);
    var rest_name: ?[]const u8 = null;

    var i: usize = 0;
    var found_amp = false;
    while (i < params.items.len) : (i += 1) {
        const item = params.items[i];
        if (!found_amp and std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.symbol, "&")) {
            found_amp = true;
            continue;
        }
        if (found_amp) {
            // The symbol after & is the rest parameter name
            if (std.meta.activeTag(item) != .symbol) return error.TypeError;
            rest_name = try allocator.dupe(u8, item.symbol);
            // No more params expected after rest
            break;
        } else {
            try regular_params.append(allocator, try vm.shallowClone(&item, allocator));
        }
    }

    return ParsedParams{
        .params = regular_params,
        .rest_name = rest_name,
    };
}

fn evalList(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const l = &form.*.list.items;
    // Phase 1: listValue returns Value by copy, no allocValue wrapper needed
    if (l.items.len == 0) return .{ .value = try vm.listValue(allocator, list.empty()) };

    const first = l.items[0];

    // Self-evaluating symbols (special forms) — dispatch via lookup table
    if (std.meta.activeTag(first) == .symbol) {
        if (findSpecialForm(first.symbol)) |fn_ptr| {
            return try fn_ptr(allocator, l, frame, depth);
        }
    }

    // Non-special-form: evaluate as function call
    return try evalFunctionCall(allocator, form, frame, depth + 1);
}

/// Evaluate a vector element-wise.
/// Extracted from evalRec to isolate its stack frame.
fn evalVector(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(allocator);
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    for (form.*.vector.items.items) |item| {
        try new_vec.append(allocator, try evalRecDirect(allocator, &item, frame, depth + 1));
    }
    // Phase 1: vectorValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = try vm.vectorValue(allocator, new_vec) };
}

/// Evaluate a map key-value pairs element-wise.
/// Extracted from evalRec to isolate its stack frame.
fn evalMap(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_map.items);
    }
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    for (form.*.map.entries.items) |entry| {
        try new_map.append(allocator, .{
            .key = try evalRecDirect(allocator, &entry.key, frame, depth + 1),
            .value = try evalRecDirect(allocator, &entry.value, frame, depth + 1),
        });
    }
    // Phase 1: mapValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = try vm.mapValue(allocator, new_map) };
}

/// Evaluate a cons cell as a form: convert cons chain to list, then evaluate.
/// Extracted from evalRec to isolate its stack frame (cons evaluation needs a Value copy).
fn evalCons(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    var new_list: list.List = .empty;
    errdefer new_list.deinit(allocator);
    var current_val = form.*;
    while (std.meta.activeTag(current_val) == .cons) {
        const cdata = current_val.cons;
        try new_list.append(allocator, try vm.shallowClone(&cdata.head, allocator));
        current_val = cdata.tail;
    }
    // If tail is a list, splice in its elements
    if (std.meta.activeTag(current_val) == .list) {
        for (current_val.list.items.items) |item| {
            try new_list.append(allocator, try vm.shallowClone(&item, allocator));
        }
    } else if (std.meta.activeTag(current_val) != .nil) {
        // Improper list - append the tail as a final element
        try new_list.append(allocator, try vm.shallowClone(&current_val, allocator));
    }
    const list_val = try vm.listValue(allocator, new_list);
    return try evalList(allocator, &list_val, frame, depth);
}

fn evalFunctionCall(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const l = &form.*.list.items;
    // Evaluate the operator (synchronously — operator is typically a symbol lookup)
    const op_ptr = try evalRecV(allocator, &l.items[0], frame, depth);
    defer allocator.destroy(op_ptr);
    defer vm.valueDeinit(&op_ptr.*, allocator);

    // Check if operator is a macro
    if (std.meta.activeTag(op_ptr.*) == .function and op_ptr.*.function.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        defer macro_args.deinit(allocator);
        for (l.items[1..]) |arg| {
            try macro_args.append(allocator, try vm.shallowClone(&arg, allocator));
        }
        // Call the macro with unevaluated args — disable trampolining so macros evaluate synchronously
        const saved_trampoline = trampoline_allowed;
        trampoline_allowed = false;
        defer trampoline_allowed = saved_trampoline;
        const macro_r = try call(allocator, op_ptr, &macro_args, frame, depth);
        // Phase 1: macro_r.value is now Value by copy (not *Value)
        var expanded = macro_r.value;
        defer vm.valueDeinit(&expanded, allocator);
        // Evaluate the expanded form
        return try evalRec(allocator, &expanded, frame, depth);
    }

    // Evaluate all arguments (synchronously)
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    var args: list.List = .empty;
    defer args.deinit(allocator);
    for (l.items[1..]) |arg| {
        try args.append(allocator, try evalRecDirect(allocator, &arg, frame, depth + 1));
    }

    // Call the function — may return trampoline for user-defined functions
    // Pass source line from the original form list for error reporting
    const src_line = form.*.list.src_line;
    const result = try callWithSrc(allocator, op_ptr, &args, frame, depth, src_line);
    if (std.meta.activeTag(result) == .trampoline) return result;
    // For builtins, result.value is already a *Value — return it directly
    return result;
}

fn evalLet(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    const bindings = &l.items[1];
    if (std.meta.activeTag(bindings.*) != .list and std.meta.activeTag(bindings.*) != .vector) return error.TypeError;
    const body = l.items[2..];

    // Create child Frame for let bindings (overlay-only, no parent copy)
    const child_frame = try frame.createChild(allocator);
    // Use releaseFromParent instead of deinit: child frames on the trampoline stack
    // may still reference this frame as their parent. GC handles eventual cleanup.
    defer child_frame.releaseFromParent(allocator);

    const items = switch (std.meta.activeTag(bindings.*)) {
        .list => bindings.*.list.items.items,
        .vector => bindings.*.vector.items.items,
        else => unreachable,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const sym = &items[i];
        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        const val = try evalRecDirect(allocator, &items[i + 1], child_frame, depth);
        // Bind using destructuring if sym is a vector pattern
        try bindPatternFrame(allocator, sym.*, val, child_frame);
        if (std.meta.activeTag(sym.*) == .symbol) {
        }
    }

    // Evaluate body forms, returning the last result.
    // Phase 3: Non-tail forms use evalRecDirect (Value by copy, no *Value allocation)
    const body_items = body;
    if (body_items.len == 0) {
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.nilValue() };
    }
    // Evaluate all but the last form synchronously (discard results)
    for (body_items[0 .. body_items.len - 1]) |form| {
        _ = try evalRecDirect(allocator, &form, child_frame, depth);
    }
    // Last form in tail position — use evalRec for trampoline support
    return evalRec(allocator, &body_items[body_items.len - 1], child_frame, depth);
}

fn evalLetFn(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    const bindings = l.items[1];
    if (std.meta.activeTag(bindings) != .list and std.meta.activeTag(bindings) != .vector) return error.TypeError;
    const body_forms = l.items[2..];
    const bind_items = switch (std.meta.activeTag(bindings)) {
        .list => bindings.list.items.items,
        .vector => bindings.vector.items.items,
        else => return error.TypeError,
    };

    // Create new env first so all functions can reference each other
    // letfn uses Env chain for mutual recursion (functions need to see each other)
    // Parent is the captured Frame environment (namespace + all overlay bindings)
    // Must be heap-allocated since function closures reference it through the parent chain
    const captured_env_ptr = try allocator.create(Env);
    errdefer allocator.destroy(captured_env_ptr);
    captured_env_ptr.* = try captureFrameEnv(allocator, frame);
    defer captured_env_ptr.deinit(allocator);
    defer allocator.destroy(captured_env_ptr);
    var new_env: Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = captured_env_ptr,
        .ns_manager = null,
    };
    defer new_env.deinit(allocator);

    // Parse each function definition: (name [params] body...)
    for (bind_items) |binding| {
        if (std.meta.activeTag(binding) != .list or binding.list.items.items.len < 3) return error.TypeError;
        const b = binding.list;

        // First element is the function name
        const fname = b.items.items[0];
        if (std.meta.activeTag(fname) != .symbol) return error.TypeError;

        // Second element is the parameter list
        const params_form = b.items.items[1];
        if (std.meta.activeTag(params_form) != .list and std.meta.activeTag(params_form) != .vector) return error.TypeError;
        const params_list = if (std.meta.activeTag(params_form) == .vector)
            try helpers.listFromVector(allocator, params_form.vector.items)
        else
            params_form.list.items;

        // Remaining elements are the body
        var body_list: list.List = .empty;
        errdefer body_list.deinit(allocator);
        try body_list.append(allocator, try vm.symValue(allocator, "do"));
        for (b.items.items[2..]) |form_item| {
            try body_list.append(allocator, try vm.shallowClone(&form_item, allocator));
        }

        // Parse params for variadic support
        var parsed = try parseParams(allocator, params_list);
        defer {
            parsed.params.deinit(allocator);
            if (parsed.rest_name) |rn| allocator.free(rn);
        }

        // Build arity
        var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
        errdefer {
            for (arities.items) |*a| {
                a.params.deinit(allocator);
                a.body.deinit(allocator);
                if (a.rest_name) |rn| allocator.free(rn);
            }
            allocator.free(arities.items);
        }

        const cloned_params = try list.clone(&parsed.params, allocator);
        const cloned_body = try list.clone(&body_list, allocator);
        const cloned_rest = if (parsed.rest_name) |rn| try allocator.dupe(u8, rn) else null;
        try arities.append(allocator, vm.Arity{
            .params = cloned_params,
            .body = cloned_body,
            .rest_name = cloned_rest,
        });

        // Create fn with new_env as closure (for mutual recursion)
        const fn_env: Env = .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = &new_env,
            .ns_manager = null,
        };
        var fn_val = try vm.fnValue(allocator, arities, fn_env, false);
        const persistent_fn = try vm.shallowClone(&fn_val, allocator);
        vm.valueDeinit(&fn_val, allocator);

        // Bind in new_env
        try new_env.put(fname.symbol, persistent_fn);
    }

    // Create a child Frame with new_env as root_env for body evaluation
    const child_frame = try frame.createChild(allocator);
    child_frame.root_env = &new_env;
    // Use detachFromParent instead of deinit: child frames on trampoline may reference this
    defer child_frame.releaseFromParent(allocator);

    const bf = body_forms;
    if (bf.len == 0) {
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.nilValue() };
    }
    // Phase 3: Non-tail forms use evalRecDirect (Value by copy, no *Value allocation)
    for (bf[0 .. bf.len - 1]) |form| {
        _ = try evalRecDirect(allocator, &form, child_frame, depth);
    }
    // Last form in tail position
    return evalRec(allocator, &bf[bf.len - 1], child_frame, depth);
}

/// Bind a value to a pattern. Supports simple symbols and vector destructuring with & rest.
fn bindPattern(allocator: Allocator, pattern: Value, val: Value, env: *vm.Env) anyerror!void {
    switch (std.meta.activeTag(pattern)) {
        .symbol => {
            try env.put(pattern.symbol, try vm.shallowClone(&val, allocator));
        },
        .vector => {
            // Vector destructuring: [a b & rest] matches elements of val
            const vitems = switch (std.meta.activeTag(val)) {
                .list => val.list.items.items,
                .vector => val.vector.items.items,
                else => return error.TypeError,
            };
            var j: usize = 0;
            while (j < pattern.vector.items.items.len) : (j += 1) {
                const pat_item = pattern.vector.items.items[j];
                // Handle & rest (& is parsed as a symbol)
                if (std.meta.activeTag(pat_item) == .symbol and std.mem.eql(u8, pat_item.symbol, "&")) {
                    if (j + 1 < pattern.vector.items.items.len) {
                        const rest_sym = pattern.vector.items.items[j + 1];
                        // Collect remaining items into a list (starting from current position j)
                        var rest_list: list.List = .empty;
                        errdefer rest_list.deinit(allocator);
                        var k: usize = j;
                        while (k < vitems.len) : (k += 1) {
                            try rest_list.append(allocator, try vm.shallowClone(&vitems[k], allocator));
                        }
                        if (std.meta.activeTag(rest_sym) == .symbol) {
                            try env.put(rest_sym.symbol, try vm.listValue(allocator, rest_list));
                        }
                        j += 1; // Skip the rest symbol
                    }
                    break;
                } else if (j < vitems.len) {
                    try bindPattern(allocator, pat_item, vitems[j], env);
                }
            }
        },
        else => return error.TypeError,
    }
}

/// Frame version of bindPattern
fn bindPatternFrame(allocator: Allocator, pattern: Value, val: Value, frame: *vm.Frame) anyerror!void {
    switch (std.meta.activeTag(pattern)) {
        .symbol => {
            try frame.put(pattern.symbol, try vm.shallowClone(&val, allocator));
        },
        .vector => {
            // Vector destructuring: [a b & rest] matches elements of val
            const vitems = switch (std.meta.activeTag(val)) {
                .list => val.list.items.items,
                .vector => val.vector.items.items,
                else => return error.TypeError,
            };
            var j: usize = 0;
            while (j < pattern.vector.items.items.len) : (j += 1) {
                const pat_item = pattern.vector.items.items[j];
                // Handle & rest (& is parsed as a symbol)
                if (std.meta.activeTag(pat_item) == .symbol and std.mem.eql(u8, pat_item.symbol, "&")) {
                    if (j + 1 < pattern.vector.items.items.len) {
                        const rest_sym = pattern.vector.items.items[j + 1];
                        // Collect remaining items into a list (starting from current position j)
                        var rest_list: list.List = .empty;
                        errdefer rest_list.deinit(allocator);
                        var k: usize = j;
                        while (k < vitems.len) : (k += 1) {
                            try rest_list.append(allocator, try vm.shallowClone(&vitems[k], allocator));
                        }
                        if (std.meta.activeTag(rest_sym) == .symbol) {
                            try frame.put(rest_sym.symbol, try vm.listValue(allocator, rest_list));
                        }
                        j += 1; // Skip the rest symbol
                    }
                    break;
                } else if (j < vitems.len) {
                    try bindPatternFrame(allocator, pat_item, vitems[j], frame);
                }
            }
        },
        else => return error.TypeError,
    }
}

fn evalCond(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    const clauses = l.items[1..];
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const cond = clauses[i];
        // Handle :else clause — tail position
        if (std.meta.activeTag(cond) == .keyword and std.mem.eql(u8, cond.keyword, "else")) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, &clauses[i + 1], frame, depth);
        }

        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        const cond_val = try evalRecDirect(allocator, &cond, frame, depth);
        if (vm.isTruthy(cond_val)) {
            if (i + 1 >= clauses.len) return error.ArityError;
            // Body in tail position
            return try evalRec(allocator, &clauses[i + 1], frame, depth);
        }
    }
    // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = vm.nilValue() };
}

fn evalLoop(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    const bindings = l.items[1];
    if (std.meta.activeTag(bindings) != .list and std.meta.activeTag(bindings) != .vector) return error.TypeError;
    const body = l.items[2..];

    const bind_items = switch (std.meta.activeTag(bindings)) {
        .list => bindings.list.items.items,
        .vector => bindings.vector.items.items,
        else => unreachable,
    };

    // Extract binding names
    var bind_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (bind_names.items) |name| allocator.free(name);
        allocator.free(bind_names.items);
    }
    var i: usize = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
        try bind_names.append(allocator, try allocator.dupe(u8, sym.symbol));
    }

    // Create child Frame for loop bindings
    const child_frame = try frame.createChild(allocator);
    defer child_frame.deinit(allocator);

    i = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        const val = try evalRecDirect(allocator, &bind_items[i + 1], child_frame, depth);
        try child_frame.put(sym.symbol, val);
    }

    // Loop: evaluate body, check for recur marker, rebind and repeat
    // Phase 3: Body forms use evalRecDirect (Value by copy, no *Value allocation)
    var loop_depth: usize = depth;
    while (true) {
        if (loop_depth > MAX_RECURSION) return error.RecursionLimit;

        var result: Value = vm.nilValue();
        errdefer vm.valueDeinit(&result, allocator);
        for (body) |form| {
            result = try evalRecDirect(allocator, &form, child_frame, loop_depth);
        }

        // Check for recur marker: list starting with __recur__ symbol
        if (std.meta.activeTag(result) == .list and result.list.items.items.len > 0 and
            std.meta.activeTag(result.list.items.items[0]) == .symbol and
            std.mem.eql(u8, result.list.items.items[0].symbol, "__recur__"))
        {
            const recur_vals = result.list.items.items[1..];
            if (recur_vals.len != bind_names.items.len) {
                vm.valueDeinit(&result, allocator);
                return error.ArityError;
            }
            // Rebind loop variables with new values
            var j: usize = 0;
            while (j < recur_vals.len) : (j += 1) {
                const new_val = try vm.shallowClone(&recur_vals[j], allocator);
                try child_frame.put(bind_names.items[j], new_val);
            }
            vm.valueDeinit(&result, allocator);
            loop_depth += 1;
            continue;
        }

        // Phase 1: result is already Value by copy, no allocValue wrapper needed
        return .{ .value = result };
    }
}

pub fn call(allocator: Allocator, op: *const Value, args_list: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    return callWithSrc(allocator, op, args_list, frame, depth, 0);
}

/// Create a root Frame from a namespace Env for use by external modules.
pub fn createRootFrame(allocator: Allocator, root_env: *Env) anyerror!*vm.Frame {
    const frame_ptr = try allocator.create(vm.Frame);
    errdefer allocator.destroy(frame_ptr);
    frame_ptr.* = vm.Frame.init(allocator, null, root_env);
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(frame_ptr)), gc_mod.GCObjectType.frame);
    }
    return frame_ptr;
}

// Wrapper functions for external modules that still use *Env signatures.
// These create a temporary Frame wrapping the Env.
pub fn callWithEnv(allocator: Allocator, op: *const Value, args_list: *const list.List, env: *Env, depth: usize) anyerror!EvalResult {
    const frame = try createRootFrame(allocator, env);
    // Use detachFromParent instead of deinit: child frames on trampoline may reference this
    defer frame.releaseFromParent(allocator);
    return call(allocator, op, args_list, frame, depth);
}

/// Synchronous version of callWithEnv — disables trampolining.
/// Returns the evaluated *Value directly (never .trampoline).
pub fn callWithEnvV(allocator: Allocator, op: *const Value, args_list: *const list.List, env: *Env, depth: usize) anyerror!*Value {
    const saved_trampoline = trampoline_allowed;
    trampoline_allowed = false;
    defer trampoline_allowed = saved_trampoline;
    const result = try callWithEnv(allocator, op, args_list, env, depth);
    return switch (result) {
        // Phase 1: .value is now Value by copy, need to allocate *Value for return
        .value => |v| try allocValue(allocator, v),
        .trampoline => unreachable,
    };
}

pub fn evalRecWithEnv(allocator: Allocator, form: *const Value, env: *Env, depth: usize) anyerror!EvalResult {
    const frame = try createRootFrame(allocator, env);
    // Use detachFromParent instead of deinit: child frames on trampoline may reference this
    defer frame.releaseFromParent(allocator);
    return evalRec(allocator, form, frame, depth);
}

pub fn evalRecVWithEnv(allocator: Allocator, form: *const Value, env: *Env, depth: usize) anyerror!*Value {
    const frame = try createRootFrame(allocator, env);
    defer frame.deinit(allocator);
    return evalRecV(allocator, form, frame, depth);
}

pub fn callWithSrc(allocator: Allocator, op: *const Value, args_list: *const list.List, frame: *vm.Frame, depth: usize, src_line: usize) anyerror!EvalResult {
    switch (std.meta.activeTag(op.*)) {
        .function => return callFunction(allocator, op, args_list, frame, depth, src_line),
        // Phase 1: callBuiltinFn returns Value by copy, no allocValue wrapper
        .builtin_fn => return .{ .value = try callBuiltinFn(allocator, op, args_list, frame.root_env) },
        .multimethod => {
            const result = try eval_multi.invokeMultimethod(allocator, op.*, args_list, frame, depth);
            return result;
        },
        // Phase 1: callSet/Keyword/Map/Record return Value by copy, no allocValue wrapper
        .set => return .{ .value = try callSet(allocator, op, args_list) },
        .keyword => return .{ .value = try callKeyword(allocator, op, args_list) },
        .map => return .{ .value = try callMap(allocator, op, args_list) },
        .record => return .{ .value = try callRecord(allocator, op, args_list) },
        .lazy_seq => return callLazySeq(allocator, op, frame, depth),
        else => {
            std.debug.print("NotCallable: tried to call value of type {s}\n", .{@tagName(std.meta.activeTag(op.*))});
            return error.NotCallable;
        }
    }
}

/// Call a user-defined function: match arity, bind params, evaluate body.
/// KEY TRAMPOLINE POINT: Instead of recursing into evalRec for body evaluation,
/// pushes a frame onto the trampoline stack. The eval() loop processes it.
fn callFunction(allocator: Allocator, op: *const Value, args: *const list.List, parent_frame: *vm.Frame, depth: usize, src_line: usize) anyerror!EvalResult {
    _ = depth;
    const fn_data = op.function;
    const arity = try matchArity(fn_data, args.items.len);
    // Create child Frame for this function call.
    // Copy captured closure bindings from fn_data.env into the overlay.
    // This avoids issues with shared Env HAMTs being corrupted by deinit.
    const child_frame = try parent_frame.createChild(allocator);
    // Set root_env to the function's captured environment.
    // Mark as function frame so lookup skips parent chain:
    //   child_frame.overlay (params) → root_env (closure captures) → root_env.parent (namespace)
    // The parent chain is kept for trampoline/lifecycle but NOT for symbol lookup.
    child_frame.root_env = fn_data.env;
    child_frame.is_function_frame = true;

    // Bind function name for self-reference (e.g., (fn self [x] (self (dec x))))
    if (fn_data.name) |fn_name| {
        const fn_clone = try vm.shallowClone(op, allocator);
        try child_frame.put(fn_name, fn_clone);
    }

    // Bind parameters (regular + rest) to arguments
    try bindArityParamsFrame(allocator, arity, args, child_frame);

    // Check for protocol dispatch marker
    if (arity.body.items.len >= 1 and
        std.meta.activeTag(arity.body.items[0]) == .symbol and
        std.mem.eql(u8, arity.body.items[0].symbol, "__protocol_dispatch__"))
    {
        // Protocol dispatch still uses Env-based lookup
        const result = try protocols.dispatchProtocolMethod(allocator, args.*, child_frame.root_env, 0);
        child_frame.deinit(allocator);
        // Phase 1: dispatchProtocolMethod returns Value by copy, no allocValue wrapper
        return .{ .value = result };
    }

    // If bytecode is available, use the VM instead of AST interpreter
    if (arity.bytecode) |bc| {
        // Bytecode VM still uses Env-based lookups
        const bc_env = try allocator.create(Env);
        bc_env.* = try cloneFnEnv(allocator, fn_data.env);
        try bindArityParamsEnv(allocator, arity, args, bc_env);
        const vm_result = try bytecode_mod.execute(allocator, bc, bc_env);
        switch (vm_result) {
            .value => |v| {
                bc_env.deinit(allocator);
                allocator.destroy(bc_env);
                child_frame.deinit(allocator);
                // Phase 1: bytecode .value is *Value (bytecode still uses *Value), extract the Value
                return .{ .value = v.* };
            },
            .trampoline => {
                // A user-defined function was called from within the bytecode.
                // Fall back to AST interpreter for the trampoline case.
                bc_env.deinit(allocator);
                allocator.destroy(bc_env);
            },
        }
    }

    // Phase 2: Store body as a slice reference — no cloning needed.
    // The body is part of the function definition (immutable, permanently rooted).
    // The FnData (and its body Values) is alive as long as the function Value is referenced,
    // and the function Value is held by the caller during the call.
    // The body Values are logically immutable — evaluation never mutates them.
    child_frame.body_form_items = arity.body.items;
    child_frame.body_form_src_line = src_line;

    // Phase 9: Trampoline or evaluate directly based on trampoline_allowed flag.
    // When trampoline_allowed is false (e.g., during evalRecV), evaluate directly
    // to avoid interfering with the main eval loop's current_frame tracking.
    const src_loc = if (src_line > 0) SourceLoc{ .line = src_line } else SourceLoc{};
    child_frame.src_loc = src_loc;
    if (trampoline_allowed) {
        eval_context.current_frame = child_frame;
        return .trampoline;
    } else {
        // Evaluate body directly (no trampoline)
        const result = try evalRecSlice(allocator, arity.body.items, child_frame, 0);
        child_frame.deinit(allocator);
        return result;
    }
}

/// Find the matching arity for a given argument count.
fn matchArity(fn_data: *const vm.FnData, arg_count: usize) anyerror!*const vm.Arity {
    var i: usize = 0;
    while (i < fn_data.arities.items.len) : (i += 1) {
        const arity = &fn_data.arities.items[i];
        const min_args = arity.params.items.len;
        const has_rest = arity.rest_name != null;
        if (has_rest) {
            if (arg_count >= min_args) return arity;
        } else {
            if (arg_count == min_args) return arity;
        }
    }
    return error.ArityError;
}

/// Clone a function's closure env, skipping the clone if the env has no local entries.
fn cloneFnEnv(allocator: Allocator, src: *const Env) anyerror!Env {
    if (!src.entries.isEmpty()) {
        return try src.clone(allocator);
    }
    return .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = src.parent,
        .ns_manager = null,
    };
}

/// Bind arity parameters (regular + rest) to arguments in a Frame.
fn bindArityParamsFrame(allocator: Allocator, arity: *const vm.Arity, args: *const list.List, frame: *vm.Frame) anyerror!void {
    const min_args = arity.params.items.len;
    const has_rest = arity.rest_name != null;

    // Bind regular parameters to arguments (with destructuring support)
    var j: usize = 0;
    while (j < arity.params.items.len) : (j += 1) {
        const param = arity.params.items[j];
        try bindParamFrame(allocator, param, args.items[j], frame);
    }

    // Bind rest parameter to remaining args as a list
    if (has_rest) {
        if (args.items.len > min_args) {
            var rest_list: list.List = .empty;
            errdefer rest_list.deinit(allocator);
            var k: usize = min_args;
            while (k < args.items.len) : (k += 1) {
                try rest_list.append(allocator, try vm.shallowClone(&args.items[k], allocator));
            }
            try frame.put(arity.rest_name.?, try vm.listValue(allocator, rest_list));
        } else {
            // No extra args: bind empty list to rest parameter
            if (vm.cachedEmptyList()) |empty| {
                try frame.put(arity.rest_name.?, empty);
            } else {
                try frame.put(arity.rest_name.?, try vm.listValue(allocator, .empty));
            }
        }
    }
}

/// Bind arity parameters (regular + rest) to arguments in an Env.
/// Used by bytecode path which still uses Env-based lookups.
fn bindArityParamsEnv(allocator: Allocator, arity: *const vm.Arity, args: *const list.List, new_env: *Env) anyerror!void {
    const min_args = arity.params.items.len;
    const has_rest = arity.rest_name != null;

    // Bind regular parameters to arguments (with destructuring support)
    var j: usize = 0;
    while (j < arity.params.items.len) : (j += 1) {
        const param = arity.params.items[j];
        try bindParam(allocator, param, args.items[j], new_env);
    }

    // Bind rest parameter to remaining args as a list
    if (has_rest) {
        if (args.items.len > min_args) {
            var rest_list: list.List = .empty;
            errdefer rest_list.deinit(allocator);
            var k: usize = min_args;
            while (k < args.items.len) : (k += 1) {
                try rest_list.append(allocator, try vm.shallowClone(&args.items[k], allocator));
            }
            try new_env.put(arity.rest_name.?, try vm.listValue(allocator, rest_list));
        } else {
            // No extra args: bind empty list to rest parameter
            if (vm.cachedEmptyList()) |empty| {
                try new_env.put(arity.rest_name.?, empty);
            } else {
                try new_env.put(arity.rest_name.?, try vm.listValue(allocator, .empty));
            }
        }
    }
}

/// Call a built-in function registered with the VM.
/// Phase 9: Converts specific Zig errors to typed Clojure exceptions.
fn callBuiltinFn(allocator: Allocator, op: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    // Use cast to avoid copying the large Value struct onto the stack
    const op_mut = @constCast(op);
    return op_mut.builtin_fn(op_mut, args, env) catch |err| {
        // Phase 9: Convert division by zero to ArithmeticException
        if (err == error.DivisionByZero) {
            const empty_map = vm.cachedEmptyMap() orelse return err;
            const ex = try vm.exceptionValue(allocator, "Divide by zero", empty_map.map, null, "clojure.lang/ArithmeticException");
            current_exception = ex.exception;
            exception_thrown = true;
            return EvalError.Exception;
        }
        // Phase 10: Convert socket errors to SocketException
        // The socket module sets current_exception before returning this error.
        const err_name = @errorName(err);
        if (std.mem.eql(u8, err_name, "SocketException")) {
            return EvalError.Exception;
        }
        return err;
    };
}

/// Call a set as a function: returns the element if found, nil otherwise.
fn callSet(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    for (op.set.items.items) |item| {
        if (vm.equals(item, args.items[0])) {
            return try vm.shallowClone(&item, allocator);
        }
    }
    return vm.nilValue();
}

/// Call a keyword as a function: looks up the keyword in a map or record.
fn callKeyword(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    _ = allocator;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    if (std.meta.activeTag(coll) == .map) {
        for (coll.map.entries.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, op.keyword)) {
                return entry.value;  // Share - values in map are immutable
            }
        }
    } else if (std.meta.activeTag(coll) == .record) {
        for (coll.record.fields.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, op.keyword)) {
                return entry.value;
            }
        }
        for (coll.record.extmap.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, op.keyword)) {
                return entry.value;
            }
        }
    }
    return vm.nilValue();
}

/// Call a map as a function: returns value for key, or not-found if provided.
fn callMap(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    _ = allocator;
    if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
    const key = args.items[0];
    for (op.map.entries.items) |entry| {
        if (vm.equals(entry.key, key)) {
            return entry.value;  // Share - values in map are immutable
        }
    }
    if (args.items.len == 2) {
        return args.items[1];
    }
    return vm.nilValue();
}

/// Call a record as a function: returns value for key (fields first, then extmap).
fn callRecord(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    _ = allocator;
    if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
    const key = args.items[0];
    for (op.record.fields.items) |entry| {
        if (vm.equals(entry.key, key)) {
            return entry.value;  // Share - values in record are immutable
        }
    }
    for (op.record.extmap.items) |entry| {
        if (vm.equals(entry.key, key)) {
            return entry.value;
        }
    }
    if (args.items.len == 2) {
        return args.items[1];
    }
    return vm.nilValue();
}

/// Call a lazy-seq as a function: forces its evaluation (no args allowed).
fn callLazySeq(allocator: Allocator, op: *const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result_ptr = try forceLazySeq(allocator, op.*, frame, depth);
    // Phase 1: extract Value from *Value, no extra allocation needed
    const v = result_ptr.*;
    allocator.destroy(result_ptr);
    return .{ .value = v };
}

// Flatten a cons chain into a list for doall/dorun.
// Recursively forces any nested lazy_seqs.
fn flattenConsForDoall(allocator: Allocator, val: Value, frame: *vm.Frame, depth: usize, target: *list.List) anyerror!void {
    var current = val;
    errdefer vm.valueDeinit(&current, allocator);

    while (true) {
        switch (std.meta.activeTag(current)) {
            .cons => {
                // Force the head if it's a lazy_seq
                const cdata = current.cons;
                const head = cdata.head;
                if (std.meta.activeTag(head) == .lazy_seq) {
                    const head_forced_ptr = try forceLazySeq(allocator, try vm.shallowClone(&head, allocator), frame, depth + 1);
                    if (std.meta.activeTag(head_forced_ptr.*) == .list) {
                        for (head_forced_ptr.list.items.items) |fi| {
                            try target.append(allocator, try vm.shallowClone(&fi, allocator));
                        }
                    } else {
                        try target.append(allocator, head_forced_ptr.*);
                    }
                    vm.valueDeinit(&head_forced_ptr.*, allocator);
                } else {
                    try target.append(allocator, try vm.shallowClone(&head, allocator));
                }
                // Move to tail
                const tail = try vm.shallowClone(&cdata.tail, allocator);
                vm.valueDeinit(&current, cdata.allocator);
                current = tail;
            },
            .list => {
                for (current.list.items.items) |item| {
                    if (std.meta.activeTag(item) == .lazy_seq) {
                        const forced_ptr = try forceLazySeq(allocator, item, frame, depth + 1);
                        if (std.meta.activeTag(forced_ptr.*) == .list) {
                            for (forced_ptr.list.items.items) |fi| {
                                try target.append(allocator, try vm.shallowClone(&fi, allocator));
                            }
                        }
                        vm.valueDeinit(&forced_ptr.*, allocator);
                    } else {
                        try target.append(allocator, try vm.shallowClone(&item, allocator));
                    }
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                // Force the lazy_seq and flatten
                const forced_ptr = try forceLazySeq(allocator, current, frame, depth + 1);
                if (std.meta.activeTag(forced_ptr.*) == .list) {
                    for (forced_ptr.list.items.items) |fi| {
                        try target.append(allocator, try vm.shallowClone(&fi, allocator));
                    }
                }
                vm.valueDeinit(&forced_ptr.*, allocator);
                break;
            },
            else => {
                try target.append(allocator, current);
                current = vm.nilValue();
                break;
            },
        }
    }
    vm.valueDeinit(&current, allocator);
}

// Force evaluation of a lazy sequence, returning the resulting list
fn forceLazySeq(allocator: Allocator, lazy: Value, frame: *vm.Frame, depth: usize) anyerror!*Value {
    // Evaluate the thunk
    if (lazy.lazy_seq) |thunk| {
        // Clone thunk data for evaluation — don't free the thunk itself
        // since the original Value (e.g. stored in env) still holds the pointer.
        // The thunk will be properly freed when the original Value is deinited.
        var cloned_params = try list.clone(&thunk.params, allocator);
        var cloned_body = try list.clone(&thunk.body, allocator);
        var thunk_env = try thunk.env.clone(allocator);
        // CRITICAL: Set thunk_env.allocator to persistent allocator
        thunk_env.allocator = allocator;
        defer {
            cloned_params.deinit(allocator);
            cloned_body.deinit(allocator);
            thunk_env.deinit(allocator);
        }

        // Evaluate the body to get the result
        // Create a Frame from thunk_env for evaluation
        const thunk_frame = try createRootFrame(allocator, &thunk_env);
        defer thunk_frame.deinit(allocator);
        const body_val = try vm.listValue(allocator, cloned_body);
        const result_ptr = try evalRecV(allocator, &body_val, thunk_frame, depth);

        // The result should be a list/vector (the sequence)
        // Convert to list if needed
        var final_list: list.List = .empty;
        errdefer final_list.deinit(allocator);

        switch (std.meta.activeTag(result_ptr.*)) {
            .list => {
                // Handle cons cell pattern: [head, lazy_seq_tail]
                if (result_ptr.*.list.items.items.len == 2 and std.meta.activeTag(result_ptr.*.list.items.items[1]) == .lazy_seq) {
                    const head_item = result_ptr.*.list.items.items[0];
                    if (std.meta.activeTag(head_item) == .lazy_seq) {
                        const head_forced_ptr = try forceLazySeq(allocator, head_item, frame, depth + 1);
                        try final_list.append(allocator, head_forced_ptr.*);
                        vm.valueDeinit(&head_forced_ptr.*, allocator);
                    } else {
                        try final_list.append(allocator, try vm.shallowClone(&head_item, allocator));
                    }
                    const tail_forced_ptr = try forceLazySeq(allocator, result_ptr.*.list.items.items[1], frame, depth + 1);
                    if (std.meta.activeTag(tail_forced_ptr.*) == .list) {
                        for (tail_forced_ptr.*.list.items.items) |fi| {
                            try final_list.append(allocator, try vm.shallowClone(&fi, allocator));
                        }
                    }
                    vm.valueDeinit(&tail_forced_ptr.*, allocator);
                } else {
                    for (result_ptr.*.list.items.items) |item| {
                        // Recursively force nested lazy_seqs for doall/dorun
                        if (std.meta.activeTag(item) == .lazy_seq) {
                            const forced_ptr = try forceLazySeq(allocator, item, frame, depth + 1);
                            if (std.meta.activeTag(forced_ptr.*) == .list) {
                                for (forced_ptr.*.list.items.items) |fi| {
                                    try final_list.append(allocator, try vm.shallowClone(&fi, allocator));
                                }
                            }
                            vm.valueDeinit(&forced_ptr.*, allocator);
                        } else {
                            try final_list.append(allocator, try vm.shallowClone(&item, allocator));
                        }
                    }
                }
            },
            .vector => {
                for (result_ptr.*.vector.items.items) |item| {
                    if (std.meta.activeTag(item) == .lazy_seq) {
                        const forced_ptr = try forceLazySeq(allocator, item, frame, depth + 1);
                        if (std.meta.activeTag(forced_ptr.*) == .list) {
                            for (forced_ptr.*.list.items.items) |fi| {
                                try final_list.append(allocator, try vm.shallowClone(&fi, allocator));
                            }
                        }
                        vm.valueDeinit(&forced_ptr.*, allocator);
                    } else {
                        try final_list.append(allocator, try vm.shallowClone(&item, allocator));
                    }
                }
            },
            .nil => {}, // empty sequence
            .lazy_seq => {
                // Recursively force for doall/dorun
                const forced_ptr = try forceLazySeq(allocator, result_ptr.*, frame, depth + 1);
                if (std.meta.activeTag(forced_ptr.*) == .list) {
                    for (forced_ptr.list.items.items) |fi| {
                        try final_list.append(allocator, try vm.shallowClone(&fi, allocator));
                    }
                }
                vm.valueDeinit(&forced_ptr.*, allocator);
            },
            .cons => {
                // Walk the cons chain and flatten into the list
                try flattenConsForDoall(allocator, result_ptr.*, frame, depth + 1, &final_list);
            },
            else => {
                try final_list.append(allocator, result_ptr.*);
            },
        }

        vm.valueDeinit(&result_ptr.*, allocator);
        return try allocValue(allocator, try vm.listValue(allocator, final_list));
    }

    return try allocValue(allocator, try vm.listValue(allocator, list.empty()));
}

// Bind a parameter to an argument, supporting destructuring
// e.g., param=[a b], arg=[1 2] => binds a=1, b=2
fn bindParam(allocator: Allocator, param: Value, arg: Value, env: *vm.Env) anyerror!void {
    // Delegate to bindPattern which handles symbols, vector destructuring,
    // & rest patterns, and nested destructuring.
    try bindPattern(allocator, param, arg, env);
}

// Frame version of bindParam
fn bindParamFrame(allocator: Allocator, param: Value, arg: Value, frame: *vm.Frame) anyerror!void {
    // Delegate to bindPatternFrame which handles symbols, vector destructuring,
    // & rest patterns, and nested destructuring.
    try bindPatternFrame(allocator, param, arg, frame);
}

// Check if a form looks like a parameter list (vector/list of symbols, possibly with & rest)
fn looksLikeParamList(form: Value) bool {
    const items = switch (std.meta.activeTag(form)) {
        .vector => form.vector.items.items,
        .list => form.list.items.items,
        else => return false,
    };
    if (items.len == 0) return false;
    var found_amp = false;
    for (items) |item| {
        if (std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.symbol, "&")) {
            if (found_amp) return false; // duplicate &
            found_amp = true;
            continue;
        }
        if (!found_amp and std.meta.activeTag(item) != .symbol) return false;
        if (found_amp and std.meta.activeTag(item) != .symbol) return false;
    }
    return true;
}

// case - multi-way constant dispatch
// (case expr test1 result1 test2 result2 ... :else default)
fn evalCase(allocator: Allocator, forms: []const Value, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (forms.len < 1) return error.ArityError;

    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const expr_val = try evalRecDirect(allocator, &forms[0], frame, depth);

    var i: usize = 1;
    while (i < forms.len) : (i += 2) {
        const test_form = forms[i];
        if (std.meta.activeTag(test_form) == .keyword and std.mem.eql(u8, test_form.keyword, "else")) {
            if (i + 1 >= forms.len) return error.ArityError;
            // Body in tail position
            return try evalRec(allocator, &forms[i + 1], frame, depth);
        }

        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        const test_val = try evalRecDirect(allocator, &test_form, frame, depth);

        if (vm.equals(expr_val, test_val)) {
            if (i + 1 >= forms.len) return error.ArityError;
            // Body in tail position
            return try evalRec(allocator, &forms[i + 1], frame, depth);
        }
    }

    // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = vm.nilValue() };
}

// ============================================================================
// Extracted special form evaluators
// These were inline in evalList. Extracting them reduces evalList's stack
// frame from ~48 KB to a thin dispatcher. Each handler has its own smaller
// frame allocated only when that specific form is evaluated.
// ============================================================================

/// (quote form) — return form unevaluated
fn evalQuote(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    _ = frame;
    _ = depth;
    if (l.items.len != 2) return error.ArityError;
    // Phase 1: cloneGC returns *Value, extract the Value
    const ptr = try vm.cloneGC(&l.items[1], allocator);
    return .{ .value = ptr.* };
}

/// (quit) / (exit) — signal REPL to exit
fn evalQuit(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    _ = allocator;
    _ = l;
    _ = frame;
    _ = depth;
    return error.ReplExit;
}

/// (quasiquote form) — template with unquote
fn evalQuasiquote(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len != 2) return error.ArityError;
    // Pass the full Frame so unquote can resolve local bindings (e.g. macro parameters)
    const result = try eval_macro.unquoteProcess(allocator, l.items[1], frame, depth + 1);
    // Phase 1: unquoteProcess returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

/// (def name value?) — define in current namespace
fn evalDef(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const eval_idx: usize = if (l.items.len >= 3) 2 else 1;
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const val = try evalRecDirect(allocator, &l.items[eval_idx], frame, depth + 1);
    const persistent_val = try vm.shallowClone(&val, allocator);
    try bindInCurrentNamespace(frame.root_env, sym.symbol, persistent_val);
    // Phase 1: cloneGC returns *Value, extract the Value
    const ptr = try vm.cloneGC(&sym, allocator);
    return .{ .value = ptr.* };
}

/// (if test then else?) — conditional
fn evalIf(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2 or l.items.len > 4) return error.ArityError;
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const cond_val = try evalRecDirect(allocator, &l.items[1], frame, depth + 1);
    const truthy = vm.isTruthy(cond_val);
    if (truthy) {
        // Then-branch in tail position — use evalRec for trampoline
        if (l.items.len >= 3) return try evalRec(allocator, &l.items[2], frame, depth + 1);
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.nilValue() };
    } else {
        // Else-branch in tail position — use evalRec for trampoline
        if (l.items.len >= 4) return try evalRec(allocator, &l.items[3], frame, depth + 1);
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.nilValue() };
    }
}

/// (when test body...) — if with implicit do
fn evalWhen(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const cond_val = try evalRecDirect(allocator, &l.items[1], frame, depth + 1);
    const truthy = vm.isTruthy(cond_val);
    if (truthy) {
        const body = l.items[2..];
        if (body.len == 0) {
            // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
            return .{ .value = vm.nilValue() };
        }
        // Phase 3: Non-tail forms use evalRecDirect (Value by copy)
        for (body[0 .. body.len - 1]) |form| {
            _ = try evalRecDirect(allocator, &form, frame, depth + 1);
        }
        // Last form in tail position
        return try evalRec(allocator, &body[body.len - 1], frame, depth + 1);
    }
    // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = vm.nilValue() };
}

/// (do body...) — evaluate a sequence of forms
fn evalDo(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const body = l.items[1..];
    if (body.len == 0) {
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.nilValue() };
    }
    // Phase 3: Non-tail forms use evalRecDirect (Value by copy, no *Value allocation)
    for (body[0 .. body.len - 1]) |form| {
        _ = try evalRecDirect(allocator, &form, frame, depth + 1);
    }
    // Last form in tail position — use evalRec for trampoline
    return evalRec(allocator, &body[body.len - 1], frame, depth + 1);
}

/// (defn name docstring? ([params] body...)+) — define named function
fn evalDefn(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    _ = depth;
    if (l.items.len < 3) return error.ArityError;
    const fname = l.items[1];
    if (std.meta.activeTag(fname) != .symbol) return error.TypeError;
    var idx: usize = 2;
    var docstring: ?[]const u8 = null;
    if (idx < l.items.len and std.meta.activeTag(l.items[idx]) == .string) {
        docstring = try allocator.dupe(u8, l.items[idx].string);
        idx += 1;
    }
    if (idx >= l.items.len) return error.ArityError;

    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.bytecode) |bc| {
                bc.deinit(allocator);
                allocator.destroy(bc);
            }
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }

    arities = try parseArityForms(allocator, l.items, l.items.len, &idx);

    // Compile each arity's body to bytecode.
    // Skip if body contains unhandled special forms or function calls.
    // Arithmetic/comparison operators are safe (compile to direct opcodes, Phase 6).
    // loop/recur is now supported in bytecode (Phase 5).
    for (arities.items) |*a| {
        if (!bytecode_mod.containsUnhandledSpecialFormInList(a.body) and
            !bytecode_mod.containsDestructuring(a.params) and
            !bytecode_mod.containsRealFunctionCallsInList(a.body))
        {
            const bc = try bytecode_mod.compile(allocator, a.body, "<defn>", frame.root_env);
            a.bytecode = try allocator.create(bytecode_mod.BytecodeProgram);
            a.bytecode.?.* = bc;
            // Register BytecodeProgram with GC so its internal arrays are scanned
            if (gc_mod.current_gc) |gc_inst| {
                gc_inst.setObjectType(a.bytecode.?, gc_mod.GCObjectType.bytecode_program);
            }
        }
    }

    // Get the actual namespace env where bindings live.
    // fn_env.parent must point to the same env chain that bindInCurrentNamespace uses,
    // otherwise recursive self-references won't find the function in the namespace.
    const ns_env_for_closure: *Env = if (findNsManager(frame.root_env)) |ns_mgr| blk: {
        const current_ns = ns_mgr.getCurrentNamespace();
        break :blk ns_mgr.getNamespace(current_ns) orelse frame.root_env;
    } else frame.root_env;
    const fn_env: Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = ns_env_for_closure,
        .ns_manager = frame.root_env.ns_manager,
    };
    var fn_val = try vm.fnValueNamedWithDoc(allocator, arities, fn_env, false, null, docstring);
    const persistent_fn = try vm.shallowClone(&fn_val, allocator);
    vm.valueDeinit(&fn_val, allocator);
    try bindInCurrentNamespace(frame.root_env, fname.symbol, persistent_fn);
    // Phase 1: cloneGC returns *Value, extract the Value
    const ptr = try vm.cloneGC(&fname, allocator);
    return .{ .value = ptr.* };
}

/// (fn name? ([params] body...)+) — anonymous function
fn evalFn(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    _ = depth;
    if (l.items.len < 2) return error.ArityError;
    var idx: usize = 1;
    var fn_name: ?Value = null;
    if (std.meta.activeTag(l.items[idx]) == .symbol) {
        fn_name = l.items[idx];
        idx += 1;
    }
    if (idx >= l.items.len) return error.ArityError;

    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }

    arities = try parseArityForms(allocator, l.items, l.items.len, &idx);

    // Capture full Frame chain environment as closure (namespace + all overlay bindings)
    const fn_env = try captureFrameEnv(allocator, frame);

    var fn_name_str: ?[]const u8 = null;
    if (fn_name) |name_sym| {
        fn_name_str = try allocator.dupe(u8, name_sym.symbol);
    }

    const fn_val = try vm.fnValueNamed(allocator, arities, fn_env, false, fn_name_str);
    // Phase 1: fnValueNamed returns Value by copy, no allocValue wrapper needed
    return .{ .value = fn_val };
}

/// (defmacro name docstring? ([params] body...)+) — define a macro
fn evalDefmacro(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    _ = depth;
    if (l.items.len < 3) return error.ArityError;
    const macro_name = l.items[1];
    if (std.meta.activeTag(macro_name) != .symbol) return error.TypeError;
    var idx: usize = 2;
    var docstring: ?[]const u8 = null;
    if (idx < l.items.len and std.meta.activeTag(l.items[idx]) == .string) {
        docstring = try allocator.dupe(u8, l.items[idx].string);
        idx += 1;
    }
    if (idx >= l.items.len) return error.ArityError;

    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }

    arities = try parseArityForms(allocator, l.items, l.items.len, &idx);

    // Same as defn: use the actual namespace env for the closure parent
    const ns_env_for_closure2: *Env = if (findNsManager(frame.root_env)) |ns_mgr| blk: {
        const current_ns = ns_mgr.getCurrentNamespace();
        break :blk ns_mgr.getNamespace(current_ns) orelse frame.root_env;
    } else frame.root_env;
    const fn_env: Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = ns_env_for_closure2,
        .ns_manager = frame.root_env.ns_manager,
    };
    var macro_fn = try vm.fnValueNamedWithDoc(allocator, arities, fn_env, true, null, docstring);
    const persistent_macro = try vm.shallowClone(&macro_fn, allocator);
    vm.valueDeinit(&macro_fn, allocator);
    try bindInCurrentNamespace(frame.root_env, macro_name.symbol, persistent_macro);
    // Phase 1: cloneGC returns *Value, extract the Value
    const ptr = try vm.cloneGC(&macro_name, allocator);
    return .{ .value = ptr.* };
}

/// (set! name value) — modify a variable
fn evalSetBang(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len != 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    // Verify the binding exists in the current frame's overlay.
    // set! can only modify local bindings (var, let, fn params).
    // Parent-level bindings are immutable from this frame's perspective.
    if (!frame.hasInOverlay(sym.symbol)) {
        return error.UndefinedSymbol;
    }
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const val = try evalRecDirect(allocator, &l.items[2], frame, depth + 1);
    const persistent_val = try vm.shallowClone(&val, allocator);
    // Write to current frame's overlay (not root namespace env)
    try frame.put(sym.symbol, persistent_val);
    return .{ .value = val };
}

/// (recur new-arg*) — tail recursion signal
fn evalRecur(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    var results: list.List = .empty;
    errdefer results.deinit(allocator);
    try results.append(allocator, try vm.symValue(allocator, "__recur__"));
    for (l.items[1..]) |arg| {
        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        try results.append(allocator, try evalRecDirect(allocator, &arg, frame, depth + 1));
    }
    // Phase 1: listValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = try vm.listValue(allocator, results) };
}

/// (var name value?) — create a mutable var
fn evalVar(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const val: Value = if (l.items.len >= 3) blk: {
        break :blk try evalRecDirect(allocator, &l.items[2], frame, depth + 1);
    } else vm.nilValue();
    const persistent_val = try vm.shallowClone(&val, allocator);
    // Write to current frame's overlay (local var)
    try frame.put(sym.symbol, persistent_val);
    // Phase 1: cloneGC returns *Value, extract the Value
    const ptr = try vm.cloneGC(&sym, allocator);
    return .{ .value = ptr.* };
}

/// (deref form) / (@ form) — get value from atom/var/reduced/future
fn evalDeref(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len != 2) return error.ArityError;
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const arg_val = try evalRecDirect(allocator, &l.items[1], frame, depth + 1);
    if (std.meta.activeTag(arg_val) == .atom) {
        const data = arg_val.atom;
        const val = try vm.shallowClone(&data.value, allocator);
        // Phase 1: shallowClone returns Value by copy, no allocValue wrapper needed
        return .{ .value = val };
    }
    if (std.meta.activeTag(arg_val) == .ref) {
        // Deref a ref — read current value
        var deref_args: list.List = .empty;
        errdefer deref_args.deinit(allocator);
        try deref_args.append(allocator, arg_val);
        const result = try ref_mod.core_ref_deref(testSelf(), &deref_args, frame.root_env);
        // Phase 1: core_ref_deref returns Value by copy, no allocValue wrapper needed
        return .{ .value = result };
    }
    if (std.meta.activeTag(arg_val) == .reduced) {
        const data = arg_val.reduced;
        const val = try vm.shallowClone(&data.*, allocator);
        // Phase 1: shallowClone returns Value by copy, no allocValue wrapper needed
        return .{ .value = val };
    }
    if (std.meta.activeTag(arg_val) == .future) {
        // Deref a future — blocks until done
        var deref_args: list.List = .empty;
        errdefer deref_args.deinit(allocator);
        try deref_args.append(allocator, arg_val);
        const result = try threading.core_deref_future(testSelf(), &deref_args, frame.root_env);
        // Phase 1: core_deref_future returns Value by copy, no allocValue wrapper needed
        return .{ .value = result };
    }
    if (std.meta.activeTag(arg_val) == .promise) {
        // Deref a promise — blocks until delivered
        var deref_args: list.List = .empty;
        errdefer deref_args.deinit(allocator);
        try deref_args.append(allocator, arg_val);
        const result = try threading.core_deref_promise(testSelf(), &deref_args, frame.root_env);
        // Phase 1: core_deref_promise returns Value by copy, no allocValue wrapper needed
        return .{ .value = result };
    }
    // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = vm.nilValue() };
}

/// Helper for evalDeref: create a dummy self Value for builtin calls.
fn testSelf() *const vm.Value {
    return undefined; // builtin functions ignore self
}

/// (or form*) — short-circuit or
fn evalOr(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const forms = l.items[1..];
    if (forms.len == 0) {
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.nilValue() };
    }
    // Phase 3: Non-tail forms use evalRecDirect (Value by copy, no *Value allocation)
    for (forms[0 .. forms.len - 1]) |form_item| {
        const val = try evalRecDirect(allocator, &form_item, frame, depth + 1);
        if (vm.isTruthy(val)) {
            return .{ .value = val };
        }
    }
    // Last form in tail position
    return evalRec(allocator, &forms[forms.len - 1], frame, depth + 1);
}

/// (and form*) — short-circuit and
fn evalAnd(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const forms = l.items[1..];
    if (forms.len == 0) {
        // Phase 1: boolValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.boolValue(true) };
    }
    // Phase 3: Non-tail forms use evalRecDirect (Value by copy, no *Value allocation)
    for (forms[0 .. forms.len - 1]) |form_item| {
        const val = try evalRecDirect(allocator, &form_item, frame, depth + 1);
        if (!vm.isTruthy(val)) {
            return .{ .value = val };
        }
    }
    // Last form in tail position
    return evalRec(allocator, &forms[forms.len - 1], frame, depth + 1);
}

/// (binding [var1 val1 ...] body...) — dynamic variable binding
fn evalBinding(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 3) return error.ArityError;
    const bindings = l.items[1];
    if (std.meta.activeTag(bindings) != .vector) return error.TypeError;

    // Find the namespace manager for dynamic var storage
    const ns_mgr = findNsManager(frame.root_env) orelse return error.RuntimeError;

    // Track saved state for each binding: (name, had_previous_value, saved_value?)
    var saved_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var had_previous: std.ArrayListUnmanaged(bool) = .empty;
    var saved_values: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (saved_names.items) |name| allocator.free(name);
        saved_names.deinit(allocator);
        had_previous.deinit(allocator);
        for (saved_values.items) |*val| vm.valueDeinit(val, allocator);
        saved_values.deinit(allocator);
    }

    // Create child frame for scope
    const child_frame = try frame.createChild(allocator);
    defer child_frame.releaseFromParent(allocator);

    // Set dynamic bindings in namespace manager
    var i: usize = 0;
    while (i < bindings.vector.items.items.len) : (i += 2) {
        const sym = bindings.vector.items.items[i];
        if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
        const sym_name = sym.symbol;

        // Save old value if exists
        const old_val = ns_mgr.getDynamicVar(sym_name);
        const saved_name = try allocator.dupe(u8, sym_name);
        try saved_names.append(allocator, saved_name);
        if (old_val) |ov| {
            try had_previous.append(allocator, true);
            try saved_values.append(allocator, try vm.clone(&ov, allocator));
        } else {
            try had_previous.append(allocator, false);
            try saved_values.append(allocator, vm.nilValue());
        }

        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        const val = try evalRecDirect(allocator, &bindings.vector.items.items[i + 1], child_frame, depth + 1);
        try ns_mgr.putDynamicVar(sym_name, val);
        // Also store in child frame for local scope
        try child_frame.put(sym_name, val);
    }

    // Restore old dynamic var values after body
    defer {
        for (saved_names.items, had_previous.items, saved_values.items) |name, prev, val| {
            if (prev) {
                ns_mgr.putDynamicVar(name, val) catch {};
            } else {
                ns_mgr.removeDynamicVar(name) catch {};
            }
        }
    }

    const body = l.items[2..];
    if (body.len == 0) {
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = vm.nilValue() };
    }
    // Phase 3: Non-tail forms use evalRecDirect (Value by copy)
    for (body[0 .. body.len - 1]) |form| {
        _ = try evalRecDirect(allocator, &form, child_frame, depth + 1);
    }
    // Last form in tail position
    return evalRec(allocator, &body[body.len - 1], child_frame, depth + 1);
}

/// (lazy-seq body...) — create a lazy sequence
fn evalLazySeq(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    _ = depth;
    if (l.items.len < 2) return error.ArityError;
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "do"));
    for (l.items[1..]) |form| {
        try body.append(allocator, try vm.shallowClone(&form, allocator));
    }
    // Capture the effective environment: namespace env + all frame overlay bindings
    const thunk_env = try captureFrameEnv(allocator, frame);
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = body,
        .env = thunk_env,
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
    }
    // Phase 1: lazySeqValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = vm.lazySeqValue(thunk) };
}

/// Capture the effective environment of a Frame into a flat Env.
/// Walks the Frame chain from parent to current so that closer bindings override.
fn captureFrameEnv(allocator: Allocator, frame: *vm.Frame) anyerror!Env {
    // Do NOT clone the namespace environment.
    // Instead, create an env with empty HAMT and parent = root_env.
    // This preserves the lookup chain: overlay → parent chain → root_env.
    // Only capture overlay bindings from the frame chain (actual closure captures).
    var env: Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = frame.root_env,
        .ns_manager = frame.root_env.ns_manager,
    };
    // Collect frames from current to parent
    var frames: std.ArrayListUnmanaged(*vm.Frame) = .empty;
    errdefer frames.deinit(allocator);
    var current: ?*vm.Frame = frame;
    while (current) |f| : (current = f.parent) {
        try frames.append(allocator, f);
    }
    // Walk in reverse (parent first, current last) so current overrides parent
    var i: usize = frames.items.len;
    while (i > 0) {
        i -= 1;
        var it = frames.items[i].overlay.entryIterator();
        while (it.next()) |entry| {
            if (std.meta.activeTag(entry.key) == .symbol) {
                try env.put(entry.key.symbol, try vm.shallowClone(&entry.val, allocator));
            }
        }
    }
    return env;
}

/// (dorun n? coll) — realize sequence for side effects, return nil
fn evalDorun(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const dorun_args = l.items[1..];
    var n: ?usize = null;
    var coll_form: Value = undefined;
    if (dorun_args.len == 2) {
        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        const n_val = try evalRecDirect(allocator, &dorun_args[0], frame, depth + 1);
        const n_int: i64 = switch (std.meta.activeTag(n_val)) {
            .integer => n_val.integer,
            .float => @as(i64, @intFromFloat(n_val.float)),
            else => return error.TypeError,
        };
        n = @as(usize, @intCast(n_int));
        coll_form = dorun_args[1];
    } else {
        coll_form = dorun_args[0];
    }
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    var coll = try evalRecDirect(allocator, &coll_form, frame, depth + 1);
    if (std.meta.activeTag(coll) == .lazy_seq) {
        const forced = try sequences.forceLazySeqHelper(allocator, coll);
        vm.valueDeinit(&coll, allocator);
        coll = forced;
    }
    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        .set => items = coll.set.items.items,
        .queue => items = coll.queue.items.items,
        // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
        else => return .{ .value = vm.nilValue() },
    }
    var count: usize = 0;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        if (n) |limit| {
            if (count >= limit) break;
        }
        const item = items[i];
        if (std.meta.activeTag(item) == .lazy_seq) {
            _ = try sequences.forceLazySeqHelper(allocator, item);
        }
        count += 1;
    }
    // Phase 1: nilValue returns Value by copy, no allocValue wrapper needed
    return .{ .value = vm.nilValue() };
}

/// (doall coll) — realize lazy sequences and return result
fn evalDoall(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len != 2) return error.ArityError;
    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const coll_val = try evalRecDirect(allocator, &l.items[1], frame, depth + 1);
    if (std.meta.activeTag(coll_val) == .lazy_seq) {
        const forced = try sequences.forceLazySeqHelper(allocator, coll_val);
        // Phase 1: cloneGC returns *Value, extract the Value
        const ptr = try vm.cloneGC(&forced, allocator);
        return .{ .value = ptr.* };
    }
    if (std.meta.activeTag(coll_val) == .nil) {
        // Phase 1: listValue returns Value by copy, no allocValue wrapper needed
        return .{ .value = try vm.listValue(allocator, list.empty()) };
    }
    return .{ .value = coll_val };
}

/// (throw expr) — evaluate expr and signal an exception.
/// The expression must evaluate to an exception value.
/// Sets thread-local exception state and returns EvalError.Exception.
fn evalThrow(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len != 2) return error.ArityError;

    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
    const ex_val = try evalRecDirect(allocator, &l.items[1], frame, depth + 1);

    // The expression must evaluate to an exception value
    if (std.meta.activeTag(ex_val) != .exception) {
        return error.TypeError;
    }

    // Set thread-local exception state
    current_exception = ex_val.exception;
    exception_thrown = true;

    // Return the sentinel error that signals "exception thrown"
    return EvalError.Exception;
}

/// (extend atype protocol mmap & more...) — add protocol implementations
fn evalExtend(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    if (l.items.len < 4) return error.ArityError;
    var ext_args: list.List = .empty;
    errdefer ext_args.deinit(allocator);
    try ext_args.append(allocator, try vm.shallowClone(&l.items[1], allocator));
    var ei: usize = 2;
    while (ei < l.items.len) : (ei += 1) {
        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        try ext_args.append(allocator, try evalRecDirect(allocator, &l.items[ei], frame, depth + 1));
    }
    const result = try protocols.evalExtend(allocator, ext_args, frame.root_env, depth + 1);
    // Phase 1: evalExtend returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

// ============================================================================
// Wrapper functions for external module handlers
// These adapt the unified SpecialFormFn signature to external module APIs.
// ============================================================================

fn evalNsForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try eval_ns.evalNs(allocator, l.*, frame.root_env, depth);
    // Phase 1: evalNs returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalInNsForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try eval_ns.evalInNs(allocator, l.*, frame.root_env, depth);
    // Phase 1: evalInNs returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalDefprotocolForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try protocols.evalDefProtocol(allocator, l.*, frame.root_env, depth + 1);
    // Phase 1: evalDefProtocol returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalExtendTypeForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try protocols.evalExtendType(allocator, l.*, frame.root_env, depth + 1);
    // Phase 1: evalExtendType returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalExtendProtocolForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try protocols.evalExtendProtocol(allocator, l.*, frame.root_env, depth + 1);
    // Phase 1: evalExtendProtocol returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalDefrecordForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try records.evalDefRecord(allocator, l.*, frame.root_env, depth + 1);
    // Phase 1: evalDefRecord returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalThreadLastForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try eval_thread.evalThreadLast(allocator, l.items[1..], frame, depth + 1);
    // Phase 1: evalThreadLast returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalThreadFirstForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try eval_thread.evalThreadFirst(allocator, l.items[1..], frame, depth + 1);
    // Phase 1: evalThreadFirst returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalCondThreadFirstForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try eval_thread.evalCondThreadFirst(allocator, l.items[1..], frame, depth + 1);
    // Phase 1: evalCondThreadFirst returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalCondThreadLastForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    const result = try eval_thread.evalCondThreadLast(allocator, l.items[1..], frame, depth + 1);
    // Phase 1: evalCondThreadLast returns Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

fn evalCaseForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!EvalResult {
    return try evalCase(allocator, l.items[1..], frame, depth + 1);
}
