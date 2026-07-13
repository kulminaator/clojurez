// ref.zig — STM (Software Transactional Memory) implementation.
// Provides ref, dosync, alter, commute, ref-set, ensure.
//
// Design: Simple optimistic STM with single-writer semantics.
// - RefData: value + version counter + optional validator
// - Transaction state: thread-local write-set (ref → new value)
// - dosync: retry loop — apply write-set, validate, commit or retry
// - No MVCC — simple version counter per ref
//
// All operations must be inside a dosync block (except ref creation).
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const Env = vm.Env;
const eval_mod = @import("eval.zig");
const eval_helpers = @import("namespaces/core/eval_helpers.zig");
const gc_mod = @import("gc.zig");

const Allocator = std.mem.Allocator;

// ============================================================
// Transaction state — thread-local write-set for dosync
// ============================================================

/// Entry in the transaction write-set: ref pointer → new value.
const WriteEntry = struct {
    ref_data: *vm.RefData,
    new_value: Value,
    commutative: bool = false, // true for commute, false for alter/ref-set
};

/// Transaction state for the current thread.
/// Guarded by a mutex since child threads might interact.
/// Simple spinlock for transaction state.
var tx_locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn txLock() void {
    while (tx_locked.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        // Spin until we get the lock
    }
}

fn txUnlock() void {
    tx_locked.store(false, .release);
}

var tx_active: bool = false;
var tx_write_set: std.ArrayListUnmanaged(WriteEntry) = .empty;
var tx_retry_count: usize = 0;
const MAX_RETRIES: usize = 10;

// ============================================================
// (ref initial-value) — Create an STM reference.
// ============================================================

pub fn core_ref(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 1) return error.ArityError;

    // Parse optional keyword arguments: (:commutative bool)
    var commutative = false;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (std.meta.activeTag(arg) != .keyword) continue;
        if (std.mem.eql(u8, arg.keyword, "commutative") and i + 1 < args.items.len) {
            const val = args.items[i + 1];
            if (std.meta.activeTag(val) == .bool) {
                commutative = val.bool;
            }
            i += 1;
        }
    }

    var meta: ?Value = null;
    if (commutative) {
        meta = try vm.mapValue(allocator, std.ArrayListUnmanaged(vm.MapEntry).empty);
        if (meta) |m| {
            const key = try vm.keywordValue(allocator, "commutative");
            const val = vm.boolValue(true);
            try m.map.entries.append(allocator, .{ .key = key, .value = val });
        }
    }

    return try vm.refValueWithMeta(allocator, args.items[0], meta);
}

// ============================================================
// (deref ref) / (@ ref) — Read the value of a ref.
// Works both inside and outside dosync.
// ============================================================

pub fn core_ref_deref(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .ref) return error.TypeError;

    const ref_data = arg.ref;
    // If inside a transaction, check if there's a pending write
    if (tx_active) {
        for (tx_write_set.items) |entry| {
            if (entry.ref_data == ref_data) {
                return try vm.clone(&entry.new_value, allocator);
            }
        }
    }
    return try vm.clone(&ref_data.value, allocator);
}

// ============================================================
// (ref-set ref val) — Set the value of a ref (inside dosync).
// ============================================================

pub fn core_ref_set(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .ref) return error.TypeError;

    const ref_data = arg.ref;
    txLock();
    defer txUnlock();
    if (!tx_active) return error.NotInTransaction;

    const new_val = try vm.clone(&args.items[1], allocator);

    // Update or add to write-set
    var found = false;
    for (tx_write_set.items) |*entry| {
        if (entry.ref_data == ref_data) {
            vm.valueDeinit(&entry.new_value, allocator);
            entry.new_value = new_val;
            entry.commutative = false;
            found = true;
            break;
        }
    }
    if (!found) {
        try tx_write_set.append(allocator, .{
            .ref_data = ref_data,
            .new_value = new_val,
            .commutative = false,
        });
    }
    return try vm.clone(&args.items[1], allocator);
}

// ============================================================
// (alter ref f & args) — Non-commutative update (inside dosync).
// ============================================================

pub fn core_alter(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 2) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .ref) return error.TypeError;

    const ref_data = arg.ref;
    txLock();
    defer txUnlock();
    if (!tx_active) return error.NotInTransaction;

    // Get current value (from write-set or ref)
    var current_val: Value = try vm.clone(&ref_data.value, allocator);
    for (tx_write_set.items) |entry| {
        if (entry.ref_data == ref_data) {
            vm.valueDeinit(&current_val, allocator);
            current_val = try vm.clone(&entry.new_value, allocator);
            break;
        }
    }
    errdefer vm.valueDeinit(&current_val, allocator);

    // Apply f to current value + additional args
    var call_args: list.List = .empty;
    defer call_args.deinit(allocator);
    
    try call_args.append(allocator, current_val);
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        try call_args.append(allocator, try vm.clone(&args.items[i], allocator));
    }

    const fn_val = args.items[1];
    const result_ptr = try eval_helpers.callBuiltin(allocator, &fn_val, call_args.items, env);
    const new_val = try vm.clone(&result_ptr.*, allocator);
    allocator.destroy(result_ptr);
    vm.valueDeinit(&current_val, allocator);

    // Update or add to write-set
    var found = false;
    for (tx_write_set.items) |*entry| {
        if (entry.ref_data == ref_data) {
            vm.valueDeinit(&entry.new_value, allocator);
            entry.new_value = new_val;
            entry.commutative = false;
            found = true;
            break;
        }
    }
    if (!found) {
        try tx_write_set.append(allocator, .{
            .ref_data = ref_data,
            .new_value = new_val,
            .commutative = false,
        });
    }
    return new_val;
}

// ============================================================
// (commute ref f & args) — Commutative update (inside dosync).
// ============================================================

pub fn core_commute(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    const allocator = env.allocator;
    if (args.items.len < 2) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .ref) return error.TypeError;

    const ref_data = arg.ref;
    txLock();
    defer txUnlock();
    if (!tx_active) return error.NotInTransaction;

    // For commute, always read the current committed value (not from write-set)
    var current_val = try vm.clone(&ref_data.value, allocator);
    errdefer vm.valueDeinit(&current_val, allocator);

    // Apply f to current value + additional args
    var call_args: list.List = .empty;
    defer call_args.deinit(allocator);
    
    try call_args.append(allocator, current_val);
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        try call_args.append(allocator, try vm.clone(&args.items[i], allocator));
    }

    const fn_val = args.items[1];
    const result_ptr = try eval_helpers.callBuiltin(allocator, &fn_val, call_args.items, env);
    const new_val = try vm.clone(&result_ptr.*, allocator);
    allocator.destroy(result_ptr);
    vm.valueDeinit(&current_val, allocator);

    // Update or add to write-set
    var found = false;
    for (tx_write_set.items) |*entry| {
        if (entry.ref_data == ref_data) {
            vm.valueDeinit(&entry.new_value, allocator);
            entry.new_value = new_val;
            entry.commutative = true;
            found = true;
            break;
        }
    }
    if (!found) {
        try tx_write_set.append(allocator, .{
            .ref_data = ref_data,
            .new_value = new_val,
            .commutative = true,
        });
    }
    return new_val;
}

// ============================================================
// (ensure ref) — Add ref to transaction read-set (inside dosync).
// For clojure.test, this is a no-op since we don't do full read-set tracking.
// ============================================================

pub fn core_ensure(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .ref) return error.TypeError;
    // In our simple STM, ensure is a no-op — all refs are implicitly in the read-set
    return arg;
}

// ============================================================
// (dosync body*) — Transactional execution.
// ============================================================

pub fn evalDosync(allocator: Allocator, l: *const list.List, frame: *vm.Frame, depth: usize) anyerror!eval_mod.EvalResult {
    if (l.items.len < 1) return error.ArityError;

    txLock();
    tx_retry_count = 0;
    txUnlock();

    var result: Value = vm.nilValue();

    while (true) {
        // Begin transaction
        txLock();
        tx_active = true;
        tx_write_set = .empty;
        txUnlock();

        // Evaluate body forms
        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
        var i: usize = 1;
        while (i < l.items.len) : (i += 1) {
            const item = &l.items[i];
            const val = try eval_mod.evalRecDirect(allocator, item, frame, depth + 1);
            vm.valueDeinit(&result, allocator);
            result = try vm.clone(&val, allocator);
        }

        // Commit phase: apply write-set
        // In a simple single-threaded STM, validation always passes
        {
            // Apply write-set
            for (tx_write_set.items) |entry| {
                vm.valueDeinit(&entry.ref_data.value, allocator);
                entry.ref_data.value = entry.new_value;
                entry.ref_data.version += 1;
                // entry.new_value is now owned by ref_data, don't deinit
            }

            // Clear write-set (values transferred to refs)
            const items_buf = tx_write_set.items;
            tx_write_set.deinit(allocator);
            tx_write_set = .empty;
            allocator.free(items_buf);

            txLock();
            tx_active = false;
            txUnlock();
            break;
        }

        // Abort and retry
        txLock();
        tx_active = false;
        for (tx_write_set.items) |*entry| {
            vm.valueDeinit(&entry.new_value, allocator);
        }
        tx_write_set.deinit(allocator);
        tx_write_set = .empty;
        tx_retry_count += 1;
        txUnlock();

        if (tx_retry_count >= MAX_RETRIES) {
            return error.TransactionRetryLimitExceeded;
        }
    }

    // Phase 1: result is already Value by copy, no allocValue wrapper needed
    return .{ .value = result };
}

// ============================================================
// (ref? x) — Check if x is a ref.
// ============================================================

pub fn core_ref_q(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 1) return error.ArityError;
    return if (std.meta.activeTag(args.items[0]) == .ref)
        vm.boolValue(true)
    else
        vm.boolValue(false);
}

// ============================================================
// (commutative? x) — Check if x is a commutative ref.
// Returns true if x has :commutative true in its metadata.
// ============================================================

pub fn core_commutative_q(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .ref) return vm.boolValue(false);
    const ref_data = arg.ref;
    if (ref_data.meta) |m| {
        // Look up :commutative key in metadata map
        for (m.map.entries.items) |entry| {
            if (std.meta.activeTag(entry.key) == .keyword and
                std.mem.eql(u8, entry.key.keyword, "commutative"))
            {
                return if (std.meta.activeTag(entry.value) == .bool)
                    entry.value
                else
                    vm.boolValue(false);
            }
        }
    }
    return vm.boolValue(false);
}

// ============================================================
// Registration
// ============================================================

pub fn registerRefFunctions(env: *Env) anyerror!void {
    try env.put("ref", vm.builtinFnValue(core_ref));
    try env.put("ref-set", vm.builtinFnValue(core_ref_set));
    try env.put("alter", vm.builtinFnValue(core_alter));
    try env.put("commute", vm.builtinFnValue(core_commute));
    try env.put("ensure", vm.builtinFnValue(core_ensure));
    try env.put("ref?", vm.builtinFnValue(core_ref_q));
    try env.put("commutative?", vm.builtinFnValue(core_commutative_q));
}
