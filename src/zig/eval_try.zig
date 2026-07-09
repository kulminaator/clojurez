// eval_try.zig — try/catch/finally special form implementation
//
// Implements the (try body* (catch Type sym body*)* (finally cleanup*)?) form.
// Handles exception matching via the type hierarchy (exceptionIsA).

const std = @import("std");
const vm = @import("value.zig");
const list = @import("list.zig");
const Value = vm.Value;
const eval = @import("eval.zig");
const exception_mod = @import("exception.zig");

const Allocator = std.mem.Allocator;

/// A single catch clause: (catch Type sym body*)
const TryCatchClause = struct {
    type_kw: []const u8, // Exception type keyword (e.g. "clojure.lang/Exception")
    sym: []const u8,     // Bound symbol name
    body: Value,         // Body form (do-wrapped)
};

/// Parsed structure of a try form.
const ParsedTryForm = struct {
    body_forms: []Value,
    catch_clauses: []TryCatchClause,
    finally_forms: []Value,
};

/// Clean up resources allocated by parseTryForm.
fn parseTryFormCleanup(allocator: Allocator, parsed: *ParsedTryForm) void {
    for (parsed.body_forms) |*form| {
        vm.valueDeinit(form, allocator);
    }
    allocator.free(parsed.body_forms);

    for (parsed.catch_clauses) |*clause| {
        allocator.free(clause.type_kw);
        allocator.free(clause.sym);
        vm.valueDeinit(&clause.body, allocator);
    }
    allocator.free(parsed.catch_clauses);

    for (parsed.finally_forms) |*form| {
        vm.valueDeinit(form, allocator);
    }
    allocator.free(parsed.finally_forms);
}

/// Parse the try form structure into body, catch clauses, and optional finally.
/// Syntax: (try body* (catch Type sym body*)* (finally cleanup*)?)
fn parseTryForm(allocator: Allocator, forms: []const Value) anyerror!ParsedTryForm {
    var body_forms: std.ArrayListUnmanaged(Value) = .empty;
    var catch_clauses: std.ArrayListUnmanaged(TryCatchClause) = .empty;
    var finally_forms: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        body_forms.deinit(allocator);
        catch_clauses.deinit(allocator);
        finally_forms.deinit(allocator);
    }

    var i: usize = 0;
    var found_catch = false;
    var found_finally = false;

    while (i < forms.len) : (i += 1) {
        const form = forms[i];

        if (std.meta.activeTag(form) == .list and form.list.items.items.len > 0) {
            const op = form.list.items.items[0];

            if (std.meta.activeTag(op) == .symbol) {
                if (std.mem.eql(u8, op.symbol, "catch")) {
                    found_catch = true;
                    // Parse: (catch Type sym body*)
                    if (form.list.items.items.len < 4) return error.ArityError;
                    const type_form = form.list.items.items[1];
                    const sym_form = form.list.items.items[2];

                    // Resolve the catch type
                    const type_kw = try resolveCatchType(allocator, type_form);

                    if (std.meta.activeTag(sym_form) != .symbol) return error.TypeError;

                    // Wrap body in do
                    var body_list: list.List = .empty;
                    errdefer body_list.deinit(allocator);
                    try body_list.append(allocator, try vm.symValue(allocator, "do"));
                    for (form.list.items.items[3..]) |bf| {
                        try body_list.append(allocator, try vm.shallowClone(&bf, allocator));
                    }

                    try catch_clauses.append(allocator, TryCatchClause{
                        .type_kw = type_kw,
                        .sym = try allocator.dupe(u8, sym_form.symbol),
                        .body = try vm.listValue(allocator, body_list),
                    });

                } else if (std.mem.eql(u8, op.symbol, "finally")) {
                    found_finally = true;
                    // Parse: (finally body*)
                    for (form.list.items.items[1..]) |ff| {
                        try finally_forms.append(allocator, try vm.shallowClone(&ff, allocator));
                    }
                    // finally must be last
                    if (i + 1 < forms.len) return error.ArityError;
                }
            }
        }

        if (found_catch or found_finally) {
            continue;
        }

        // Body form
        try body_forms.append(allocator, try vm.shallowClone(&form, allocator));
    }

    return ParsedTryForm{
        .body_forms = body_forms.items,
        .catch_clauses = catch_clauses.items,
        .finally_forms = finally_forms.items,
    };
}

/// Resolve a catch type form to a hierarchy string.
/// - Keywords: ":foo/bar" → "foo/bar" (direct)
/// - Symbols: "Exception" → "clojure.lang/Exception" (known type lookup)
/// - Symbols: "foo/bar" → "foo/bar" (qualified, use as-is)
fn resolveCatchType(allocator: Allocator, type_form: Value) anyerror![]const u8 {
    return switch (std.meta.activeTag(type_form)) {
        .keyword => allocator.dupe(u8, type_form.keyword),
        .symbol => blk: {
            const sym = type_form.symbol;
            // If already qualified (contains /), use as-is
            if (std.mem.indexOfScalar(u8, sym, '/')) |_| {
                break :blk try allocator.dupe(u8, sym);
            }
            // Check known built-in exception type names
            const known_types = [_][]const u8{
                "Throwable", "Exception", "RuntimeException",
                "ArithmeticException", "IllegalArgumentException",
                "IllegalStateException", "NullPointerException",
                "IndexOutOfBoundsException", "ExceptionInfo",
                "IOException", "FileNotFoundException",
                "SocketTimeoutException", "TimeoutException",
            };
            for (known_types) |known| {
                if (std.mem.eql(u8, sym, known)) {
                    break :blk try std.fmt.allocPrint(allocator, "clojure.lang/{s}", .{sym});
                }
            }
            // Unknown symbol — treat as clojure.lang type (best effort)
            break :blk try std.fmt.allocPrint(allocator, "clojure.lang/{s}", .{sym});
        },
        else => return error.TypeError,
    };
}

/// Evaluate finally forms. Returns the last value or nil.
/// Exceptions during finally evaluation are swallowed (finally always runs).
fn evalTryFinally(allocator: Allocator, forms: []const Value, frame: *vm.Frame, depth: usize) anyerror!*Value {
    var last: ?*Value = null;
    errdefer {
        if (last) |v| {
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        }
    }
    for (forms) |form| {
        if (last) |v| {
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        }
        last = try eval.evalRecV(allocator, &form, frame, depth);
    }
    return last orelse try eval.allocValue(allocator, vm.nilValue());
}

/// Evaluate try body forms. Returns the last body value on success.
/// On exception, returns null and sets had_exception via exception state.
/// On other errors, propagates the error.
fn evalTryBody(allocator: Allocator, forms: []const Value, frame: *vm.Frame, depth: usize) anyerror!?*Value {
    if (forms.len == 0) return null;

    // Evaluate all but last form (discard results)
    var idx: usize = 0;
    while (idx < forms.len - 1) : (idx += 1) {
        const v = eval.evalRecV(allocator, &forms[idx], frame, depth) catch |err| {
            if (err == eval.EvalError.Exception) return null;
            return err;
        };
        vm.valueDeinit(v, allocator);
        allocator.destroy(v);
    }

    // Evaluate last body form — keep the result
    const last_val = eval.evalRecV(allocator, &forms[forms.len - 1], frame, depth) catch |err| {
        if (err == eval.EvalError.Exception) return null;
        return err;
    };
    return last_val;
}

/// (try body* (catch Type sym body*)* (finally cleanup*)?)
pub fn evalTry(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval.EvalResult {
    if (l.items.len < 2) return error.ArityError;

    // Parse the try form structure
    var parsed = try parseTryForm(allocator, l.items[1..]);
    defer parseTryFormCleanup(allocator, &parsed);

    // Clear any prior exception state (nested try must not see outer exceptions)
    eval.clearException();

    // Evaluate body forms
    const body_result = try evalTryBody(allocator, parsed.body_forms, frame, depth);

    // Check if an exception was thrown during body evaluation
    const had_exception = eval.hasException();

    // --- Exception handling ---
    if (had_exception) {
        const ex = eval.getException() orelse {
            // Run finally and re-raise
            if (parsed.finally_forms.len > 0) {
                _ = evalTryFinally(allocator, parsed.finally_forms, frame, depth) catch {};
            }
            return eval.EvalError.Exception;
        };

        // Try to match against catch clauses
        for (parsed.catch_clauses) |clause| {
            if (exception_mod.exceptionIsA(ex.type_kw, clause.type_kw)) {
                // Match! Bind exception to caught symbol
                try frame.put(clause.sym, vm.exceptionValueFromData(ex));
                eval.clearException();

                // Evaluate catch body
                const catch_result = eval.evalRec(allocator, &clause.body, frame, depth) catch |err| {
                    if (err == eval.EvalError.Exception) {
                        // Exception from catch body — run finally before propagating
                        if (parsed.finally_forms.len > 0) {
                            _ = evalTryFinally(allocator, parsed.finally_forms, frame, depth) catch {};
                        }
                        return err;
                    }
                    return err;
                };

                // Run finally before returning
                if (parsed.finally_forms.len > 0) {
                    _ = evalTryFinally(allocator, parsed.finally_forms, frame, depth) catch {};
                }
                return catch_result;
            }
        }

        // No catch matched — run finally and re-raise
        if (parsed.finally_forms.len > 0) {
            _ = evalTryFinally(allocator, parsed.finally_forms, frame, depth) catch {};
        }
        // Do NOT clear exception — caller needs it
        return eval.EvalError.Exception;
    }

    // --- Normal completion ---
    // Run finally if present
    if (parsed.finally_forms.len > 0) {
        _ = evalTryFinally(allocator, parsed.finally_forms, frame, depth) catch {};
    }

    // Return the last body value, or nil if no body
    if (body_result) |v| {
        return .{ .value = v };
    }
    return .{ .value = try eval.allocValue(allocator, vm.nilValue()) };
}
