// Higher-order sequence operations: map, mapcat, reduce, flatten, filter,
// remove, every?, some, distinct?, next, nthnext, drop
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;
const phm = @import("../../persistent_hash_map.zig");
const helpers = @import("helpers.zig");
const eval_helpers = @import("eval_helpers.zig");
const arithmetic = @import("arithmetic.zig");
const sequences_mod = @import("sequences.zig");
const chunks = @import("chunks.zig");
const test_utils = @import("test_utils.zig");
const gc_mod = @import("../../gc.zig");

const Allocator = std.mem.Allocator;

const toInt = helpers.toInt;

// Force a lazy_seq into a concrete list
pub fn forceLazySeqToConcreteList(allocator: Allocator, val: Value) anyerror!list.List {
    var forced = try sequences_mod.forceLazySeqHelper(allocator, val);
    defer vm.valueDeinit(&forced, allocator);
    return try list.clone(&forced.list.items, allocator);
}

// Force any lazy value (lazy_seq) into a concrete list
pub fn forceToConcreteList(allocator: Allocator, val: Value) anyerror!list.List {
    return switch (std.meta.activeTag(val)) {
        .lazy_seq => return forceLazySeqToConcreteList(allocator, val),
        .cons => {
            // Flatten cons chain to a list
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var current = val;
            errdefer vm.valueDeinit(&current, allocator);
            while (true) {
                switch (std.meta.activeTag(current)) {
                    .cons => {
                        const cdata = current.cons;
                        try result.append(allocator, try vm.shallowClone(&cdata.head, allocator));
                        const tail = try vm.shallowClone(&cdata.tail, allocator);
                        vm.valueDeinit(&current, cdata.allocator);
                        current = tail;
                    },
                    .list => {
                        for (current.list.items.items) |item| {
                            try result.append(allocator, try vm.shallowClone(&item, allocator));
                        }
                        break;
                    },
                    .nil => break,
                    .lazy_seq => {
                        var forced = try sequences_mod.forceLazySeqHelper(allocator, current);
                        defer vm.valueDeinit(&forced, allocator);
                        for (forced.list.items.items) |item| {
                            try result.append(allocator, try vm.shallowClone(&item, allocator));
                        }
                        break;
                    },
                    else => {
                        try result.append(allocator, current);
                        current = vm.nilValue();
                        break;
                    },
                }
            }
            vm.valueDeinit(&current, allocator);
            return result;
        },
        else => {
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            switch (std.meta.activeTag(val)) {
                .list => return try list.clone(&val.list.items, allocator),
                .vector => {
                    for (val.vector.items.items) |item| {
                        try result.append(allocator, try vm.shallowClone(&item, allocator));
                    }
                    return result;
                },
                else => return result,
            }
        },
    };
}

pub fn core_map(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    // Handle nil — (map f nil) returns nil
    if (std.meta.activeTag(coll) == .nil) return vm.nilValue();

    // Validate collection type
    switch (std.meta.activeTag(coll)) {
        .list, .vector, .lazy_seq, .chunked_cons => {},
        else => return error.TypeError,
    }

    // Create thunk with custom handler — bypasses the Clojure evaluator
    // for per-element processing.
    // Use a thin self-contained env — no parent chain, no cloning of namespace.
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = null,
            .ns_manager = null,
            .referred_names = .empty,
        },
        .custom_handler = vm.LazySeqHandler.map,
        .shared_coll = null,
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
    }
    try thunk.env.put("f", try vm.shallowClone(&f, allocator));

    // For concrete collections (list/vector), allocate the collection as a
    // separate GC-tracked object so shared_coll points to stable memory that
    // won't move if the env's HashMap resizes. The GC scan marks shared_coll
    // to keep it alive.
    const cloned_coll = try vm.shallowClone(&coll, allocator);
    if (std.meta.activeTag(coll) == .list or std.meta.activeTag(coll) == .vector) {
        const stable_coll = try allocator.create(Value);
        stable_coll.* = cloned_coll;
        thunk.shared_coll = stable_coll;
        try thunk.env.put("idx", vm.intValue(0));
        // Clone again for env storage — put() will deinit the passed value,
        // which would corrupt stable_coll if we passed cloned_coll directly.
        try thunk.env.put("coll", try vm.shallowClone(&cloned_coll, allocator));
        // stable_coll owns the original cloned_coll now; no deinit needed here.
    } else {
        // Lazy collections: store in env, shared_coll stays null
        // forceMapStepLazy clones from env on each step.
        try thunk.env.put("coll", cloned_coll);
    }

    return vm.lazySeqValue(thunk);
}

pub fn core_mapcat(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const coll = args.items[i];
        // Force lazy_seq to concrete list
        var items_list: list.List = .empty;
        errdefer items_list.deinit(allocator);
        switch (std.meta.activeTag(coll)) {
            .list => items_list = try list.clone(&coll.list.items, allocator),
            .vector => {
                for (coll.vector.items.items) |item| {
                    try items_list.append(allocator, try vm.shallowClone(&item, allocator));
                }
            },
            .lazy_seq => {
                var forced = try sequences_mod.forceLazySeqHelper(allocator, try vm.shallowClone(&coll, allocator));
                defer vm.valueDeinit(&forced, allocator);
                items_list = try list.clone(&forced.list.items, allocator);
            },
            else => {},
        }
        for (items_list.items) |item| {
            var arg_list: list.List = .empty;
            errdefer arg_list.deinit(allocator);
            try arg_list.append(allocator, try vm.shallowClone(&item, allocator));
            const mapped_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
            const mapped = mapped_ptr.*;
            allocator.destroy(mapped_ptr);
            switch (std.meta.activeTag(mapped)) {
                .list => {
                    for (mapped.list.items.items) |mitem| {
                        try result.append(allocator, try vm.shallowClone(&mitem, allocator));
                    }
                },
                .vector => {
                    for (mapped.vector.items.items) |mitem| {
                        try result.append(allocator, try vm.shallowClone(&mitem, allocator));
                    }
                },
                .lazy_seq => {
                    var concrete = try forceToConcreteList(allocator, mapped);
                    for (concrete.items) |mitem| {
                        try result.append(allocator, try vm.shallowClone(&mitem, allocator));
                    }
                    concrete.deinit(allocator);
                },
                .cons => {
                    var concrete = try forceToConcreteList(allocator, mapped);
                    for (concrete.items) |mitem| {
                        try result.append(allocator, try vm.shallowClone(&mitem, allocator));
                    }
                    concrete.deinit(allocator);
                },
                else => try result.append(allocator, mapped),
            }
        }
    }
    return try vm.listValue(allocator, result);
}

pub fn core_reduce(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;

    const allocator = env_env.allocator;
    const f = args.items[0];
    var coll: Value = undefined;
    var init_val: ?Value = null;

    if (args.items.len == 3) {
        coll = args.items[2];
        init_val = args.items[1];
    } else {
        coll = args.items[1];
    }

    // Handle lazy_seq, cons, chunked_cons with streaming reduce
    switch (std.meta.activeTag(coll)) {
        .lazy_seq, .cons, .chunked_cons => {
            return reduceSeq(allocator, f, coll, init_val, env_env);
        },
        else => {},
    }

    // Concrete collection path
    var items: []const Value = undefined;
    var owned_items: ?list.List = null;
    defer if (owned_items) |*ol| ol.deinit(allocator);

    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        .set => items = coll.set.items.items,
        .queue => items = coll.queue.items.items,
        .map => {
            var pairs: list.List = .empty;
            errdefer pairs.deinit(allocator);
            for (coll.map.entries.items) |entry| {
                var pair: vec.Vector = .empty;
                try pair.append(allocator, try vm.shallowClone(&entry.key, allocator));
                try pair.append(allocator, try vm.shallowClone(&entry.value, allocator));
                try pairs.append(allocator, try vm.vectorValue(allocator, pair));
            }
            items = pairs.items;
            owned_items = pairs;
        },
        .record => {
            var pairs: list.List = .empty;
            errdefer pairs.deinit(allocator);
            for (coll.record.fields.items) |entry| {
                var pair: vec.Vector = .empty;
                try pair.append(allocator, try vm.shallowClone(&entry.key, allocator));
                try pair.append(allocator, try vm.shallowClone(&entry.value, allocator));
                try pairs.append(allocator, try vm.vectorValue(allocator, pair));
            }
            for (coll.record.extmap.items) |entry| {
                var pair: vec.Vector = .empty;
                try pair.append(allocator, try vm.shallowClone(&entry.key, allocator));
                try pair.append(allocator, try vm.shallowClone(&entry.value, allocator));
                try pairs.append(allocator, try vm.vectorValue(allocator, pair));
            }
            items = pairs.items;
            owned_items = pairs;
        },
        else => return error.TypeError,
    }

    if (items.len == 0) {
        if (init_val) |iv| return try vm.shallowClone(&iv, allocator);
        return vm.nilValue();
    }

    // Fast path: reduce with + on integer lists
    if (std.meta.activeTag(f) == .builtin_fn and f.builtin_fn == arithmetic.core_plus) {
        var all_ints = true;
        for (items) |item| {
            if (std.meta.activeTag(item) != .integer) { all_ints = false; break; }
        }
        if (all_ints) {
            if (init_val) |iv| {
                if (std.meta.activeTag(iv) == .integer or std.meta.activeTag(iv) == .float) {
                    var acc: i64 = if (std.meta.activeTag(iv) == .integer) iv.integer else @as(i64, @intFromFloat(iv.float));
                    var idx: usize = 0;
                    while (idx < items.len) : (idx += 1) {
                        acc += items[idx].integer;
                    }
                    return vm.intValue(acc);
                }
            } else if (items.len == 1) {
                return vm.intValue(items[0].integer);
            } else {
                var acc: i64 = items[0].integer;
                var idx: usize = 1;
                while (idx < items.len) : (idx += 1) {
                    acc += items[idx].integer;
                }
                return vm.intValue(acc);
            }
        }
    }

    // General path for concrete collections
    return reduceItems(allocator, f, items, init_val, env_env);
}

/// Reduce over a sequence (lazy_seq, cons, or chunked_cons).
/// Streams through elements without forcing the entire sequence.
fn reduceSeq(allocator: Allocator, f: Value, coll: Value, init_val: ?Value, env: *Env) anyerror!Value {
    var acc: ?Value = if (init_val) |iv| try vm.shallowClone(&iv, allocator) else null;
    var owned_acc: bool = acc != null; // we own the clone of init_val
    errdefer if (acc) |*a| vm.valueDeinit(a, allocator);

    var current = try vm.shallowClone(&coll, allocator);
    var current_alloc = allocator;
    defer vm.valueDeinit(&current, current_alloc);

    while (true) {
        // Force lazy_seq if needed
        if (std.meta.activeTag(current) == .lazy_seq) {
            const forced = try sequences_mod.forceLazySeqGetResult(allocator, &current);
            vm.valueDeinit(&current, current_alloc);
            current = forced;
            current_alloc = allocator;
            continue;
        }

        // Handle chunked_cons — process chunk elements in tight loop
        if (std.meta.activeTag(current) == .chunked_cons) {
            const ccd = current.chunked_cons;
            const chunk = ccd.chunk;
            var i: usize = chunk.off;
            while (i < chunk.end) : (i += 1) {
                const elem = try vm.shallowClone(&chunk.items[i], allocator);
                const step_result = try reduceStep(allocator, f, acc, owned_acc, elem, env);
                acc = step_result.new_acc;
                owned_acc = step_result.owned;
                // Check for early reduction termination
                if (step_result.reduced) {
                    vm.valueDeinit(&current, current_alloc);
                    current = vm.nilValue();
                    owned_acc = false; // transfer ownership to caller
                    return acc.?;
                }
            }
            // Move to tail
            const tail = try vm.shallowClone(&ccd.tail, allocator);
            vm.valueDeinit(&current, current_alloc);
            current = tail;
            current_alloc = allocator;
            continue;
        }

        // Handle cons
        if (std.meta.activeTag(current) == .cons) {
            const cdata = current.cons;
            const elem = try vm.shallowClone(&cdata.head, allocator);
            const step_result = try reduceStep(allocator, f, acc, owned_acc, elem, env);
            acc = step_result.new_acc;
            owned_acc = step_result.owned;
            if (step_result.reduced) {
                vm.valueDeinit(&current, current_alloc);
                current = vm.nilValue();
                owned_acc = false; // transfer ownership to caller
                return acc.?;
            }
            const tail = try vm.shallowClone(&cdata.tail, allocator);
            vm.valueDeinit(&current, current_alloc);
            current = tail;
            current_alloc = allocator;
            continue;
        }

        // Handle list (can come from forcing a lazy-seq)
        if (std.meta.activeTag(current) == .list) {
            const items = current.list.items.items;
            var idx: usize = 0;
            while (idx < items.len) : (idx += 1) {
                const elem = try vm.shallowClone(&items[idx], allocator);
                const step_result = try reduceStep(allocator, f, acc, owned_acc, elem, env);
                acc = step_result.new_acc;
                owned_acc = step_result.owned;
                if (step_result.reduced) {
                    vm.valueDeinit(&current, current_alloc);
                    current = vm.nilValue();
                    owned_acc = false; // transfer ownership to caller
                    return acc.?;
                }
            }
            // Deinit and set to nil so defer is a no-op
            vm.valueDeinit(&current, current_alloc);
            current = vm.nilValue();
            break;
        }

        // Handle vector (can come from forcing a lazy-seq)
        if (std.meta.activeTag(current) == .vector) {
            const items = current.vector.items.items;
            var idx: usize = 0;
            while (idx < items.len) : (idx += 1) {
                const elem = try vm.shallowClone(&items[idx], allocator);
                const step_result = try reduceStep(allocator, f, acc, owned_acc, elem, env);
                acc = step_result.new_acc;
                owned_acc = step_result.owned;
                if (step_result.reduced) {
                    vm.valueDeinit(&current, current_alloc);
                    current = vm.nilValue();
                    owned_acc = false; // transfer ownership to caller
                    return acc.?;
                }
            }
            // Deinit and set to nil so defer is a no-op
            vm.valueDeinit(&current, current_alloc);
            current = vm.nilValue();
            break;
        }

        // Sequence ended (nil) or non-sequence type
        break;
    }

    // Return accumulator or nil
    // Transfer ownership to caller - don't deinit
    if (acc) |a| return a;
    return vm.nilValue();
}

/// Result of a single reduce step.
const ReduceStepResult = struct {
    new_acc: Value,
    owned: bool,
    reduced: bool,
};

/// Single reduce step: (f acc elem).
fn reduceStep(allocator: Allocator, f: Value, acc: ?Value, owned_acc: bool, elem: Value, env: *Env) anyerror!ReduceStepResult {
    var e = elem;
    var e_owned = true;
    defer if (e_owned) vm.valueDeinit(&e, allocator);

    var new_acc: Value = undefined;
    var new_owned: bool = false;

    if (acc) |old_acc| {
        var arg_list: list.List = .empty;
        errdefer arg_list.deinit(allocator);
        // Clone values directly into arg_list
        try arg_list.append(allocator, try vm.shallowClone(&old_acc, allocator));
        try arg_list.append(allocator, try vm.shallowClone(&e, allocator));
        // Call the function - arg_list is only used during the call
        const result_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env);
        new_acc = result_ptr.*;
        allocator.destroy(result_ptr);
        // Explicitly deinit arg_list before continuing
        arg_list.deinit(allocator);
        if (owned_acc) {
            var mutable_old = old_acc;
            vm.valueDeinit(&mutable_old, allocator);
        }
        new_owned = true;
    } else {
        new_acc = e;
        e_owned = false; // transferred ownership to new_acc
        new_owned = true;
    }

    // Check for reduced wrapper
    if (std.meta.activeTag(new_acc) == .reduced) {
        const data = new_acc.reduced;
        const unwrapped = data.*;
        return .{ .new_acc = unwrapped, .owned = true, .reduced = true };
    }

    return .{ .new_acc = new_acc, .owned = new_owned, .reduced = false };
}

/// Reduce over a concrete items array.
fn reduceItems(allocator: Allocator, f: Value, items: []const Value, init_val: ?Value, env: *Env) anyerror!Value {
    var acc: Value = undefined;
    if (init_val) |iv| {
        acc = try vm.shallowClone(&iv, allocator);
    } else if (items.len == 1) {
        return try vm.shallowClone(&items[0], allocator);
    } else {
        acc = try vm.shallowClone(&items[0], allocator);
    }

    var start: usize = 0;
    if (init_val == null and items.len > 1) start = 1;

    var i = start;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, try vm.shallowClone(&acc, allocator));
        try arg_list.append(allocator, try vm.shallowClone(&items[i], allocator));

        const new_acc_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env);
        const new_acc = new_acc_ptr.*;
        allocator.destroy(new_acc_ptr);
        vm.valueDeinit(&acc, allocator);
        // Check for early reduction termination
        if (std.meta.activeTag(new_acc) == .reduced) {
            const data = new_acc.reduced;
            acc = data.*;
            return acc;
        }
        acc = new_acc;
    }
    return acc;
}

// reduced - wrap x for early reduction termination
pub fn core_reduced(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.reducedValue(env_env.allocator, args.items[0]);
}

// reduced? - check if value is a reduced wrapper
pub fn core_reduced_q(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(vm.isReduced(args.items[0]));
}

// ensure-reduced - if already reduced, return as-is; else wrap in reduced
pub fn core_ensure_reduced(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    if (vm.isReduced(args.items[0])) {
        return try vm.shallowClone(&args.items[0], env_env.allocator);
    }
    return vm.reducedValue(env_env.allocator, args.items[0]);
}

// unreduced - unwrap reduced value if reduced, else return as-is
pub fn core_unreduced(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.unreducedValue(env_env.allocator, args.items[0]);
}

pub fn core_flatten(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return doFlatten(env_env.allocator, args.items[0], env_env);
}

fn doFlatten(allocator: Allocator, val: Value, env: *Env) anyerror!Value {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    switch (std.meta.activeTag(val)) {
        .list => {
            for (val.list.items.items) |item| {
                var flattened = try doFlatten(allocator, item, env);
                if (std.meta.activeTag(flattened) == .list) {
                    for (flattened.list.items.items) |elem| {
                        try result.append(allocator, try vm.shallowClone(&elem, allocator));
                    }
                    vm.valueDeinit(&flattened, allocator);
                } else {
                    try result.append(allocator, flattened);
                }
            }
        },
        .vector => {
            for (val.vector.items.items) |item| {
                var flattened = try doFlatten(allocator, item, env);
                if (std.meta.activeTag(flattened) == .list) {
                    for (flattened.list.items.items) |elem| {
                        try result.append(allocator, try vm.shallowClone(&elem, allocator));
                    }
                    vm.valueDeinit(&flattened, allocator);
                } else {
                    try result.append(allocator, flattened);
                }
            }
        },
        else => {
            try result.append(allocator, try vm.shallowClone(&val, allocator));
        },
    }
    return try vm.listValue(allocator, result);
}

pub fn core_next(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    var rest = try sequences_mod.core_rest(self, args, env_env);
    if (std.meta.activeTag(rest) == .list and rest.list.items.items.len == 0) {
        vm.valueDeinit(&rest, env_env.allocator);
        return vm.nilValue();
    }
    return rest;
}

pub fn core_nthnext(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    if (args.items.len != 2) return error.ArityError;
    const n = try toInt(args.items[0]);
    if (n <= 0) return try sequences_mod.core_seq(self, args, env_env);

    const coll = args.items[1];
    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    if (@as(usize, @intCast(n)) >= items.len) return vm.nilValue();

    var result: list.List = .empty;
    try result.ensureTotalCapacity(env_env.allocator, items.len - @as(usize, @intCast(n)));
    errdefer result.deinit(env_env.allocator);
    var i: usize = @as(usize, @intCast(n));
    while (i < items.len) : (i += 1) {
        try result.append(env_env.allocator, try vm.shallowClone(&items[i], env_env.allocator));
    }
    return try vm.listValue(env_env.allocator, result);
}

pub fn core_filter(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const pred = args.items[0];
    const coll = args.items[1];

    // Handle nil — (filter pred nil) returns nil
    if (std.meta.activeTag(coll) == .nil) return vm.nilValue();

    // Validate collection type
    switch (std.meta.activeTag(coll)) {
        .list, .vector, .lazy_seq, .chunked_cons => {},
        else => return error.TypeError,
    }

    // Create thunk with custom handler — bypasses the Clojure evaluator
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = null,
            .ns_manager = null,
            .referred_names = .empty,
        },
        .custom_handler = vm.LazySeqHandler.filter,
        .shared_coll = null,
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
    }
    try thunk.env.put("pred", try vm.shallowClone(&pred, allocator));

    // For concrete collections (list/vector), store the collection stably
    const cloned_coll = try vm.shallowClone(&coll, allocator);
    if (std.meta.activeTag(coll) == .list or std.meta.activeTag(coll) == .vector) {
        // For concrete collections, we don't use shared_coll for filter
        // since filter processes element by element
        try thunk.env.put("coll", cloned_coll);
    } else {
        // Lazy collections: store in env
        try thunk.env.put("coll", cloned_coll);
    }

    return vm.lazySeqValue(thunk);
}

pub fn core_remove(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try vm.shallowClone(&item, env_env.allocator));
        const pred_result_ptr = try eval_helpers.callBuiltin(env_env.allocator, &f, &arg_list, env_env);
        const pred_result = pred_result_ptr.*;
        const truthy = vm.isTruthy(pred_result);
        vm.valueDeinit(&pred_result_ptr.*, env_env.allocator);
        env_env.allocator.destroy(pred_result_ptr);
        if (!truthy) {
            try result.append(env_env.allocator, try vm.shallowClone(&item, env_env.allocator));
        }
    }
    return try vm.listValue(env_env.allocator, result);
}

pub fn core_every_q(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        .set => items = coll.set.items.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try vm.shallowClone(&item, env_env.allocator));
        const pred_result_ptr = try eval_helpers.callBuiltin(env_env.allocator, &f, &arg_list, env_env);
        const pred_result = pred_result_ptr.*;
        const truthy = vm.isTruthy(pred_result);
        vm.valueDeinit(&pred_result_ptr.*, env_env.allocator);
        env_env.allocator.destroy(pred_result_ptr);
        if (!truthy) return vm.boolValue(false);
    }
    return vm.boolValue(true);
}

pub fn core_some(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        .set => items = coll.set.items.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try vm.shallowClone(&item, env_env.allocator));
        const result_ptr = try eval_helpers.callBuiltin(env_env.allocator, &f, &arg_list, env_env);
        if (vm.isTruthy(result_ptr.*)) {
            const result = result_ptr.*;
            env_env.allocator.destroy(result_ptr);
            return result;
        }
        vm.valueDeinit(&result_ptr.*, env_env.allocator);
        env_env.allocator.destroy(result_ptr);
    }
    return vm.nilValue();
}

pub fn core_distinct_q(_: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    for (items, 0..) |item, i| {
        var j: usize = i + 1;
        while (j < items.len) : (j += 1) {
            if (vm.equals(item, items[j])) return vm.boolValue(false);
        }
    }
    return vm.boolValue(true);
}

pub fn core_drop(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const n = try toInt(args.items[0]);
    const coll = args.items[1];

    // For lazy_seq, cons, and chunked_cons, return a lazy-seq that preserves laziness
    // Mirrors Clojure: (lazy-seq (when (pos? n) (when-let [s (seq coll)]
    //   (if (zero? (dec n)) s (drop (dec n) (rest s))))))
    if (std.meta.activeTag(coll) == .lazy_seq or std.meta.activeTag(coll) == .cons or std.meta.activeTag(coll) == .chunked_cons) {
        if (n <= 0) return try vm.shallowClone(&coll, allocator);
        return dropLazySeq(allocator, n, coll, env_env);
    }

    var items: []const Value = undefined;
    var is_list: bool = false;
    switch (std.meta.activeTag(coll)) {
        .list => { items = coll.list.items.items; is_list = true; },
        .vector => { items = coll.vector.items.items; is_list = false; },
        else => return error.TypeError,
    }

    if (n <= 0) return try vm.shallowClone(&coll, env_env.allocator);
    if (@as(usize, @intCast(n)) >= items.len) {
        if (is_list) return try vm.listValue(allocator, list.empty());
        return try vm.vectorValue(allocator, vec.Vector.empty);
    }

    const start: usize = @as(usize, @intCast(n));
    if (is_list) {
        var result: list.List = .empty;
        errdefer result.deinit(env_env.allocator);
        var i: usize = start;
        while (i < items.len) : (i += 1) {
            try result.append(env_env.allocator, try vm.shallowClone(&items[i], env_env.allocator));
        }
        return try vm.listValue(allocator, result);
    } else {
        var result: vec.Vector = .empty;
        errdefer result.deinit(env_env.allocator);
        var i: usize = start;
        while (i < items.len) : (i += 1) {
            try result.append(env_env.allocator, try vm.shallowClone(&items[i], env_env.allocator));
        }
        return try vm.vectorValue(allocator, result);
    }
}

/// Build a lazy-seq for (drop n coll) where coll is lazy_seq or cons.
/// Uses a self-referencing thunk so recursive calls go through core_drop directly.
fn dropLazySeq(allocator: Allocator, n: i64, coll: Value, env: *Env) anyerror!Value {
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = try env.clone(allocator),
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
    }
    try thunk.env.put("n", vm.intValue(n));
    try thunk.env.put("coll", try vm.shallowClone(&coll, allocator));
    // Self-reference: thunk calls core_drop directly
    try thunk.env.put("__zig_drop", vm.builtinFnValue(core_drop));

    // Build thunk body:
    // (if (pos? n)
    //   (let [s (seq coll)]
    //     (if s
    //       (if (zero? (dec n)) (rest s) (__zig_drop (dec n) (rest s)))
    //       nil))
    //   coll)
    const a = allocator;
    const sym_if = try vm.symValue(a, "if");
    const sym_pos_q = try vm.symValue(a, "pos?");
    const sym_n = try vm.symValue(a, "n");
    const sym_coll = try vm.symValue(a, "coll");
    const sym_let = try vm.symValue(a, "let");
    const sym_s = try vm.symValue(a, "s");
    const sym_seq = try vm.symValue(a, "seq");
    const sym_zero_q = try vm.symValue(a, "zero?");
    const sym_dec = try vm.symValue(a, "dec");
    const sym_rest = try vm.symValue(a, "rest");
    const sym_zig_drop = try vm.symValue(a, "__zig_drop");
    const sym_nil = vm.nilValue();

    // (pos? n)
    var pos_call: list.List = .empty;
    try pos_call.append(a, sym_pos_q);
    try pos_call.append(a, sym_n);

    // (seq coll)
    var seq_call: list.List = .empty;
    try seq_call.append(a, sym_seq);
    try seq_call.append(a, sym_coll);

    // [s (seq coll)]
    var bindings: list.List = .empty;
    try bindings.append(a, sym_s);
    try bindings.append(a, try vm.listValue(a, seq_call));

    // (dec n)
    var dec_call: list.List = .empty;
    try dec_call.append(a, sym_dec);
    try dec_call.append(a, sym_n);

    // (zero? (dec n))
    var zero_call: list.List = .empty;
    try zero_call.append(a, sym_zero_q);
    try zero_call.append(a, try vm.listValue(a, dec_call));

    // (rest s)
    var rest_call: list.List = .empty;
    try rest_call.append(a, sym_rest);
    try rest_call.append(a, sym_s);

    // (__zig_drop (dec n) (rest s))
    var drop_call: list.List = .empty;
    try drop_call.append(a, sym_zig_drop);
    try drop_call.append(a, try vm.listValue(a, dec_call));
    try drop_call.append(a, try vm.listValue(a, rest_call));

    // (if (zero? (dec n)) (rest s) (__zig_drop (dec n) (rest s)))
    var inner_if: list.List = .empty;
    try inner_if.append(a, sym_if);
    try inner_if.append(a, try vm.listValue(a, zero_call));
    try inner_if.append(a, try vm.listValue(a, rest_call));
    try inner_if.append(a, try vm.listValue(a, drop_call));

    // (if s (inner_if) nil)
    var s_check: list.List = .empty;
    try s_check.append(a, sym_if);
    try s_check.append(a, sym_s);
    try s_check.append(a, try vm.listValue(a, inner_if));
    try s_check.append(a, sym_nil);

    // (let [s (seq coll)] (if s ... nil))
    var let_form: list.List = .empty;
    try let_form.append(a, sym_let);
    try let_form.append(a, try vm.listValue(a, bindings));
    try let_form.append(a, try vm.listValue(a, s_check));

    // (if (pos? n) (let ...) coll)
    var body: list.List = .empty;
    try body.append(a, sym_if);
    try body.append(a, try vm.listValue(a, pos_call));
    try body.append(a, try vm.listValue(a, let_form));
    try body.append(a, sym_coll);

    thunk.body = body;
    return vm.lazySeqValue(thunk);
}

// doall* - realizes a lazy sequence and returns the realized list
pub fn core_doall_star(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var coll = try vm.shallowClone(&args.items[0], allocator);
    defer vm.valueDeinit(&coll, allocator);

    // Recursively force lazy sequences
    return forceValue(allocator, coll);
}

fn forceValue(allocator: Allocator, val: Value) anyerror!Value {
    const result = switch (std.meta.activeTag(val)) {
        .lazy_seq => {
            // Evaluate the thunk
            if (val.lazy_seq) |thunk| {
                const cloned_params = try list.clone(&thunk.params, allocator);
                const cloned_body = try list.clone(&thunk.body, allocator);
                var thunk_env = try thunk.env.clone(allocator);

                const fn_val = try vm.fnValueSingle(allocator, cloned_params, cloned_body, thunk_env, null, false);
                var empty_args: list.List = .empty;
                const result_ptr = try eval_helpers.callBuiltin(
                    allocator,
                    &fn_val,
                    &empty_args,
                    &thunk_env,
                );
                var result = result_ptr.*;
                allocator.destroy(result_ptr);

                // Force each element of the result
                switch (std.meta.activeTag(result)) {
                    .list => {
                        var forced_list: list.List = .empty;
                        errdefer forced_list.deinit(allocator);
                        // Handle cons cell pattern: [head, lazy_seq_tail]
                        // forceLazySeqHelper returns at most 2 items from a cons
                        if (result.list.items.items.len == 2 and std.meta.activeTag(result.list.items.items[1]) == .lazy_seq) {
                            // Force the head if it's a lazy_seq, otherwise clone
                            const head_item = result.list.items.items[0];
                            if (std.meta.activeTag(head_item) == .lazy_seq) {
                                const head_forced = try forceValue(allocator, head_item);
                                // Append the forced head as a single element (don't flatten)
                                try forced_list.append(allocator, head_forced);
                            } else {
                                try forced_list.append(allocator, try vm.shallowClone(&head_item, allocator));
                            }
                            // Force the tail lazy_seq recursively
                            var tail_forced = try forceValue(allocator, result.list.items.items[1]);
                            if (std.meta.activeTag(tail_forced) == .list) {
                                for (tail_forced.list.items.items) |fi| {
                                    try forced_list.append(allocator, try vm.shallowClone(&fi, allocator));
                                }
                            }
                            vm.valueDeinit(&tail_forced, allocator);
                        } else {
                            for (result.list.items.items) |item| {
                                // Only force lazy_seq items; clone everything else
                                if (std.meta.activeTag(item) == .lazy_seq) {
                                    var forced = try forceValue(allocator, item);
                                    if (std.meta.activeTag(forced) == .list) {
                                        for (forced.list.items.items) |fi| {
                                            try forced_list.append(allocator, try vm.shallowClone(&fi, allocator));
                                        }
                                    } else {
                                        try forced_list.append(allocator, forced);
                                    }
                                    vm.valueDeinit(&forced, allocator);
                                } else {
                                    try forced_list.append(allocator, try vm.shallowClone(&item, allocator));
                                }
                            }
                        }
                        vm.valueDeinit(&result, allocator);
                        return try vm.listValue(allocator, forced_list);
                    },
                    .vector => {
                        var forced_vec: vec.Vector = .empty;
                        errdefer forced_vec.deinit(allocator);
                        for (result.vector.items.items) |item| {
                            // Only force lazy_seq items; clone everything else
                            if (std.meta.activeTag(item) == .lazy_seq) {
                                var forced = try forceValue(allocator, item);
                                if (std.meta.activeTag(forced) == .list) {
                                    for (forced.list.items.items) |fi| {
                                        try forced_vec.append(allocator, try vm.shallowClone(&fi, allocator));
                                    }
                                } else {
                                    try forced_vec.append(allocator, forced);
                                }
                                vm.valueDeinit(&forced, allocator);
                            } else {
                                try forced_vec.append(allocator, try vm.shallowClone(&item, allocator));
                            }
                        }
                        vm.valueDeinit(&result, allocator);
                        return try vm.vectorValue(allocator, forced_vec);
                    },
                    .nil => {
                        // Thunk returned nil (empty sequence)
                        vm.valueDeinit(&result, allocator);
                        return try vm.listValue(allocator, list.empty());
                    },
                    .lazy_seq => {
                        // Thunk returned a lazy_seq (e.g., from cons). Recursively force it.
                        const forced = try forceValue(allocator, result);
                        vm.valueDeinit(&result, allocator);
                        return forced;
                    },
                    .cons => {
                        // Thunk returned a cons cell. Convert to list and force nested lazy_seqs.
                        // forceToConcreteList takes ownership of the cons value.
                        var concrete = try forceToConcreteList(allocator, result);
                        // Now force any lazy_seq elements in the list
                        var forced_list: list.List = .empty;
                        errdefer forced_list.deinit(allocator);
                        for (concrete.items) |item| {
                            if (std.meta.activeTag(item) == .lazy_seq) {
                                var forced = try forceValue(allocator, item);
                                if (std.meta.activeTag(forced) == .list) {
                                    for (forced.list.items.items) |fi| {
                                        try forced_list.append(allocator, try vm.shallowClone(&fi, allocator));
                                    }
                                } else {
                                    try forced_list.append(allocator, forced);
                                }
                                vm.valueDeinit(&forced, allocator);
                            } else {
                                try forced_list.append(allocator, try vm.shallowClone(&item, allocator));
                            }
                        }
                        concrete.deinit(allocator);
                        return try vm.listValue(allocator, forced_list);
                    },
                    else => {
                        const forced = try forceValue(allocator, result);
                        vm.valueDeinit(&result, allocator);
                        return forced;
                    },
                }
            }
            return try vm.listValue(allocator, list.empty());
        },
        .list => {
            // For standalone lists, just clone them (they're data, not thunk results)
            return try vm.shallowClone(&val, allocator);
        },
        .vector => {
            var forced_vec: vec.Vector = .empty;
            errdefer forced_vec.deinit(allocator);
            for (val.vector.items.items) |item| {
                // Flatten lazy_seq elements
                if (std.meta.activeTag(item) == .lazy_seq) {
                    var forced = try sequences_mod.forceLazySeqHelper(allocator, item);
                    defer vm.valueDeinit(&forced, allocator);
                    for (forced.list.items.items) |fi| {
                        const recursively_forced = try forceValue(allocator, fi);
                        try forced_vec.append(allocator, recursively_forced);
                    }
                } else {
                    const forced_item = try forceValue(allocator, item);
                    try forced_vec.append(allocator, forced_item);
                }
            }
            return try vm.vectorValue(allocator, forced_vec);
        },
        .cons => {
            // Force cons cells: walk the chain and force nested lazy_seqs
            // Clone all elements, don't consume the original
            var forced_list: list.List = .empty;
            errdefer forced_list.deinit(allocator);
            var current: Value = val;
            while (true) {
                switch (std.meta.activeTag(current)) {
                    .cons => {
                        const cdata = current.cons;
                        // Force the head if it's a lazy_seq
                        if (std.meta.activeTag(cdata.head) == .lazy_seq) {
                            var head_forced = try forceValue(allocator, cdata.head);
                            if (std.meta.activeTag(head_forced) == .list) {
                                for (head_forced.list.items.items) |fi| {
                                    try forced_list.append(allocator, try vm.shallowClone(&fi, allocator));
                                }
                            } else {
                                try forced_list.append(allocator, head_forced);
                            }
                            vm.valueDeinit(&head_forced, allocator);
                        } else {
                            try forced_list.append(allocator, try vm.shallowClone(&cdata.head, allocator));
                        }
                        // Move to tail (clone it, current is still the original cons)
                        const tail = try vm.shallowClone(&cdata.tail, allocator);
                        current = tail;
                    },
                    .list => {
                        for (current.list.items.items) |item| {
                            if (std.meta.activeTag(item) == .lazy_seq) {
                                var forced = try forceValue(allocator, item);
                                if (std.meta.activeTag(forced) == .list) {
                                    for (forced.list.items.items) |fi| {
                                        try forced_list.append(allocator, try vm.shallowClone(&fi, allocator));
                                    }
                                } else {
                                    try forced_list.append(allocator, forced);
                                }
                                vm.valueDeinit(&forced, allocator);
                            } else {
                                try forced_list.append(allocator, try vm.shallowClone(&item, allocator));
                            }
                        }
                        vm.valueDeinit(&current, allocator);
                        break;
                    },
                    .nil => {
                        vm.valueDeinit(&current, allocator);
                        break;
                    },
                    .lazy_seq => {
                        var forced = try forceValue(allocator, current);
                        if (std.meta.activeTag(forced) == .list) {
                            for (forced.list.items.items) |fi| {
                                try forced_list.append(allocator, try vm.shallowClone(&fi, allocator));
                            }
                        }
                        vm.valueDeinit(&forced, allocator);
                        vm.valueDeinit(&current, allocator);
                        break;
                    },
                    else => {
                        try forced_list.append(allocator, try vm.shallowClone(&current, allocator));
                        vm.valueDeinit(&current, allocator);
                        break;
                    },
                }
            }
            return try vm.listValue(allocator, forced_list);
        },
        else => try vm.shallowClone(&val, allocator),
    };
    return result;
}

// iterate: repeatedly apply f to init, lazily
// Mirrors Clojure: returns a lazy (infinite!) sequence of x, (f x), (f (f x)) etc.
pub fn core_iterate(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const f = args.items[0];
    const x = args.items[1];

    // Return a lazy-seq: (lazy-seq (cons x (__zig_iterate f (f x))))
    // We use __zig_iterate (a private self-reference) instead of the global
    // "iterate" symbol, so the thunk calls this Zig function directly without
    // going through any Clojure wrapper (e.g. core.clj defn delegating to zig.core/iterate).
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = try env_env.clone(allocator),
    };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
    }
    try thunk.env.put("f", try vm.shallowClone(&f, allocator));
    try thunk.env.put("x", try vm.shallowClone(&x, allocator));
    // Store a self-reference so the thunk body calls core_iterate directly
    try thunk.env.put("__zig_iterate", vm.builtinFnValue(core_iterate));

    // Build thunk body: (cons x (__zig_iterate f (f x)))
    const a = allocator;
    const sym_cons = try vm.symValue(a, "cons");
    const sym_x = try vm.symValue(a, "x");
    const sym_f = try vm.symValue(a, "f");
    const sym_zig_iterate = try vm.symValue(a, "__zig_iterate");

    // (f x)
    var f_call: list.List = .empty;
    try f_call.append(a, sym_f);
    try f_call.append(a, sym_x);

    // (__zig_iterate f (f x))
    var iterate_call: list.List = .empty;
    try iterate_call.append(a, sym_zig_iterate);
    try iterate_call.append(a, sym_f);
    try iterate_call.append(a, try vm.listValue(a, f_call));

    // (cons x (__zig_iterate f (f x)))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, sym_x);
    try cons_call.append(a, try vm.listValue(a, iterate_call));

    thunk.body = cons_call;
    return vm.lazySeqValue(thunk);
}

// cycle: returns a lazy (infinite) sequence of repetitions of the items in coll
// Mirrors Clojure: (lazy-seq (when-let [s (seq coll)] (concat s (cycle coll))))
// Uses cons-based approach to avoid concat's lazy-seq embedding issue
pub fn core_cycle(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    const coll = args.items[0];

    // Return a lazy-seq: (lazy-seq (let [s (seq coll)] (when s (cons (first s) (__zig_cycle (conj (vec (rest s)) (first s)))))))
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{ .params = list.empty(), .body = list.empty(), .env = try env_env.clone(allocator) };
    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(thunk)), gc_mod.GCObjectType.lazy_seq_thunk);
    }
    try thunk.env.put("coll", try vm.shallowClone(&coll, allocator));
    // Self-reference: thunk calls core_cycle directly, not via global symbol
    try thunk.env.put("__zig_cycle", vm.builtinFnValue(core_cycle));

    const a = allocator;
    const sym_let = try vm.symValue(a, "let");
    const sym_s = try vm.symValue(a, "s");
    const sym_seq = try vm.symValue(a, "seq");
    const sym_coll = try vm.symValue(a, "coll");
    const sym_when = try vm.symValue(a, "when");
    const sym_cons = try vm.symValue(a, "cons");
    const sym_first = try vm.symValue(a, "first");
    const sym_zig_cycle = try vm.symValue(a, "__zig_cycle");
    const sym_conj = try vm.symValue(a, "conj");
    const sym_vec = try vm.symValue(a, "vec");
    const sym_rest = try vm.symValue(a, "rest");

    // (seq coll)
    var seq_call: list.List = .empty;
    try seq_call.append(a, sym_seq);
    try seq_call.append(a, sym_coll);

    // [s (seq coll)]
    var bindings: list.List = .empty;
    try bindings.append(a, sym_s);
    try bindings.append(a, try vm.listValue(a, seq_call));

    // (first s)
    var first_call: list.List = .empty;
    try first_call.append(a, sym_first);
    try first_call.append(a, sym_s);

    // (rest s)
    var rest_call: list.List = .empty;
    try rest_call.append(a, sym_rest);
    try rest_call.append(a, sym_s);

    // (vec (rest s))
    var vec_call: list.List = .empty;
    try vec_call.append(a, sym_vec);
    try vec_call.append(a, try vm.listValue(a, rest_call));

    // (conj (vec (rest s)) (first s))
    var conj_call: list.List = .empty;
    try conj_call.append(a, sym_conj);
    try conj_call.append(a, try vm.listValue(a, vec_call));
    try conj_call.append(a, try vm.listValue(a, first_call));

    // (__zig_cycle (conj (vec (rest s)) (first s)))
    var cycle_call: list.List = .empty;
    try cycle_call.append(a, sym_zig_cycle);
    try cycle_call.append(a, try vm.listValue(a, conj_call));

    // (cons (first s) (cycle ...))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, try vm.listValue(a, first_call));
    try cons_call.append(a, try vm.listValue(a, cycle_call));

    // (when s (cons ...))
    var when_call: list.List = .empty;
    try when_call.append(a, sym_when);
    try when_call.append(a, sym_s);
    try when_call.append(a, try vm.listValue(a, cons_call));

    // (let [s (seq coll)] (when s (cons ...)))
    var body: list.List = .empty;
    try body.append(a, sym_let);
    try body.append(a, try vm.listValue(a, bindings));
    try body.append(a, try vm.listValue(a, when_call));

    thunk.body = body;
    return vm.lazySeqValue(thunk);
}

pub fn registerSequenceOpFunctions(env: *Env) anyerror!void {
    try env.put("map", vm.builtinFnValue(core_map));
    try env.put("mapcat", vm.builtinFnValue(core_mapcat));
    try env.put("reduce", vm.builtinFnValue(core_reduce));
    try env.put("flatten", vm.builtinFnValue(core_flatten));
    try env.put("filter", vm.builtinFnValue(core_filter));
    try env.put("remove", vm.builtinFnValue(core_remove));
    try env.put("every?", vm.builtinFnValue(core_every_q));
    try env.put("some", vm.builtinFnValue(core_some));
    try env.put("distinct?", vm.builtinFnValue(core_distinct_q));
    try env.put("next", vm.builtinFnValue(core_next));
    try env.put("nthnext", vm.builtinFnValue(core_nthnext));
    try env.put("drop", vm.builtinFnValue(core_drop));
    try env.put("doall*", vm.builtinFnValue(core_doall_star));
    try env.put("iterate", vm.builtinFnValue(core_iterate));
    try env.put("cycle", vm.builtinFnValue(core_cycle));

    // Reduced wrapper functions
    try env.put("reduced", vm.builtinFnValue(core_reduced));
    try env.put("reduced?", vm.builtinFnValue(core_reduced_q));
    try env.put("ensure-reduced", vm.builtinFnValue(core_ensure_reduced));
    try env.put("unreduced", vm.builtinFnValue(core_unreduced));
}

const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "seq_ops::flatten: nested list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    // Build: (1 (2 3) 4)
    var inner: list.List = .empty;
    _ = inner.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = inner.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    var outer: list.List = .empty;
    _ = outer.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = outer.append(std.heap.page_allocator, try vm.listValue(std.heap.page_allocator, inner)) catch unreachable;
    _ = outer.append(std.heap.page_allocator, vm.intValue(4)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, outer);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_flatten(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items.len == 4);
    try std.testing.expect(result.list.items.items[0].integer == 1);
    try std.testing.expect(result.list.items.items[1].integer == 2);
    try std.testing.expect(result.list.items.items[2].integer == 3);
    try std.testing.expect(result.list.items.items[3].integer == 4);
}

test "seq_ops::distinct_q: all distinct" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_distinct_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "seq_ops::distinct_q: has duplicates" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_distinct_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "seq_ops::drop: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(4)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ vm.intValue(2), lv });
    var result = core_drop(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items.len == 2);
    try std.testing.expect(result.list.items.items[0].integer == 3);
}

test "seq_ops::drop: more than length returns empty" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ vm.intValue(5), lv });
    var result = core_drop(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items.len == 0);
}

test "seq_ops::next: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_next(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items.len == 2);
    try std.testing.expect(result.list.items.items[0].integer == 2);
}

test "seq_ops::next: single element returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_next(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "seq_ops::nthnext: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(4)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ vm.intValue(2), lv });
    var result = core_nthnext(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items.len == 2);
    try std.testing.expect(result.list.items.items[0].integer == 3);
}

test "seq_ops::nthnext: out of range returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ vm.intValue(5), lv });
    var result = core_nthnext(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}


test "seq_ops::reduced: wraps value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_reduced(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .reduced);
    try std.testing.expect(result.reduced.integer == 42);
}

test "seq_ops::reduced_q: true for reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var reduced_val = vm.reducedValue(std.heap.page_allocator, vm.intValue(42)) catch unreachable;
    defer vm.valueDeinit(&reduced_val, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ reduced_val });
    var result = core_reduced_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bool);
    try std.testing.expect(result.bool == true);
}

test "seq_ops::reduced_q: false for non-reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_reduced_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bool);
    try std.testing.expect(result.bool == false);
}

test "seq_ops::ensure_reduced: wraps non-reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_ensure_reduced(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .reduced);
}

test "seq_ops::ensure_reduced: passes through reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var reduced_val = vm.reducedValue(std.heap.page_allocator, vm.intValue(42)) catch unreachable;
    defer vm.valueDeinit(&reduced_val, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ reduced_val });
    var result = core_ensure_reduced(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .reduced);
}

test "seq_ops::unreduced: unwraps reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var reduced_val = vm.reducedValue(std.heap.page_allocator, vm.intValue(42)) catch unreachable;
    defer vm.valueDeinit(&reduced_val, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ reduced_val });
    var result = core_unreduced(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 42);
}

test "seq_ops::unreduced: passes through non-reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_unreduced(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 42);
}
