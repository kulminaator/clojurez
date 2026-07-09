// exception.zig — Exception type hierarchy and builtins
//
// Provides:
// - Built-in exception type hierarchy (Throwable, Exception, etc.)
// - exceptionIsA() for hierarchy checking
// - derive/parents/isa? builtins for extensible hierarchy
// - ex-info/ex-data/ex-message/ex-cause builtins

const std = @import("std");
const vm = @import("value.zig");
const list = @import("list.zig");
const Value = vm.Value;
const Env = vm.Env;
const gc_mod = @import("gc.zig");

const Allocator = std.mem.Allocator;

// Helper: tag a string data allocation so the GC doesn't misidentify it.
fn tagStringData(ptr: *anyopaque) void {
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(ptr, gc_mod.GCObjectType.string_data);
    }
}

// ============================================================
// Type hierarchy: child string → parent string mapping.
// ============================================================

pub var hierarchy: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
pub var hierarchy_mutex: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

/// Initialize the built-in exception hierarchy at VM startup.
pub fn initExceptionHierarchy(allocator: Allocator) anyerror!void {
    try hierarchy.put(allocator, "clojure.lang/Exception", "clojure.lang/Throwable");
    try hierarchy.put(allocator, "clojure.lang/RuntimeException", "clojure.lang/Exception");
    try hierarchy.put(allocator, "clojure.lang/ArithmeticException", "clojure.lang/RuntimeException");
    try hierarchy.put(allocator, "clojure.lang/IllegalArgumentException", "clojure.lang/RuntimeException");
    try hierarchy.put(allocator, "clojure.lang/IllegalStateException", "clojure.lang/RuntimeException");
    try hierarchy.put(allocator, "clojure.lang/NullPointerException", "clojure.lang/RuntimeException");
    try hierarchy.put(allocator, "clojure.lang/IndexOutOfBoundsException", "clojure.lang/RuntimeException");
    try hierarchy.put(allocator, "clojure.lang/ExceptionInfo", "clojure.lang/RuntimeException");
    try hierarchy.put(allocator, "clojure.lang/IOException", "clojure.lang/Exception");
    try hierarchy.put(allocator, "clojure.lang/FileNotFoundException", "clojure.lang/IOException");
    try hierarchy.put(allocator, "clojure.lang/SocketTimeoutException", "clojure.lang/IOException");
    try hierarchy.put(allocator, "clojure.lang/TimeoutException", "clojure.lang/Exception");
}

/// Check if child is-a parent (following hierarchy chain).
pub fn exceptionIsA(child: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, child, parent)) return true;
    var current = child;
    var iterations: usize = 0;
    while (iterations < 64) : (iterations += 1) {
        const p = hierarchy.get(current) orelse return false;
        if (std.mem.eql(u8, p, parent)) return true;
        current = p;
    }
    return false;
}

// ============================================================
// Helper: extract string from keyword/symbol/string value
// ============================================================

fn typeToString(val: Value, allocator: Allocator) anyerror!?[]const u8 {
    return switch (std.meta.activeTag(val)) {
        .keyword => try allocator.dupe(u8, val.keyword),
        .symbol => try allocator.dupe(u8, val.symbol),
        .string => try allocator.dupe(u8, val.string),
        else => null,
    };
}

// ============================================================
// Builtins: derive, parents, isa?
// ============================================================

pub fn deriveBuiltin(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    // (derive child parent)
    if (args.items.len != 2) return error.ArityError;
    const allocator = env.allocator;
    const child = try typeToString(args.items[0], allocator) orelse return error.TypeError;
    errdefer allocator.free(child);
    const parent = try typeToString(args.items[1], allocator) orelse return error.TypeError;
    errdefer allocator.free(parent);

    const child_duped = try allocator.dupe(u8, child);
    errdefer allocator.free(child_duped);
    const parent_duped = try allocator.dupe(u8, parent);
    errdefer allocator.free(parent_duped);

    // Tag strings for GC so they survive collection
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(child_duped.ptr))));
    tagStringData(@as(*anyopaque, @ptrCast(@constCast(parent_duped.ptr))));

    // Acquire spinlock
    while (hierarchy_mutex.cmpxchgStrong(0, 1, .acq_rel, .monotonic) != null) {}
    defer hierarchy_mutex.store(0, .release);
    try hierarchy.put(allocator, child_duped, parent_duped);
    return vm.nilValue();
}

pub fn parentsBuiltin(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    // (parents child) — returns #{ parent-keyword }
    if (args.items.len != 1) return error.ArityError;
    const allocator = env.allocator;
    const child = try typeToString(args.items[0], allocator) orelse return error.TypeError;
    defer allocator.free(child);

    const parent = hierarchy.get(child);
    if (parent) |p| {
        var items: std.ArrayListUnmanaged(Value) = .empty;
        errdefer {
            for (items.items) |*v| vm.valueDeinit(v, allocator);
            allocator.free(items.items);
        }
        try items.append(allocator, try vm.keywordValue(allocator, p));
        return try vm.setValue(allocator, items);
    }
    // No parent — return empty set
    return try vm.setValue(allocator, .empty);
}

pub fn isaBuiltin(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    // (isa? child parent)
    if (args.items.len != 2) return error.ArityError;
    const allocator = env.allocator;
    const child = try typeToString(args.items[0], allocator) orelse return error.TypeError;
    defer allocator.free(child);
    const parent = try typeToString(args.items[1], allocator) orelse return error.TypeError;
    defer allocator.free(parent);
    return vm.boolValue(exceptionIsA(child, parent));
}

// ============================================================
// Builtins: ex-info, ex-data, ex-message, ex-cause
// ============================================================

pub fn exInfo(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    // (ex-info msg data & [cause])
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;

    const allocator = env.allocator;
    const msg_val = args.items[0];
    const data_val = args.items[1];
    const cause_val = if (args.items.len >= 3) &args.items[2] else null;

    // Message must be a string or nil
    var message: []const u8 = "";
    if (std.meta.activeTag(msg_val) == .string) {
        message = msg_val.string;
    } else if (std.meta.activeTag(msg_val) != .nil) {
        // Coerce to string via fmt
        const msg_str = try vm.fmt(msg_val, allocator);
        defer allocator.free(msg_str);
        message = try allocator.dupe(u8, msg_str);
        defer allocator.free(message);
    }

    // Data must be a map
    if (std.meta.activeTag(data_val) != .map) return error.TypeError;
    const map_data = data_val.map; // *MapData — shared, never cloned

    // Check for :type key in data map (custom exception type)
    var type_kw: []const u8 = "clojure.lang/ExceptionInfo";
    for (data_val.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword, "type"))
        {
            type_kw = switch (std.meta.activeTag(entry.value)) {
                .keyword => entry.value.keyword,
                .string => entry.value.string,
                .symbol => entry.value.symbol,
                else => "clojure.lang/ExceptionInfo",
            };
            break;
        }
    }

    // Cause must be an exception or nil
    var cause: ?*vm.ExceptionData = null;
    if (cause_val) |cv| {
        if (std.meta.activeTag(cv.*) == .exception) {
            cause = cv.*.exception;
        } else if (std.meta.activeTag(cv.*) != .nil) {
            return error.TypeError;
        }
    }

    return try vm.exceptionValue(allocator, message, map_data, cause, type_kw);
}

pub fn exData(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 1) return error.ArityError;
    const ex_val = args.items[0];

    if (std.meta.activeTag(ex_val) == .exception) {
        const ed = ex_val.exception;
        // Return the data map — SHARED pointer, no clone
        return Value{ .map = ed.data };
    }
    return vm.nilValue();
}

pub fn exMessage(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const ex_val = args.items[0];

    if (std.meta.activeTag(ex_val) == .exception) {
        const ed = ex_val.exception;
        if (ed.message.len > 0) {
            return try vm.stringValue(env.allocator, ed.message);
        }
    }
    return vm.nilValue();
}

pub fn exCause(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 1) return error.ArityError;
    const ex_val = args.items[0];

    if (std.meta.activeTag(ex_val) == .exception) {
        const ed = ex_val.exception;
        if (ed.cause) |cause| {
            // SHARED pointer — no allocation, no clone
            return vm.exceptionValueFromData(cause);
        }
    }
    return vm.nilValue();
}

// ============================================================
// Registration
// ============================================================

pub fn registerExceptionFunctions(env: *Env) anyerror!void {
    try env.put("derive", vm.builtinFnValue(deriveBuiltin));
    try env.put("parents", vm.builtinFnValue(parentsBuiltin));
    try env.put("isa?", vm.builtinFnValue(isaBuiltin));
    try env.put("ex-info", vm.builtinFnValue(exInfo));
    try env.put("ex-data", vm.builtinFnValue(exData));
    try env.put("ex-message", vm.builtinFnValue(exMessage));
    try env.put("ex-cause", vm.builtinFnValue(exCause));
}
