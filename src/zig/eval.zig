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
const eval_macro = @import("eval_macro.zig");
const eval_ns = @import("eval_ns.zig");
const protocols = @import("namespaces/core/protocols.zig");
const records = @import("namespaces/core/records.zig");
const gc_mod = @import("gc.zig");
const threading = @import("namespaces/core/threading.zig");
const bytecode_mod = @import("bytecode.zig");

const Allocator = std.mem.Allocator;

// ============================================================
// Trampoline infrastructure — heap-based evaluation stack
// Replaces C-stack recursion with heap-allocated frames.
// Every Clojure function call pushes a frame instead of recursing.
// ============================================================

/// A single evaluation frame on the heap stack.
/// Represents one pending function body evaluation.
pub const TrampolineFrame = struct {
    body_form: Value,       // the function body to evaluate (a list)
    frame: *vm.Frame,       // the function's evaluation frame (heap-allocated, GC-managed)
    src_loc: vm.SourceLoc = .{}, // source location of the call site
};

// Re-export SourceLoc from value.zig for backward compatibility
pub const SourceLoc = vm.SourceLoc;

/// Heap-based evaluation stack for trampolining.
pub const TrampolineStack = struct {
    allocator: Allocator,
    frames: std.ArrayListUnmanaged(TrampolineFrame),

    pub fn init(allocator: Allocator) TrampolineStack {
        return .{
            .allocator = allocator,
            .frames = .empty,
        };
    }

    pub fn deinit(self: *TrampolineStack) void {
        // Clean up any remaining frames
        for (self.frames.items) |*f| {
            f.frame.detachFromParent();
            vm.valueDeinit(&f.body_form, self.allocator);
        }
        self.frames.deinit(self.allocator);
    }

    /// Push a frame for function body evaluation.
    pub fn push(self: *TrampolineStack, body: Value, frame: *vm.Frame) anyerror!void {
        return self.pushWithLoc(body, frame, .{});
    }

    /// Push a frame for function body evaluation with source location.
    pub fn pushWithLoc(self: *TrampolineStack, body: Value, frame: *vm.Frame, src_loc: SourceLoc) anyerror!void {
        try self.frames.append(self.allocator, .{
            .body_form = body,
            .frame = frame,
            .src_loc = src_loc,
        });
    }

    /// Pop the top frame.
    pub fn pop(self: *TrampolineStack) ?TrampolineFrame {
        if (self.frames.items.len == 0) return null;
        const item = self.frames.items[self.frames.items.len - 1];
        self.frames.items.len -= 1;
        return item;
    }

    pub fn isEmpty(self: *const TrampolineStack) bool {
        return self.frames.items.len == 0;
    }

    pub fn len(self: *const TrampolineStack) usize {
        return self.frames.items.len;
    }
};

/// Result of evalRec: either a normal *Value or a Trampoline marker.
pub const EvalResult = union(enum) {
    value: *Value,
    trampoline, // signals that a frame was pushed, caller should continue loop
};

/// Allocate a Value on the GC heap and initialize it from a stack Value.
/// Used for Values constructed directly (not cloned), e.g. vm.nilValue(), vm.listValue(...).
pub fn allocValue(allocator: Allocator, val: Value) anyerror!*Value {
    const ptr = try allocator.create(Value);
    ptr.* = val;
    return ptr;
}

/// Dereference and deinit a *Value, used for intermediate results that won't be returned.
pub fn deallocValue(allocator: Allocator, ptr: *Value) void {
    ptr.*.deinit(allocator);
    // Don't destroy - GC manages the memory
}

/// Unified special form handler signature.
const SpecialFormFn = *const fn (Allocator, *const list.List, *vm.Frame, usize, ?*TrampolineStack) anyerror!EvalResult;

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
    .{ .name = "->>", .fn_ptr = evalThreadLastForm },
    .{ .name = "->", .fn_ptr = evalThreadFirstForm },
    .{ .name = "cond->", .fn_ptr = evalCondThreadFirstForm },
    .{ .name = "cond->>", .fn_ptr = evalCondThreadLastForm },
    .{ .name = "case", .fn_ptr = evalCaseForm },
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

/// Push the HAMT root from an Env as a temporary GC root.
/// Returns a Guard struct that pops the root on deinit (use `defer guard.deinit()`).
/// This protects HAMT nodes reachable from stack-allocated Env structs.
const TempRootGuard = struct {
    gc: ?*gc_mod.GC,
    has_hamt_root: bool = false,

    pub fn deinit(self: TempRootGuard) void {
        if (self.gc) |gc_inst| {
            if (self.has_hamt_root) {
                gc_inst.popTempRoot(); // pop HAMT root (last pushed)
            }
            gc_inst.popTempRoot(); // pop env (first pushed)
        }
    }
};

pub fn pushEnvTempRoot(env: *const Env) TempRootGuard {
    if (gc_mod.current_gc) |gc_inst| {
        // Push the Env struct itself as a temp root so the GC doesn't sweep
        // the Env while it's in use by the evaluation stack.
        gc_inst.pushTempRoot(@as(*anyopaque, @ptrCast(@constCast(env))));
        // Also push the HAMT root for thorough coverage.
        const has_hamt = env.entries.root != null;
        if (env.entries.root) |root| {
            gc_inst.pushTempRoot(root);
        }
        return TempRootGuard{ .gc = gc_inst, .has_hamt_root = has_hamt };
    }
    return TempRootGuard{ .gc = null, .has_hamt_root = false };
}

/// Pop the temp roots pushed by pushEnvTempRoot.
/// Used when the guard's deinit cannot be used (e.g., in the eval loop).
pub fn popEnvTempRoot(env: *const Env) void {
    if (gc_mod.current_gc) |gc_inst| {
        if (env.entries.root) |_| {
            gc_inst.popTempRoot(); // pop HAMT root (last pushed)
        }
        gc_inst.popTempRoot(); // pop env (first pushed)
    }
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
fn formatEvalError(allocator: Allocator, err: anyerror, file: []const u8, form: *const Value, tramp: *const TrampolineStack) ![]const u8 {
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

    // Add stack trace from trampoline stack
    if (tramp.frames.items.len > 0) {
        try msg.appendSlice(allocator, "\n\nStack trace:");
        // Print frames from bottom (oldest) to top (newest)
        var i: usize = 0;
        while (i < tramp.frames.items.len) : (i += 1) {
            const frame = &tramp.frames.items[i];
            const fn_name = extractFnName(&frame.body_form);
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
    var tramp = TrampolineStack.init(allocator);
    errdefer tramp.deinit();

    // Create root Frame from namespace Env
    const root_frame = try createRootFrame(allocator, env);
    defer root_frame.deinit(allocator);

    // Evaluate the initial form
    var result: ?EvalResult = evalRec(allocator, &form, root_frame, 0, &tramp) catch |err| {
        // Don't format internal control errors like ReplExit
        if (err == EvalError.ReplExit) return err;
        const msg = formatEvalError(allocator, err, file, &form, &tramp) catch {
            return err; // errdefer will clean up tramp
        };
        defer allocator.free(msg);
        std.debug.print("{s}\n", .{msg});
        return err; // errdefer will clean up tramp
    };

    // Trampoline loop: process pending frames
    while (true) {
        const current = result orelse {
            tramp.deinit();
            return try allocValue(allocator, vm.nilValue());
        };

        switch (current) {
            .value => |v| {
                tramp.deinit();
                return v;
            },
            .trampoline => {},
        }

        // Pop the next frame and evaluate it
        var tramp_frame = tramp.pop() orelse {
            tramp.deinit();
            return try allocValue(allocator, vm.nilValue());
        };

        const body_val = tramp_frame.body_form;
        result = evalRec(allocator, &body_val, tramp_frame.frame, 0, &tramp) catch |err| {
            // Don't format internal control errors like ReplExit
            if (err == EvalError.ReplExit) {
                tramp_frame.frame.detachFromParent();
                return err; // errdefer will clean up tramp
            }
            const msg = formatEvalError(allocator, err, file, &body_val, &tramp) catch {
                tramp_frame.frame.detachFromParent();
                return err; // errdefer will clean up tramp
            };
            defer allocator.free(msg);
            std.debug.print("{s}\n", .{msg});
            tramp_frame.frame.detachFromParent();
            return err; // errdefer will clean up tramp
        };

        // Clean up the frame — detach from parent so GC can reclaim it.
        // Don't deinit if frame has children still on the trampoline stack.
        tramp_frame.frame.detachFromParent();
    }
}

/// Wrapper: evalRec that extracts .value from EvalResult.
/// Accepts ctx for trampoline support. Pass null for synchronous evaluation
/// (e.g., during argument evaluation where trampoline is not desired).
/// When ctx is provided and evalRec returns .trampoline, this function
/// processes the trampoline frames internally until a .value is obtained.
fn evalRecV(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!*Value {
    var result: EvalResult = try evalRec(allocator, form, frame, depth, ctx);

    // Handle trampoline: process frames until we get a value
    while (true) {
        switch (result) {
            .value => |v| return v,
            .trampoline => {},
        }

        // Pop and evaluate the next frame
        const tramp_frame = ctx.?.pop() orelse return try allocValue(allocator, vm.nilValue());

        result = try evalRec(allocator, &tramp_frame.body_form, tramp_frame.frame, 0, ctx);

        tramp_frame.frame.detachFromParent();
    }
}

/// Internal recursive evaluator with trampoline support.
/// When ctx is provided and a function body needs evaluation,
/// pushes a frame onto ctx and returns .trampoline instead of recursing.
pub fn evalRec(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    switch (form.*) {
        .nil, .bool, .integer, .float, .bigint, .ratio, .decimal, .string, .regex, .character, .keyword, .set, .queue, .chunk, .chunked_cons, .atom, .future, .promise, .reduced, .wrapped, .record => {
            return .{ .value = try vm.cloneGC(form, allocator) };
        },
        .symbol => {
            if (std.mem.eql(u8, form.*.symbol, "quote") or
                std.mem.eql(u8, form.*.symbol, "quasiquote") or
                std.mem.eql(u8, form.*.symbol, "unquote") or
                std.mem.eql(u8, form.*.symbol, "unquote-splicing"))
            {
                return .{ .value = try vm.cloneGC(form, allocator) };
            }
            // Handle qualified symbols: alias/name or namespace/name
            if (std.mem.indexOfScalar(u8, form.*.symbol, '/')) |slash_idx| {
                const alias = form.*.symbol[0..slash_idx];
                const name = form.*.symbol[slash_idx + 1 ..];
                // Resolve through namespace manager
                const ns_mgr = findNsManager(frame.root_env) orelse {
                    const val2 = frame.get(form.*.symbol);
                    if (val2) |v| return .{ .value = try vm.cloneGC(&v, allocator) };
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
                    return error.UndefinedSymbol;
                };
                // Look up alias in current namespace, or use the part before '/' as a direct namespace name
                const current_ns = ns_mgr.getCurrentNamespace();
                const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
                // Get target namespace's env and look up the name
                const target_env = ns_mgr.getNamespace(target_ns) orelse {
                    // Target namespace doesn't exist, try direct lookup
                    const val3 = frame.get(form.*.symbol);
                    if (val3) |v| return .{ .value = try vm.cloneGC(&v, allocator) };
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
                    return error.UndefinedSymbol;
                };
                const val4 = target_env.get(name);
                if (val4) |v| return .{ .value = try vm.cloneGC(&v, allocator) };
                std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
                return error.UndefinedSymbol;
            }
            const val = frame.get(form.*.symbol);
            if (val) |v| return .{ .value = try vm.cloneGC(&v, allocator) };
            std.debug.print("Undefined symbol: '{s}'\n", .{form.*.symbol});
            return error.UndefinedSymbol;
        },
        .list => {
            return try evalList(allocator, form, frame, depth, ctx);
        },
        .vector => {
            return try evalVector(allocator, form, frame, depth, ctx);
        },
        .map => {
            return try evalMap(allocator, form, frame, depth, ctx);
        },
        .function, .builtin_fn => return .{ .value = try vm.cloneGC(form, allocator) },
        .lazy_seq => return .{ .value = try vm.cloneGC(form, allocator) },
        .cons => {
            return try evalCons(allocator, form, frame, depth, ctx);
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
            try body_list.append(allocator, try vm.clone(&form_item, allocator));
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
            try regular_params.append(allocator, try vm.clone(&item, allocator));
        }
    }

    return ParsedParams{
        .params = regular_params,
        .rest_name = rest_name,
    };
}

fn evalList(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const l = &form.*.list.items;
    if (l.items.len == 0) return .{ .value = try allocValue(allocator, try vm.listValue(allocator, list.empty())) };

    const first = l.items[0];

    // Self-evaluating symbols (special forms) — dispatch via lookup table
    if (std.meta.activeTag(first) == .symbol) {
        if (findSpecialForm(first.symbol)) |fn_ptr| {
            return try fn_ptr(allocator, l, frame, depth, ctx);
        }
    }

    // Non-special-form: evaluate as function call
    return try evalFunctionCall(allocator, form, frame, depth + 1, ctx);
}

/// Evaluate a vector element-wise.
/// Extracted from evalRec to isolate its stack frame.
fn evalVector(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx; // element evaluation is synchronous
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(allocator);
    for (form.*.vector.items.items) |item| {
        const ptr = try evalRecV(allocator, &item, frame, depth + 1, null);
        try new_vec.append(allocator, ptr.*);
    }
    return .{ .value = try allocValue(allocator, try vm.vectorValue(allocator, new_vec)) };
}

/// Evaluate a map key-value pairs element-wise.
/// Extracted from evalRec to isolate its stack frame.
fn evalMap(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx; // element evaluation is synchronous
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_map.items);
    }
    for (form.*.map.entries.items) |entry| {
        const key_ptr = try evalRecV(allocator, &entry.key, frame, depth + 1, null);
        const val_ptr = try evalRecV(allocator, &entry.value, frame, depth + 1, null);
        try new_map.append(allocator, .{
            .key = key_ptr.*,
            .value = val_ptr.*,
        });
    }
    return .{ .value = try allocValue(allocator, try vm.mapValue(allocator, new_map)) };
}

/// Evaluate a cons cell as a form: convert cons chain to list, then evaluate.
/// Extracted from evalRec to isolate its stack frame (cons evaluation needs a Value copy).
fn evalCons(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    var new_list: list.List = .empty;
    errdefer new_list.deinit(allocator);
    var current_val = form.*;
    while (std.meta.activeTag(current_val) == .cons) {
        const cdata = current_val.cons;
        try new_list.append(allocator, try vm.clone(&cdata.head, allocator));
        current_val = cdata.tail;
    }
    // If tail is a list, splice in its elements
    if (std.meta.activeTag(current_val) == .list) {
        for (current_val.list.items.items) |item| {
            try new_list.append(allocator, try vm.clone(&item, allocator));
        }
    } else if (std.meta.activeTag(current_val) != .nil) {
        // Improper list - append the tail as a final element
        try new_list.append(allocator, try vm.clone(&current_val, allocator));
    }
    const list_val = try vm.listValue(allocator, new_list);
    return try evalList(allocator, &list_val, frame, depth, ctx);
}

fn evalFunctionCall(allocator: Allocator, form: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const l = &form.*.list.items;
    // Evaluate the operator (synchronously — operator is typically a symbol lookup)
    const op_ptr = try evalRecV(allocator, &l.items[0], frame, depth, null);
    defer allocator.destroy(op_ptr);
    defer vm.valueDeinit(&op_ptr.*, allocator);

    // Check if operator is a macro
    if (std.meta.activeTag(op_ptr.*) == .function and op_ptr.*.function.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        defer macro_args.deinit(allocator);
        for (l.items[1..]) |arg| {
            try macro_args.append(allocator, try vm.clone(&arg, allocator));
        }
        // Call the macro with unevaluated args — use null ctx so macros evaluate synchronously
        const macro_r = try call(allocator, op_ptr, &macro_args, frame, depth, null);
        const expanded_ptr = macro_r.value;
        var expanded = expanded_ptr.*;
        defer vm.valueDeinit(&expanded, allocator);
        defer allocator.destroy(expanded_ptr);
        // Evaluate the expanded form
        return try evalRec(allocator, &expanded, frame, depth, ctx);
    }

    // Evaluate all arguments (synchronously via evalRecV to avoid trampoline complexity)
    var args: list.List = .empty;
    defer args.deinit(allocator);
    for (l.items[1..]) |arg| {
        const arg_ptr = try evalRecV(allocator, &arg, frame, depth + 1, null);
        try args.append(allocator, arg_ptr.*);
    }

    // Call the function — may return trampoline for user-defined functions
    // Pass source line from the original form list for error reporting
    const src_line = form.*.list.src_line;
    const result = try callWithSrc(allocator, op_ptr, &args, frame, depth, ctx, src_line);
    if (std.meta.activeTag(result) == .trampoline) return result;
    // For builtins, result.value is already a *Value — return it directly
    return result;
}

fn evalLet(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
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
        // Evaluate binding value synchronously (no trampoline — we need the value)
        const val_ptr = try evalRecV(allocator, &items[i + 1], child_frame, depth, null);
        // Bind using destructuring if sym is a vector pattern
        try bindPatternFrame(allocator, sym.*, val_ptr.*, child_frame);
        if (std.meta.activeTag(sym.*) == .symbol) {
        }
    }

    // Evaluate body forms, returning the last result.
    // Non-tail forms evaluated synchronously; tail form uses evalRec for trampoline.
    var last_ptr: ?*Value = null;
    errdefer {
        if (last_ptr) |p| {
            vm.valueDeinit(&p.*, allocator);
            allocator.destroy(p);
        }
    }
    const body_items = body;
    if (body_items.len == 0) {
        return .{ .value = try allocValue(allocator, vm.nilValue()) };
    }
    // Evaluate all but the last form synchronously
    for (body_items[0 .. body_items.len - 1]) |form| {
        if (last_ptr) |p| {
            vm.valueDeinit(&p.*, allocator);
            allocator.destroy(p);
        }
        last_ptr = try evalRecV(allocator, &form, child_frame, depth, null);
    }
    // Last form in tail position — use evalRec for trampoline support
    const tail_result = try evalRec(allocator, &body_items[body_items.len - 1], child_frame, depth, ctx);
    if (last_ptr) |p| {
        vm.valueDeinit(&p.*, allocator);
        allocator.destroy(p);
    }
    return tail_result;
}

fn evalLetFn(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
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
    defer pushEnvTempRoot(&new_env).deinit();

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
            try body_list.append(allocator, try vm.clone(&form_item, allocator));
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
        const persistent_fn = try vm.clone(&fn_val, allocator);
        vm.valueDeinit(&fn_val, allocator);

        // Bind in new_env
        try new_env.put(fname.symbol, persistent_fn);
    }

    // Create a child Frame with new_env as root_env for body evaluation
    const child_frame = try frame.createChild(allocator);
    child_frame.root_env = &new_env;
    // Use detachFromParent instead of deinit: child frames on trampoline may reference this
    defer child_frame.releaseFromParent(allocator);

    var do_result: Value = vm.nilValue();
    errdefer vm.valueDeinit(&do_result, allocator);
    const bf = body_forms;
    if (bf.len == 0) {
        return .{ .value = try allocValue(allocator, vm.nilValue()) };
    }
    // Non-tail forms evaluated synchronously
    for (bf[0 .. bf.len - 1]) |form| {
        const result_ptr = try evalRecV(allocator, &form, child_frame, depth, null);
        vm.valueDeinit(&do_result, allocator);
        do_result = result_ptr.*;
    }
    // Last form in tail position
    const tail_result = try evalRec(allocator, &bf[bf.len - 1], child_frame, depth, ctx);
    return tail_result;
}

/// Bind a value to a pattern. Supports simple symbols and vector destructuring with & rest.
fn bindPattern(allocator: Allocator, pattern: Value, val: Value, env: *vm.Env) anyerror!void {
    switch (std.meta.activeTag(pattern)) {
        .symbol => {
            try env.put(pattern.symbol, try vm.clone(&val, allocator));
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
                            try rest_list.append(allocator, try vm.clone(&vitems[k], allocator));
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
            try frame.put(pattern.symbol, try vm.clone(&val, allocator));
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
                            try rest_list.append(allocator, try vm.clone(&vitems[k], allocator));
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

fn evalCond(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    const clauses = l.items[1..];
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const cond = clauses[i];
        // Handle :else clause — tail position
        if (std.meta.activeTag(cond) == .keyword and std.mem.eql(u8, cond.keyword, "else")) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, &clauses[i + 1], frame, depth, ctx);
        }

        // Condition evaluated synchronously (we need to inspect the value)
        const result_ptr = try evalRecV(allocator, &cond, frame, depth, null);
        if (vm.isTruthy(result_ptr.*)) {
            if (i + 1 >= clauses.len) return error.ArityError;
            vm.valueDeinit(result_ptr, allocator);
            // Body in tail position
            return try evalRec(allocator, &clauses[i + 1], frame, depth, ctx);
        }
        vm.valueDeinit(result_ptr, allocator);
    }
    return .{ .value = try allocValue(allocator, vm.nilValue()) };
}

fn evalLoop(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx; // loop/recur handles its own iteration, no trampoline needed
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
        // Binding values evaluated synchronously (we need the value)
        const val_ptr = try evalRecV(allocator, &bind_items[i + 1], child_frame, depth, null);
        try child_frame.put(sym.symbol, val_ptr.*);
    }

    // Loop: evaluate body, check for recur marker, rebind and repeat
    // Body forms evaluated synchronously — loop needs to inspect results for __recur__
    var loop_depth: usize = depth;
    while (true) {
        if (loop_depth > MAX_RECURSION) return error.RecursionLimit;

        var result: Value = vm.nilValue();
        errdefer vm.valueDeinit(&result, allocator);
        for (body) |form| {
            const result_ptr = try evalRecV(allocator, &form, child_frame, loop_depth, null);
            vm.valueDeinit(&result, allocator);
            result = result_ptr.*;
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
                const new_val = try vm.clone(&recur_vals[j], allocator);
                try child_frame.put(bind_names.items[j], new_val);
            }
            vm.valueDeinit(&result, allocator);
            loop_depth += 1;
            continue;
        }

        return .{ .value = try allocValue(allocator, result) };
    }
}

pub fn call(allocator: Allocator, op: *const Value, args_list: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    return callWithSrc(allocator, op, args_list, frame, depth, ctx, 0);
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
pub fn callWithEnv(allocator: Allocator, op: *const Value, args_list: *const list.List, env: *Env, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const frame = try createRootFrame(allocator, env);
    // Use detachFromParent instead of deinit: child frames on trampoline may reference this
    defer frame.releaseFromParent(allocator);
    return call(allocator, op, args_list, frame, depth, ctx);
}

pub fn evalRecWithEnv(allocator: Allocator, form: *const Value, env: *Env, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const frame = try createRootFrame(allocator, env);
    // Use detachFromParent instead of deinit: child frames on trampoline may reference this
    defer frame.releaseFromParent(allocator);
    return evalRec(allocator, form, frame, depth, ctx);
}

pub fn evalRecVWithEnv(allocator: Allocator, form: *const Value, env: *Env, depth: usize, ctx: ?*TrampolineStack) anyerror!*Value {
    const frame = try createRootFrame(allocator, env);
    defer frame.deinit(allocator);
    return evalRecV(allocator, form, frame, depth, ctx);
}

pub fn callWithSrc(allocator: Allocator, op: *const Value, args_list: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack, src_line: usize) anyerror!EvalResult {
    switch (std.meta.activeTag(op.*)) {
        .function => return callFunction(allocator, op, args_list, frame, depth, ctx, src_line),
        .builtin_fn => return .{ .value = try allocValue(allocator, try callBuiltinFn(allocator, op, args_list, frame.root_env)) },
        .set => return .{ .value = try allocValue(allocator, try callSet(allocator, op, args_list)) },
        .keyword => return .{ .value = try allocValue(allocator, try callKeyword(allocator, op, args_list)) },
        .map => return .{ .value = try allocValue(allocator, try callMap(allocator, op, args_list)) },
        .record => return .{ .value = try allocValue(allocator, try callRecord(allocator, op, args_list)) },
        .lazy_seq => return callLazySeq(allocator, op, frame, depth, ctx),
        else => {
            std.debug.print("NotCallable: tried to call value of type {s}\n", .{@tagName(std.meta.activeTag(op.*))});
            return error.NotCallable;
        }
    }
}

/// Call a user-defined function: match arity, bind params, evaluate body.
/// KEY TRAMPOLINE POINT: Instead of recursing into evalRec for body evaluation,
/// pushes a frame onto the trampoline stack. The eval() loop processes it.
fn callFunction(allocator: Allocator, op: *const Value, args: *const list.List, parent_frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack, src_line: usize) anyerror!EvalResult {
    _ = depth;
    const fn_data = op.function;
    const arity = try matchArity(fn_data, args.items.len);

    // Create child Frame with root_env = fn_data.env (closure capture via root_env)
    const child_frame = try parent_frame.createChild(allocator);
    child_frame.root_env = fn_data.env;

    // Bind function name for self-reference (e.g., (fn self [x] (self (dec x))))
    if (fn_data.name) |fn_name| {
        const fn_clone = try vm.clone(op, allocator);
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
        return .{ .value = try allocValue(allocator, result) };
    }

    // If bytecode is available, use the VM instead of AST interpreter
    if (arity.bytecode) |bc| {
        // Bytecode VM still uses Env-based lookups
        const bc_env = try allocator.create(Env);
        bc_env.* = try cloneFnEnv(allocator, fn_data.env);
        try bindArityParamsEnv(allocator, arity, args, bc_env);
        const vm_result = try bytecode_mod.execute(allocator, bc, bc_env, ctx);
        switch (vm_result) {
            .value => |v| {
                bc_env.deinit(allocator);
                allocator.destroy(bc_env);
                child_frame.deinit(allocator);
                return .{ .value = v };
            },
            .trampoline => {
                // A user-defined function was called from within the bytecode.
                // Fall back to AST interpreter for the trampoline case.
                bc_env.deinit(allocator);
                allocator.destroy(bc_env);
            },
        }
    }

    // TRAMPOLINE: Push body evaluation onto heap stack instead of recursing.
    // The eval() loop will pop this frame and evaluate it.
    // Deep clone the body so it survives after the caller frees its copy of the function Value.
    var body_clone: list.List = .empty;
    errdefer body_clone.deinit(allocator);
    for (arity.body.items) |item| {
        try body_clone.append(allocator, try vm.clone(&item, allocator));
    }
    // Set source line on the body form for error reporting
    const body_val = try vm.listValueWithLine(allocator, body_clone, src_line);
    if (ctx) |tramp| {
        // Set source location on the trampoline frame for error reporting
        const src_loc = if (src_line > 0) SourceLoc{ .line = src_line } else SourceLoc{};
        try tramp.pushWithLoc(body_val, child_frame, src_loc);
        return .trampoline;
    }

    // Fallback: no trampoline context — evaluate directly (shouldn't happen in normal use)
    const result_ptr = try evalRec(allocator, &body_val, child_frame, 0, null);
    child_frame.deinit(allocator);
    return result_ptr;
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
                try rest_list.append(allocator, try vm.clone(&args.items[k], allocator));
            }
            try frame.put(arity.rest_name.?, try vm.listValue(allocator, rest_list));
        } else {
            // No extra args: bind empty list to rest parameter
            try frame.put(arity.rest_name.?, try vm.listValue(allocator, .empty));
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
                try rest_list.append(allocator, try vm.clone(&args.items[k], allocator));
            }
            try new_env.put(arity.rest_name.?, try vm.listValue(allocator, rest_list));
        } else {
            // No extra args: bind empty list to rest parameter
            try new_env.put(arity.rest_name.?, try vm.listValue(allocator, .empty));
        }
    }
}

/// Call a built-in function registered with the VM.
fn callBuiltinFn(_: Allocator, op: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    // Use cast to avoid copying the large Value struct onto the stack
    const op_mut = @constCast(op);
    return op_mut.builtin_fn(op_mut, args, env);
}

/// Call a set as a function: returns the element if found, nil otherwise.
fn callSet(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    for (op.set.items.items) |item| {
        if (vm.equals(item, args.items[0])) {
            return try vm.clone(&item, allocator);
        }
    }
    return vm.nilValue();
}

/// Call a keyword as a function: looks up the keyword in a map or record.
fn callKeyword(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    if (std.meta.activeTag(coll) == .map) {
        for (coll.map.entries.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, op.keyword)) {
                return try vm.clone(&entry.value, allocator);
            }
        }
    } else if (std.meta.activeTag(coll) == .record) {
        for (coll.record.fields.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, op.keyword)) {
                return try vm.clone(&entry.value, allocator);
            }
        }
        for (coll.record.extmap.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, op.keyword)) {
                return try vm.clone(&entry.value, allocator);
            }
        }
    }
    return vm.nilValue();
}

/// Call a map as a function: returns value for key, or not-found if provided.
fn callMap(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
    const key = args.items[0];
    for (op.map.entries.items) |entry| {
        if (vm.equals(entry.key, key)) {
            return try vm.clone(&entry.value, allocator);
        }
    }
    if (args.items.len == 2) {
        return try vm.clone(&args.items[1], allocator);
    }
    return vm.nilValue();
}

/// Call a record as a function: returns value for key (fields first, then extmap).
fn callRecord(allocator: Allocator, op: *const Value, args: *const list.List) anyerror!Value {
    if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
    const key = args.items[0];
    for (op.record.fields.items) |entry| {
        if (vm.equals(entry.key, key)) {
            return try vm.clone(&entry.value, allocator);
        }
    }
    for (op.record.extmap.items) |entry| {
        if (vm.equals(entry.key, key)) {
            return try vm.clone(&entry.value, allocator);
        }
    }
    if (args.items.len == 2) {
        return try vm.clone(&args.items[1], allocator);
    }
    return vm.nilValue();
}

/// Call a lazy-seq as a function: forces its evaluation (no args allowed).
fn callLazySeq(allocator: Allocator, op: *const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    const result_ptr = try forceLazySeq(allocator, op.*, frame, depth);
    // result_ptr is already a *Value — return it directly
    return .{ .value = result_ptr };
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
                    const head_forced_ptr = try forceLazySeq(allocator, try vm.clone(&head, allocator), frame, depth + 1);
                    if (std.meta.activeTag(head_forced_ptr.*) == .list) {
                        for (head_forced_ptr.list.items.items) |fi| {
                            try target.append(allocator, try vm.clone(&fi, allocator));
                        }
                    } else {
                        try target.append(allocator, head_forced_ptr.*);
                    }
                    vm.valueDeinit(&head_forced_ptr.*, allocator);
                } else {
                    try target.append(allocator, try vm.clone(&head, allocator));
                }
                // Move to tail
                const tail = try vm.clone(&cdata.tail, allocator);
                vm.valueDeinit(&current, cdata.allocator);
                current = tail;
            },
            .list => {
                for (current.list.items.items) |item| {
                    if (std.meta.activeTag(item) == .lazy_seq) {
                        const forced_ptr = try forceLazySeq(allocator, item, frame, depth + 1);
                        if (std.meta.activeTag(forced_ptr.*) == .list) {
                            for (forced_ptr.list.items.items) |fi| {
                                try target.append(allocator, try vm.clone(&fi, allocator));
                            }
                        }
                        vm.valueDeinit(&forced_ptr.*, allocator);
                    } else {
                        try target.append(allocator, try vm.clone(&item, allocator));
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
                        try target.append(allocator, try vm.clone(&fi, allocator));
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
        const result_ptr = try evalRecV(allocator, &body_val, thunk_frame, depth, null);

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
                        try final_list.append(allocator, try vm.clone(&head_item, allocator));
                    }
                    const tail_forced_ptr = try forceLazySeq(allocator, result_ptr.*.list.items.items[1], frame, depth + 1);
                    if (std.meta.activeTag(tail_forced_ptr.*) == .list) {
                        for (tail_forced_ptr.*.list.items.items) |fi| {
                            try final_list.append(allocator, try vm.clone(&fi, allocator));
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
                                    try final_list.append(allocator, try vm.clone(&fi, allocator));
                                }
                            }
                            vm.valueDeinit(&forced_ptr.*, allocator);
                        } else {
                            try final_list.append(allocator, try vm.clone(&item, allocator));
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
                                try final_list.append(allocator, try vm.clone(&fi, allocator));
                            }
                        }
                        vm.valueDeinit(&forced_ptr.*, allocator);
                    } else {
                        try final_list.append(allocator, try vm.clone(&item, allocator));
                    }
                }
            },
            .nil => {}, // empty sequence
            .lazy_seq => {
                // Recursively force for doall/dorun
                const forced_ptr = try forceLazySeq(allocator, result_ptr.*, frame, depth + 1);
                if (std.meta.activeTag(forced_ptr.*) == .list) {
                    for (forced_ptr.list.items.items) |fi| {
                        try final_list.append(allocator, try vm.clone(&fi, allocator));
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
fn bindParam(allocator: Allocator, param: Value, arg: Value, env: *Env) anyerror!void {
    switch (std.meta.activeTag(param)) {
        .symbol => {
            try env.put(param.symbol, try vm.clone(&arg, allocator));
        },
        .vector => {
            // Destructure: param is [x y z], arg should be a collection
            var arg_items: []const Value = undefined;
            switch (std.meta.activeTag(arg)) {
                .list => arg_items = arg.list.items.items,
                .vector => arg_items = arg.vector.items.items,
                else => return error.TypeError,
            }
            if (param.vector.items.items.len != arg_items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.vector.items.items.len) : (i += 1) {
                try bindParam(allocator, param.vector.items.items[i], arg_items[i], env);
            }
        },
        .list => {
            // Same as vector but from a list
            if (param.list.items.items.len != arg.list.items.items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.list.items.items.len) : (i += 1) {
                try bindParam(allocator, param.list.items.items[i], arg.list.items.items[i], env);
            }
        },
        else => {}, // Ignore other param types
    }
}

// Frame version of bindParam
fn bindParamFrame(allocator: Allocator, param: Value, arg: Value, frame: *vm.Frame) anyerror!void {
    switch (std.meta.activeTag(param)) {
        .symbol => {
            try frame.put(param.symbol, try vm.clone(&arg, allocator));
        },
        .vector => {
            // Destructure: param is [x y z], arg should be a collection
            var arg_items: []const Value = undefined;
            switch (std.meta.activeTag(arg)) {
                .list => arg_items = arg.list.items.items,
                .vector => arg_items = arg.vector.items.items,
                else => return error.TypeError,
            }
            if (param.vector.items.items.len != arg_items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.vector.items.items.len) : (i += 1) {
                try bindParamFrame(allocator, param.vector.items.items[i], arg_items[i], frame);
            }
        },
        .list => {
            // Same as vector but from a list
            if (param.list.items.items.len != arg.list.items.items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.list.items.items.len) : (i += 1) {
                try bindParamFrame(allocator, param.list.items.items[i], arg.list.items.items[i], frame);
            }
        },
        else => {}, // Ignore other param types
    }
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
fn evalCase(allocator: Allocator, forms: []const Value, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    if (forms.len < 1) return error.ArityError;

    // Expression evaluated synchronously (we need to compare against test values)
    const expr_val_ptr = try evalRecV(allocator, &forms[0], frame, depth, null);
    defer vm.valueDeinit(expr_val_ptr, allocator);

    var i: usize = 1;
    while (i < forms.len) : (i += 2) {
        const test_form = forms[i];
        if (std.meta.activeTag(test_form) == .keyword and std.mem.eql(u8, test_form.keyword, "else")) {
            if (i + 1 >= forms.len) return error.ArityError;
            // Body in tail position
            return try evalRec(allocator, &forms[i + 1], frame, depth, ctx);
        }

        // Test form evaluated synchronously
        const test_val_ptr = try evalRecV(allocator, &test_form, frame, depth, null);
        defer vm.valueDeinit(test_val_ptr, allocator);

        if (vm.equals(expr_val_ptr.*, test_val_ptr.*)) {
            if (i + 1 >= forms.len) return error.ArityError;
            // Body in tail position
            return try evalRec(allocator, &forms[i + 1], frame, depth, ctx);
        }
    }

    return .{ .value = try allocValue(allocator, vm.nilValue()) };
}

// ============================================================================
// Extracted special form evaluators
// These were inline in evalList. Extracting them reduces evalList's stack
// frame from ~48 KB to a thin dispatcher. Each handler has its own smaller
// frame allocated only when that specific form is evaluated.
// ============================================================================

/// (quote form) — return form unevaluated
fn evalQuote(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = frame;
    _ = depth;
    _ = ctx;
    if (l.items.len != 2) return error.ArityError;
    return .{ .value = try vm.cloneGC(&l.items[1], allocator) };
}

/// (quit) / (exit) — signal REPL to exit
fn evalQuit(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = allocator;
    _ = l;
    _ = frame;
    _ = depth;
    _ = ctx;
    return error.ReplExit;
}

/// (quasiquote form) — template with unquote
fn evalQuasiquote(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    if (l.items.len != 2) return error.ArityError;
    // Pass the full Frame so unquote can resolve local bindings (e.g. macro parameters)
    const result = try eval_macro.unquoteProcess(allocator, l.items[1], frame, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

/// (def name value?) — define in current namespace
fn evalDef(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const eval_idx: usize = if (l.items.len >= 3) 2 else 1;
    // Value evaluated synchronously (we need to bind it)
    const val_ptr = try evalRecV(allocator, &l.items[eval_idx], frame, depth + 1, null);
    const persistent_val = try vm.clone(&val_ptr.*, allocator);
    try bindInCurrentNamespace(frame.root_env, sym.symbol, persistent_val);
    return .{ .value = try vm.cloneGC(&sym, allocator) };
}

/// (if test then else?) — conditional
fn evalIf(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    if (l.items.len < 2 or l.items.len > 4) return error.ArityError;
    // Condition evaluated synchronously (we need to inspect truthiness)
    const cond_ptr = try evalRecV(allocator, &l.items[1], frame, depth + 1, null);
    const truthy = vm.isTruthy(cond_ptr.*);
    vm.valueDeinit(cond_ptr, allocator);
    if (truthy) {
        // Then-branch in tail position — use evalRec for trampoline
        if (l.items.len >= 3) return try evalRec(allocator, &l.items[2], frame, depth + 1, ctx);
        return .{ .value = try allocValue(allocator, vm.nilValue()) };
    } else {
        // Else-branch in tail position — use evalRec for trampoline
        if (l.items.len >= 4) return try evalRec(allocator, &l.items[3], frame, depth + 1, ctx);
        return .{ .value = try allocValue(allocator, vm.nilValue()) };
    }
}

/// (when test body...) — if with implicit do
fn evalWhen(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    if (l.items.len < 2) return error.ArityError;
    // Condition evaluated synchronously
    const cond_ptr = try evalRecV(allocator, &l.items[1], frame, depth + 1, null);
    const truthy = vm.isTruthy(cond_ptr.*);
    vm.valueDeinit(cond_ptr, allocator);
    if (truthy) {
        const body = l.items[2..];
        if (body.len == 0) {
            return .{ .value = try allocValue(allocator, vm.nilValue()) };
        }
        // Non-tail forms evaluated synchronously
        var do_result: Value = vm.nilValue();
        errdefer vm.valueDeinit(&do_result, allocator);
        for (body[0 .. body.len - 1]) |form| {
            const result_ptr = try evalRecV(allocator, &form, frame, depth + 1, null);
            vm.valueDeinit(&do_result, allocator);
            do_result = result_ptr.*;
        }
        // Last form in tail position
        return try evalRec(allocator, &body[body.len - 1], frame, depth + 1, ctx);
    }
    return .{ .value = try allocValue(allocator, vm.nilValue()) };
}

/// (do body...) — evaluate a sequence of forms
fn evalDo(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const body = l.items[1..];
    if (body.len == 0) {
        return .{ .value = try allocValue(allocator, vm.nilValue()) };
    }
    // Non-tail forms evaluated synchronously (no trampoline — we discard results)
    var last_ptr: ?*Value = null;
    errdefer {
        if (last_ptr) |p| {
            vm.valueDeinit(p, allocator);
            allocator.destroy(p);
        }
    }
    for (body[0 .. body.len - 1]) |form| {
        if (last_ptr) |p| {
            vm.valueDeinit(p, allocator);
            allocator.destroy(p);
        }
        last_ptr = try evalRecV(allocator, &form, frame, depth + 1, null);
    }
    // Last form in tail position — use evalRec for trampoline
    const tail_result = try evalRec(allocator, &body[body.len - 1], frame, depth + 1, ctx);
    if (last_ptr) |p| {
        vm.valueDeinit(p, allocator);
        allocator.destroy(p);
    }
    return tail_result;
}

/// (defn name docstring? ([params] body...)+) — define named function
fn evalDefn(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
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

    const fn_env: Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = frame.root_env,
        .ns_manager = null,
    };
    var fn_val = try vm.fnValueNamedWithDoc(allocator, arities, fn_env, false, null, docstring);
    const persistent_fn = try vm.clone(&fn_val, allocator);
    vm.valueDeinit(&fn_val, allocator);
    try bindInCurrentNamespace(frame.root_env, fname.symbol, persistent_fn);
    return .{ .value = try vm.cloneGC(&fname, allocator) };
}

/// (fn name? ([params] body...)+) — anonymous function
fn evalFn(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
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
    return .{ .value = try allocValue(allocator, fn_val) };
}

/// (defmacro name docstring? ([params] body...)+) — define a macro
fn evalDefmacro(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
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

    const fn_env: Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = frame.root_env,
        .ns_manager = null,
    };
    var macro_fn = try vm.fnValueNamedWithDoc(allocator, arities, fn_env, true, null, docstring);
    const persistent_macro = try vm.clone(&macro_fn, allocator);
    vm.valueDeinit(&macro_fn, allocator);
    try bindInCurrentNamespace(frame.root_env, macro_name.symbol, persistent_macro);
    return .{ .value = try vm.cloneGC(&macro_name, allocator) };
}

/// (set! name value) — modify a variable
fn evalSetBang(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    if (l.items.len != 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    // Value evaluated synchronously (we need to bind it)
    const val_ptr = try evalRecV(allocator, &l.items[2], frame, depth + 1, null);
    const persistent_val = try vm.clone(&val_ptr.*, allocator);
    // Write to current frame's overlay (not root namespace env)
    try frame.put(sym.symbol, persistent_val);
    return .{ .value = val_ptr };
}

/// (recur new-arg*) — tail recursion signal
fn evalRecur(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    if (l.items.len < 2) return error.ArityError;
    var results: list.List = .empty;
    errdefer results.deinit(allocator);
    try results.append(allocator, try vm.symValue(allocator, "__recur__"));
    for (l.items[1..]) |arg| {
        // Args evaluated synchronously
        const ptr = try evalRecV(allocator, &arg, frame, depth + 1, null);
        try results.append(allocator, ptr.*);
    }
    return .{ .value = try allocValue(allocator, try vm.listValue(allocator, results)) };
}

/// (var name value?) — create a mutable var
fn evalVar(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const sym = l.items[1];
    if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
    const val_ptr = if (l.items.len >= 3)
        // Value evaluated synchronously
        try evalRecV(allocator, &l.items[2], frame, depth + 1, null)
    else
        try allocValue(allocator, vm.nilValue());
    const persistent_val = try vm.clone(&val_ptr.*, allocator);
    // Write to current frame's overlay (local var)
    try frame.put(sym.symbol, persistent_val);
    return .{ .value = try vm.cloneGC(&sym, allocator) };
}

/// (deref form) / (@ form) — get value from atom/var/reduced/future
fn evalDeref(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    if (l.items.len != 2) return error.ArityError;
    // Arg evaluated synchronously (we need to inspect the type)
    const arg_ptr = try evalRecV(allocator, &l.items[1], frame, depth + 1, null);
    if (std.meta.activeTag(arg_ptr.*) == .atom) {
        const data = arg_ptr.*.atom;
        const val = try vm.clone(&data.value, allocator);
        vm.valueDeinit(&arg_ptr.*, allocator);
        return .{ .value = try allocValue(allocator, val) };
    }
    if (std.meta.activeTag(arg_ptr.*) == .reduced) {
        const data = arg_ptr.*.reduced;
        const val = try vm.clone(&data.*, allocator);
        vm.valueDeinit(&arg_ptr.*, allocator);
        return .{ .value = try allocValue(allocator, val) };
    }
    if (std.meta.activeTag(arg_ptr.*) == .future) {
        // Deref a future — blocks until done
        const future_val = arg_ptr.*;
        vm.valueDeinit(&arg_ptr.*, allocator);
        var deref_args: list.List = .empty;
        errdefer deref_args.deinit(allocator);
        try deref_args.append(allocator, future_val);
        const result = try threading.core_deref_future(testSelf(), &deref_args, frame.root_env);
        return .{ .value = try allocValue(allocator, result) };
    }
    if (std.meta.activeTag(arg_ptr.*) == .promise) {
        // Deref a promise — blocks until delivered
        const promise_val = arg_ptr.*;
        vm.valueDeinit(&arg_ptr.*, allocator);
        var deref_args: list.List = .empty;
        errdefer deref_args.deinit(allocator);
        try deref_args.append(allocator, promise_val);
        const result = try threading.core_deref_promise(testSelf(), &deref_args, frame.root_env);
        return .{ .value = try allocValue(allocator, result) };
    }
    vm.valueDeinit(&arg_ptr.*, allocator);
    return .{ .value = try allocValue(allocator, vm.nilValue()) };
}

/// Helper for evalDeref: create a dummy self Value for builtin calls.
fn testSelf() *const vm.Value {
    return undefined; // builtin functions ignore self
}

/// (or form*) — short-circuit or
fn evalOr(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const forms = l.items[1..];
    if (forms.len == 0) {
        return .{ .value = try allocValue(allocator, vm.nilValue()) };
    }
    // Non-tail forms evaluated synchronously
    var last_ptr: ?*Value = null;
    errdefer {
        if (last_ptr) |p| {
            vm.valueDeinit(p, allocator);
            allocator.destroy(p);
        }
    }
    for (forms[0 .. forms.len - 1]) |form_item| {
        const val_ptr = try evalRecV(allocator, &form_item, frame, depth + 1, null);
        if (vm.isTruthy(val_ptr.*)) {
            if (last_ptr) |p| {
                vm.valueDeinit(p, allocator);
                allocator.destroy(p);
            }
            return .{ .value = val_ptr };
        }
        if (last_ptr) |p| {
            vm.valueDeinit(p, allocator);
            allocator.destroy(p);
        }
        last_ptr = val_ptr;
    }
    // Last form in tail position
    const tail_result = try evalRec(allocator, &forms[forms.len - 1], frame, depth + 1, ctx);
    if (last_ptr) |p| {
        vm.valueDeinit(p, allocator);
        allocator.destroy(p);
    }
    return tail_result;
}

/// (and form*) — short-circuit and
fn evalAnd(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const forms = l.items[1..];
    if (forms.len == 0) {
        return .{ .value = try allocValue(allocator, vm.boolValue(true)) };
    }
    // Non-tail forms evaluated synchronously
    for (forms[0 .. forms.len - 1]) |form_item| {
        const val_ptr = try evalRecV(allocator, &form_item, frame, depth + 1, null);
        if (!vm.isTruthy(val_ptr.*)) return .{ .value = val_ptr };
        vm.valueDeinit(val_ptr, allocator);
    }
    // Last form in tail position
    return try evalRec(allocator, &forms[forms.len - 1], frame, depth + 1, ctx);
}

/// (binding [var1 val1 ...] body...) — dynamic variable binding
fn evalBinding(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    if (l.items.len < 3) return error.ArityError;
    const bindings = l.items[1];
    if (std.meta.activeTag(bindings) != .vector) return error.TypeError;
    const child_frame = try frame.createChild(allocator);
    // Use detachFromParent instead of deinit: child frames on trampoline may reference this
    defer child_frame.releaseFromParent(allocator);

    var i: usize = 0;
    while (i < bindings.vector.items.items.len) : (i += 2) {
        const sym = bindings.vector.items.items[i];
        if (std.meta.activeTag(sym) != .symbol) return error.TypeError;
        // Binding values evaluated synchronously
        const val_ptr = try evalRecV(allocator, &bindings.vector.items.items[i + 1], child_frame, depth + 1, null);
        try child_frame.put(sym.symbol, val_ptr.*);
    }
    const body = l.items[2..];
    if (body.len == 0) {
        return .{ .value = try allocValue(allocator, vm.nilValue()) };
    }
    // Non-tail forms evaluated synchronously
    var do_result: Value = vm.nilValue();
    errdefer vm.valueDeinit(&do_result, allocator);
    for (body[0 .. body.len - 1]) |form| {
        const result_ptr = try evalRecV(allocator, &form, child_frame, depth + 1, null);
        vm.valueDeinit(&do_result, allocator);
        do_result = result_ptr.*;
    }
    // Last form in tail position
    return try evalRec(allocator, &body[body.len - 1], child_frame, depth + 1, ctx);
}

/// (lazy-seq body...) — create a lazy sequence
fn evalLazySeq(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    _ = depth;
    if (l.items.len < 2) return error.ArityError;
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "do"));
    for (l.items[1..]) |form| {
        try body.append(allocator, try vm.clone(&form, allocator));
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
    return .{ .value = try allocValue(allocator, vm.lazySeqValue(thunk)) };
}

/// Capture the effective environment of a Frame into a flat Env.
/// Walks the Frame chain from parent to current so that closer bindings override.
fn captureFrameEnv(allocator: Allocator, frame: *vm.Frame) anyerror!Env {
    var env = try frame.root_env.clone(allocator);
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
                try env.put(entry.key.symbol, try vm.clone(&entry.val, allocator));
            }
        }
    }
    return env;
}

/// (dorun n? coll) — realize sequence for side effects, return nil
fn evalDorun(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
    const dorun_args = l.items[1..];
    var n: ?usize = null;
    var coll_form: Value = undefined;
    if (dorun_args.len == 2) {
        const n_val_ptr = try evalRecV(allocator, &dorun_args[0], frame, depth + 1, null);
        defer vm.valueDeinit(&n_val_ptr.*, allocator);
        const n_int: i64 = switch (std.meta.activeTag(n_val_ptr.*)) {
            .integer => n_val_ptr.*.integer,
            .float => @as(i64, @intFromFloat(n_val_ptr.*.float)),
            else => return error.TypeError,
        };
        n = @as(usize, @intCast(n_int));
        coll_form = dorun_args[1];
    } else {
        coll_form = dorun_args[0];
    }
    const coll_ptr = try evalRecV(allocator, &coll_form, frame, depth + 1, null);
    defer vm.valueDeinit(&coll_ptr.*, allocator);

    var coll = coll_ptr.*;
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
        else => return .{ .value = try allocValue(allocator, vm.nilValue()) },
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
    return .{ .value = try allocValue(allocator, vm.nilValue()) };
}

/// (doall coll) — realize lazy sequences and return result
fn evalDoall(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    _ = ctx;
    if (l.items.len != 2) return error.ArityError;
    const coll_ptr = try evalRecV(allocator, &l.items[1], frame, depth + 1, null);
    if (std.meta.activeTag(coll_ptr.*) == .lazy_seq) {
        const forced = try sequences.forceLazySeqHelper(allocator, coll_ptr.*);
        vm.valueDeinit(&coll_ptr.*, allocator);
        return .{ .value = try vm.cloneGC(&forced, allocator) };
    }
    if (std.meta.activeTag(coll_ptr.*) == .nil) {
        vm.valueDeinit(&coll_ptr.*, allocator);
        return .{ .value = try allocValue(allocator, try vm.listValue(allocator, list.empty())) };
    }
    return .{ .value = try vm.cloneGC(&coll_ptr.*, allocator) };
}

/// (extend atype protocol mmap & more...) — add protocol implementations
fn evalExtend(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    if (l.items.len < 4) return error.ArityError;
    var ext_args: list.List = .empty;
    errdefer ext_args.deinit(allocator);
    try ext_args.append(allocator, try vm.clone(&l.items[1], allocator));
    var ei: usize = 2;
    while (ei < l.items.len) : (ei += 1) {
        const ptr = try evalRecV(allocator, &l.items[ei], frame, depth + 1, null);
        try ext_args.append(allocator, ptr.*);
    }
    const result = try protocols.evalExtend(allocator, ext_args, frame.root_env, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

// ============================================================================
// Wrapper functions for external module handlers
// These adapt the unified SpecialFormFn signature to external module APIs.
// ============================================================================

fn evalNsForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try eval_ns.evalNs(allocator, l.*, frame.root_env, depth, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalInNsForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try eval_ns.evalInNs(allocator, l.*, frame.root_env, depth, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalDefprotocolForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try protocols.evalDefProtocol(allocator, l.*, frame.root_env, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalExtendTypeForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try protocols.evalExtendType(allocator, l.*, frame.root_env, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalExtendProtocolForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try protocols.evalExtendProtocol(allocator, l.*, frame.root_env, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalDefrecordForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try records.evalDefRecord(allocator, l.*, frame.root_env, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalThreadLastForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try eval_thread.evalThreadLast(allocator, l.items[1..], frame, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalThreadFirstForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try eval_thread.evalThreadFirst(allocator, l.items[1..], frame, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalCondThreadFirstForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try eval_thread.evalCondThreadFirst(allocator, l.items[1..], frame, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalCondThreadLastForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    const result = try eval_thread.evalCondThreadLast(allocator, l.items[1..], frame, depth + 1, ctx);
    return .{ .value = try allocValue(allocator, result) };
}

fn evalCaseForm(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize, ctx: ?*TrampolineStack) anyerror!EvalResult {
    return try evalCase(allocator, l.items[1..], frame, depth + 1, ctx);
}
