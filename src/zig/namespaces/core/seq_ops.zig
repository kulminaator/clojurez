// Higher-order sequence operations: map, mapcat, reduce, flatten, filter,
// remove, every?, some, distinct?, next, nthnext, drop
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = Value.Env;
const helpers = @import("helpers.zig");
const eval_helpers = @import("eval_helpers.zig");
const arithmetic = @import("arithmetic.zig");
const sequences_mod = @import("sequences.zig");
const test_utils = @import("test_utils.zig");

const Allocator = std.mem.Allocator;

const toInt = helpers.toInt;

// Force a lazy_seq into a concrete list
pub fn forceLazySeqToConcreteList(allocator: Allocator, val: Value) anyerror!list.List {
    var forced = try sequences_mod.forceLazySeqHelper(allocator, val);
    defer forced.deinit(allocator);
    return try list.clone(&forced.list_val, allocator);
}

// Force any lazy value (lazy_seq) into a concrete list
pub fn forceToConcreteList(allocator: Allocator, val: Value) anyerror!list.List {
    return switch (val.type) {
        .lazy_seq => return forceLazySeqToConcreteList(allocator, val),
        .cons => {
            // Flatten cons chain to a list
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var current = val;
            errdefer current.deinit(allocator);
            while (true) {
                switch (current.type) {
                    .cons => {
                        const cdata = current.cons_val.?;
                        try result.append(allocator, try cdata.head.clone(allocator));
                        const tail = try cdata.tail.clone(allocator);
                        current.deinit(cdata.allocator);
                        current = tail;
                    },
                    .list => {
                        for (current.list_val.items) |item| {
                            try result.append(allocator, try item.clone(allocator));
                        }
                        break;
                    },
                    .nil => break,
                    .lazy_seq => {
                        var forced = try sequences_mod.forceLazySeqHelper(allocator, current);
                        defer forced.deinit(allocator);
                        for (forced.list_val.items) |item| {
                            try result.append(allocator, try item.clone(allocator));
                        }
                        break;
                    },
                    else => {
                        try result.append(allocator, current);
                        current = Value.nilValue();
                        break;
                    },
                }
            }
            current.deinit(allocator);
            return result;
        },
        else => {
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            switch (val.type) {
                .list => return try list.clone(&val.list_val, allocator),
                .vector => {
                    for (val.vec_val.items) |item| {
                        try result.append(allocator, try item.clone(allocator));
                    }
                    return result;
                },
                else => return result,
            }
        },
    };
}

pub fn core_map(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    // Validate collection type
    switch (coll.type) {
        .list, .vector, .lazy_seq => {},
        else => return error.TypeError,
    }

    // Create thunk with custom handler — bypasses the Clojure evaluator
    // for per-element processing. The handler does the map step directly in Zig.
    const thunk = try allocator.create(Value.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(), // unused when custom_handler is set
        .env = try env_env.clone(allocator),
        .custom_handler = Value.LazySeqHandler.map,
    };
    try thunk.env.put("f", try f.clone(allocator));
    try thunk.env.put("coll", try coll.clone(allocator));

    return Value.lazySeqValue(thunk);
}

pub fn core_mapcat(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
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
        switch (coll.type) {
            .list => items_list = try list.clone(&coll.list_val, allocator),
            .vector => {
                for (coll.vec_val.items) |item| {
                    try items_list.append(allocator, try item.clone(allocator));
                }
            },
            .lazy_seq => {
                var forced = try sequences_mod.forceLazySeqHelper(allocator, try coll.clone(allocator));
                defer forced.deinit(allocator);
                items_list = try list.clone(&forced.list_val, allocator);
            },
            else => {},
        }
        for (items_list.items) |item| {
            var arg_list: list.List = .empty;
            errdefer arg_list.deinit(allocator);
            try arg_list.append(allocator, try item.clone(allocator));
            const mapped = try eval_helpers.callBuiltin(allocator, f, arg_list, env_env);
            switch (mapped.type) {
                .list => {
                    for (mapped.list_val.items) |mitem| {
                        try result.append(allocator, try mitem.clone(allocator));
                    }
                },
                .vector => {
                    for (mapped.vec_val.items) |mitem| {
                        try result.append(allocator, try mitem.clone(allocator));
                    }
                },
                .lazy_seq => {
                    var concrete = try forceToConcreteList(allocator, mapped);
                    for (concrete.items) |mitem| {
                        try result.append(allocator, try mitem.clone(allocator));
                    }
                    concrete.deinit(allocator);
                },
                .cons => {
                    var concrete = try forceToConcreteList(allocator, mapped);
                    for (concrete.items) |mitem| {
                        try result.append(allocator, try mitem.clone(allocator));
                    }
                    concrete.deinit(allocator);
                },
                else => try result.append(allocator, mapped),
            }
        }
    }
    return Value.listValue(result);
}

pub fn core_reduce(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;

    const f = args.items[0];
    var coll: Value = undefined;
    var init_val: ?Value = null;

    if (args.items.len == 3) {
        coll = args.items[2];
        init_val = args.items[1];
    } else {
        coll = args.items[1];
    }

    // Force lazy sequences to concrete lists before reducing
    var owned_coll: bool = false;
    defer {
        if (owned_coll) {
            coll.deinit(env_env.allocator);
        }
    }
    switch (coll.type) {
        .lazy_seq => {
            const concrete_list = try forceToConcreteList(env_env.allocator, coll);
            // Null out the thunk before deinit so we don't free caller-owned data
            coll.lazy_seq_val.thunk = null;
            coll.deinit(env_env.allocator);
            coll = Value.listValue(concrete_list);
            owned_coll = true;
        },
        else => {},
    }

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        .set => items = coll.set_val.items,
        .queue => items = coll.queue_val.items,
        else => return error.TypeError,
    }

    if (items.len == 0) {
        if (init_val) |iv| return try iv.clone(env_env.allocator);
        return Value.nilValue();
    }

    // Fast path: reduce with + on integer lists
    if (f.type == .builtin_fn and f.builtin_fn_val == arithmetic.core_plus) {
        var all_ints = true;
        for (items) |item| {
            if (item.type != .integer) { all_ints = false; break; }
        }
        if (all_ints) {
            if (init_val) |iv| {
                if (iv.type == .integer or iv.type == .float) {
                    var acc: i64 = if (iv.type == .integer) iv.int_val else @as(i64, @intFromFloat(iv.float_val));
                    var idx: usize = 0;
                    while (idx < items.len) : (idx += 1) {
                        acc += items[idx].int_val;
                    }
                    return Value.intValue(acc);
                }
            } else if (items.len == 1) {
                return Value.intValue(items[0].int_val);
            } else {
                var acc: i64 = items[0].int_val;
                var idx: usize = 1;
                while (idx < items.len) : (idx += 1) {
                    acc += items[idx].int_val;
                }
                return Value.intValue(acc);
            }
        }
    }

    // General path
    var acc: Value = undefined;
    if (init_val) |iv| {
        acc = try iv.clone(env_env.allocator);
    } else if (items.len == 1) {
        return try items[0].clone(env_env.allocator);
    } else {
        acc = try items[0].clone(env_env.allocator);
    }

    var start: usize = 0;
    if (init_val == null and items.len > 1) start = 1;

    var i = start;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try acc.clone(env_env.allocator));
        try arg_list.append(env_env.allocator, try items[i].clone(env_env.allocator));

        var new_acc = try eval_helpers.callBuiltin(env_env.allocator, f, arg_list, env_env);
        acc.deinit(env_env.allocator);
        // Check for early reduction termination
        if (new_acc.type == .reduced) {
            if (new_acc.reduced_val) |data| {
                acc = data.*;
                // Null out pointer before deinit to avoid double-free
                new_acc.reduced_val = null;
                new_acc.deinit(env_env.allocator);
                return acc;
            }
        }
        acc = new_acc;
    }
    return acc;
}

// reduced - wrap x for early reduction termination
pub fn core_reduced(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.reducedValue(env_env.allocator, args.items[0]);
}

// reduced? - check if value is a reduced wrapper
pub fn core_reduced_q(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].isReduced());
}

// ensure-reduced - if already reduced, return as-is; else wrap in reduced
pub fn core_ensure_reduced(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    if (args.items[0].isReduced()) {
        return try args.items[0].clone(env_env.allocator);
    }
    return Value.reducedValue(env_env.allocator, args.items[0]);
}

// unreduced - unwrap reduced value if reduced, else return as-is
pub fn core_unreduced(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.unreducedValue(env_env.allocator, args.items[0]);
}

pub fn core_flatten(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return doFlatten(env_env.allocator, args.items[0], env_env);
}

fn doFlatten(allocator: Allocator, val: Value, env: *Env) anyerror!Value {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    switch (val.type) {
        .list => {
            for (val.list_val.items) |item| {
                var flattened = try doFlatten(allocator, item, env);
                if (flattened.type == .list) {
                    for (flattened.list_val.items) |elem| {
                        try result.append(allocator, try elem.clone(allocator));
                    }
                    flattened.deinit(allocator);
                } else {
                    try result.append(allocator, flattened);
                }
            }
        },
        .vector => {
            for (val.vec_val.items) |item| {
                var flattened = try doFlatten(allocator, item, env);
                if (flattened.type == .list) {
                    for (flattened.list_val.items) |elem| {
                        try result.append(allocator, try elem.clone(allocator));
                    }
                    flattened.deinit(allocator);
                } else {
                    try result.append(allocator, flattened);
                }
            }
        },
        else => {
            try result.append(allocator, try val.clone(allocator));
        },
    }
    return Value.listValue(result);
}

pub fn core_next(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    var rest = try sequences_mod.core_rest(self, args, env_env);
    if (rest.type == .list and rest.list_val.items.len == 0) {
        rest.deinit(env_env.allocator);
        return Value.nilValue();
    }
    return rest;
}

pub fn core_nthnext(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    if (args.items.len != 2) return error.ArityError;
    const n = try toInt(args.items[0]);
    if (n <= 0) return try sequences_mod.core_seq(self, args, env_env);

    const coll = args.items[1];
    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    if (@as(usize, @intCast(n)) >= items.len) return Value.nilValue();

    var result: list.List = .empty;
    try result.ensureTotalCapacity(env_env.allocator, items.len - @as(usize, @intCast(n)));
    errdefer result.deinit(env_env.allocator);
    var i: usize = @as(usize, @intCast(n));
    while (i < items.len) : (i += 1) {
        try result.append(env_env.allocator, try items[i].clone(env_env.allocator));
    }
    return Value.listValue(result);
}

pub fn core_filter(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var pred_result = try eval_helpers.callBuiltin(env_env.allocator, f, arg_list, env_env);
        defer pred_result.deinit(env_env.allocator);
        if (pred_result.isTruthy()) {
            try result.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.listValue(result);
}

pub fn core_remove(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var pred_result = try eval_helpers.callBuiltin(env_env.allocator, f, arg_list, env_env);
        defer pred_result.deinit(env_env.allocator);
        if (!pred_result.isTruthy()) {
            try result.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.listValue(result);
}

pub fn core_every_q(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        .set => items = coll.set_val.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var pred_result = try eval_helpers.callBuiltin(env_env.allocator, f, arg_list, env_env);
        defer pred_result.deinit(env_env.allocator);
        if (!pred_result.isTruthy()) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_some(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        .set => items = coll.set_val.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var result = try eval_helpers.callBuiltin(env_env.allocator, f, arg_list, env_env);
        if (result.isTruthy()) return result;
        result.deinit(env_env.allocator);
    }
    return Value.nilValue();
}

pub fn core_distinct_q(_: *Value, args: list.List, _: *Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    for (items, 0..) |item, i| {
        var j: usize = i + 1;
        while (j < items.len) : (j += 1) {
            if (item.equals(items[j])) return Value.boolValue(false);
        }
    }
    return Value.boolValue(true);
}

pub fn core_drop(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const n = try toInt(args.items[0]);
    const coll = args.items[1];

    // For lazy_seq and cons, return a lazy-seq that preserves laziness
    // Mirrors Clojure: (lazy-seq (when (pos? n) (when-let [s (seq coll)]
    //   (if (zero? (dec n)) s (drop (dec n) (rest s))))))
    if (coll.type == .lazy_seq or coll.type == .cons) {
        if (n <= 0) return try coll.clone(allocator);
        return dropLazySeq(allocator, n, coll, env_env);
    }

    var items: []const Value = undefined;
    var is_list: bool = false;
    switch (coll.type) {
        .list => { items = coll.list_val.items; is_list = true; },
        .vector => { items = coll.vec_val.items; is_list = false; },
        else => return error.TypeError,
    }

    if (n <= 0) return try coll.clone(env_env.allocator);
    if (@as(usize, @intCast(n)) >= items.len) {
        if (is_list) return Value.listValue(list.empty());
        return Value.vectorValue(vec.Vector.empty);
    }

    const start: usize = @as(usize, @intCast(n));
    if (is_list) {
        var result: list.List = .empty;
        errdefer result.deinit(env_env.allocator);
        var i: usize = start;
        while (i < items.len) : (i += 1) {
            try result.append(env_env.allocator, try items[i].clone(env_env.allocator));
        }
        return Value.listValue(result);
    } else {
        var result: vec.Vector = .empty;
        errdefer result.deinit(env_env.allocator);
        var i: usize = start;
        while (i < items.len) : (i += 1) {
            try result.append(env_env.allocator, try items[i].clone(env_env.allocator));
        }
        return Value.vectorValue(result);
    }
}

/// Build a lazy-seq for (drop n coll) where coll is lazy_seq or cons.
/// Uses a self-referencing thunk so recursive calls go through core_drop directly.
fn dropLazySeq(allocator: Allocator, n: i64, coll: Value, env: *Env) anyerror!Value {
    const thunk = try allocator.create(Value.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = try env.clone(allocator),
    };
    try thunk.env.put("n", Value.intValue(n));
    try thunk.env.put("coll", try coll.clone(allocator));
    // Self-reference: thunk calls core_drop directly
    try thunk.env.put("__zig_drop", Value.builtinFnValue(core_drop));

    // Build thunk body:
    // (if (pos? n)
    //   (let [s (seq coll)]
    //     (if s
    //       (if (zero? (dec n)) (rest s) (__zig_drop (dec n) (rest s)))
    //       nil))
    //   coll)
    const a = allocator;
    const sym_if = try Value.symValue(a, "if");
    const sym_pos_q = try Value.symValue(a, "pos?");
    const sym_n = try Value.symValue(a, "n");
    const sym_coll = try Value.symValue(a, "coll");
    const sym_let = try Value.symValue(a, "let");
    const sym_s = try Value.symValue(a, "s");
    const sym_seq = try Value.symValue(a, "seq");
    const sym_zero_q = try Value.symValue(a, "zero?");
    const sym_dec = try Value.symValue(a, "dec");
    const sym_rest = try Value.symValue(a, "rest");
    const sym_zig_drop = try Value.symValue(a, "__zig_drop");
    const sym_nil = Value.nilValue();

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
    try bindings.append(a, Value.listValue(seq_call));

    // (dec n)
    var dec_call: list.List = .empty;
    try dec_call.append(a, sym_dec);
    try dec_call.append(a, sym_n);

    // (zero? (dec n))
    var zero_call: list.List = .empty;
    try zero_call.append(a, sym_zero_q);
    try zero_call.append(a, Value.listValue(dec_call));

    // (rest s)
    var rest_call: list.List = .empty;
    try rest_call.append(a, sym_rest);
    try rest_call.append(a, sym_s);

    // (__zig_drop (dec n) (rest s))
    var drop_call: list.List = .empty;
    try drop_call.append(a, sym_zig_drop);
    try drop_call.append(a, Value.listValue(dec_call));
    try drop_call.append(a, Value.listValue(rest_call));

    // (if (zero? (dec n)) (rest s) (__zig_drop (dec n) (rest s)))
    var inner_if: list.List = .empty;
    try inner_if.append(a, sym_if);
    try inner_if.append(a, Value.listValue(zero_call));
    try inner_if.append(a, Value.listValue(rest_call));
    try inner_if.append(a, Value.listValue(drop_call));

    // (if s (inner_if) nil)
    var s_check: list.List = .empty;
    try s_check.append(a, sym_if);
    try s_check.append(a, sym_s);
    try s_check.append(a, Value.listValue(inner_if));
    try s_check.append(a, sym_nil);

    // (let [s (seq coll)] (if s ... nil))
    var let_form: list.List = .empty;
    try let_form.append(a, sym_let);
    try let_form.append(a, Value.listValue(bindings));
    try let_form.append(a, Value.listValue(s_check));

    // (if (pos? n) (let ...) coll)
    var body: list.List = .empty;
    try body.append(a, sym_if);
    try body.append(a, Value.listValue(pos_call));
    try body.append(a, Value.listValue(let_form));
    try body.append(a, sym_coll);

    thunk.body = body;
    return Value.lazySeqValue(thunk);
}

// doall* - realizes a lazy sequence and returns the realized list
pub fn core_doall_star(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var coll = try args.items[0].clone(allocator);
    defer coll.deinit(allocator);

    // Recursively force lazy sequences
    return forceValue(allocator, coll);
}

fn forceValue(allocator: Allocator, val: Value) anyerror!Value {
    const result = switch (val.type) {
        .lazy_seq => {
            // Evaluate the thunk
            if (val.lazy_seq_val.thunk) |thunk| {
                const cloned_params = try list.clone(&thunk.params, allocator);
                const cloned_body = try list.clone(&thunk.body, allocator);
                var thunk_env = try thunk.env.clone(allocator);

                const fn_val = try Value.fnValueSingle(allocator, cloned_params, cloned_body, thunk_env, null, false);
                var result = try eval_helpers.callBuiltin(
                    allocator,
                    fn_val,
                    list.empty(),
                    &thunk_env,
                );

                // Force each element of the result
                switch (result.type) {
                    .list => {
                        var forced_list: list.List = .empty;
                        errdefer forced_list.deinit(allocator);
                        // Handle cons cell pattern: [head, lazy_seq_tail]
                        // forceLazySeqHelper returns at most 2 items from a cons
                        if (result.list_val.items.len == 2 and result.list_val.items[1].type == .lazy_seq) {
                            // Force the head if it's a lazy_seq, otherwise clone
                            const head_item = result.list_val.items[0];
                            if (head_item.type == .lazy_seq) {
                                const head_forced = try forceValue(allocator, head_item);
                                // Append the forced head as a single element (don't flatten)
                                try forced_list.append(allocator, head_forced);
                            } else {
                                try forced_list.append(allocator, try head_item.clone(allocator));
                            }
                            // Force the tail lazy_seq recursively
                            var tail_forced = try forceValue(allocator, result.list_val.items[1]);
                            if (tail_forced.type == .list) {
                                for (tail_forced.list_val.items) |fi| {
                                    try forced_list.append(allocator, try fi.clone(allocator));
                                }
                            }
                            tail_forced.deinit(allocator);
                        } else {
                            for (result.list_val.items) |item| {
                                // Only force lazy_seq items; clone everything else
                                if (item.type == .lazy_seq) {
                                    var forced = try forceValue(allocator, item);
                                    if (forced.type == .list) {
                                        for (forced.list_val.items) |fi| {
                                            try forced_list.append(allocator, try fi.clone(allocator));
                                        }
                                    } else {
                                        try forced_list.append(allocator, forced);
                                    }
                                    forced.deinit(allocator);
                                } else {
                                    try forced_list.append(allocator, try item.clone(allocator));
                                }
                            }
                        }
                        result.deinit(allocator);
                        return Value.listValue(forced_list);
                    },
                    .vector => {
                        var forced_vec: vec.Vector = .empty;
                        errdefer forced_vec.deinit(allocator);
                        for (result.vec_val.items) |item| {
                            // Only force lazy_seq items; clone everything else
                            if (item.type == .lazy_seq) {
                                var forced = try forceValue(allocator, item);
                                if (forced.type == .list) {
                                    for (forced.list_val.items) |fi| {
                                        try forced_vec.append(allocator, try fi.clone(allocator));
                                    }
                                } else {
                                    try forced_vec.append(allocator, forced);
                                }
                                forced.deinit(allocator);
                            } else {
                                try forced_vec.append(allocator, try item.clone(allocator));
                            }
                        }
                        result.deinit(allocator);
                        return Value.vectorValue(forced_vec);
                    },
                    .nil => {
                        // Thunk returned nil (empty sequence)
                        result.deinit(allocator);
                        return Value.listValue(list.empty());
                    },
                    .lazy_seq => {
                        // Thunk returned a lazy_seq (e.g., from cons). Recursively force it.
                        const forced = try forceValue(allocator, result);
                        result.deinit(allocator);
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
                            if (item.type == .lazy_seq) {
                                var forced = try forceValue(allocator, item);
                                if (forced.type == .list) {
                                    for (forced.list_val.items) |fi| {
                                        try forced_list.append(allocator, try fi.clone(allocator));
                                    }
                                } else {
                                    try forced_list.append(allocator, forced);
                                }
                                forced.deinit(allocator);
                            } else {
                                try forced_list.append(allocator, try item.clone(allocator));
                            }
                        }
                        concrete.deinit(allocator);
                        return Value.listValue(forced_list);
                    },
                    else => {
                        const forced = try forceValue(allocator, result);
                        result.deinit(allocator);
                        return forced;
                    },
                }
            }
            return Value.listValue(list.empty());
        },
        .list => {
            // For standalone lists, just clone them (they're data, not thunk results)
            return try val.clone(allocator);
        },
        .vector => {
            var forced_vec: vec.Vector = .empty;
            errdefer forced_vec.deinit(allocator);
            for (val.vec_val.items) |item| {
                // Flatten lazy_seq elements
                if (item.type == .lazy_seq) {
                    var forced = try sequences_mod.forceLazySeqHelper(allocator, item);
                    defer forced.deinit(allocator);
                    for (forced.list_val.items) |fi| {
                        const recursively_forced = try forceValue(allocator, fi);
                        try forced_vec.append(allocator, recursively_forced);
                    }
                } else {
                    const forced_item = try forceValue(allocator, item);
                    try forced_vec.append(allocator, forced_item);
                }
            }
            return Value.vectorValue(forced_vec);
        },
        .cons => {
            // Force cons cells: walk the chain and force nested lazy_seqs
            // Clone all elements, don't consume the original
            var forced_list: list.List = .empty;
            errdefer forced_list.deinit(allocator);
            var current: Value = val;
            while (true) {
                switch (current.type) {
                    .cons => {
                        const cdata = current.cons_val.?;
                        // Force the head if it's a lazy_seq
                        if (cdata.head.type == .lazy_seq) {
                            var head_forced = try forceValue(allocator, cdata.head);
                            if (head_forced.type == .list) {
                                for (head_forced.list_val.items) |fi| {
                                    try forced_list.append(allocator, try fi.clone(allocator));
                                }
                            } else {
                                try forced_list.append(allocator, head_forced);
                            }
                            head_forced.deinit(allocator);
                        } else {
                            try forced_list.append(allocator, try cdata.head.clone(allocator));
                        }
                        // Move to tail (clone it, current is still the original cons)
                        const tail = try cdata.tail.clone(allocator);
                        current = tail;
                    },
                    .list => {
                        for (current.list_val.items) |item| {
                            if (item.type == .lazy_seq) {
                                var forced = try forceValue(allocator, item);
                                if (forced.type == .list) {
                                    for (forced.list_val.items) |fi| {
                                        try forced_list.append(allocator, try fi.clone(allocator));
                                    }
                                } else {
                                    try forced_list.append(allocator, forced);
                                }
                                forced.deinit(allocator);
                            } else {
                                try forced_list.append(allocator, try item.clone(allocator));
                            }
                        }
                        current.deinit(allocator);
                        break;
                    },
                    .nil => {
                        current.deinit(allocator);
                        break;
                    },
                    .lazy_seq => {
                        var forced = try forceValue(allocator, current);
                        if (forced.type == .list) {
                            for (forced.list_val.items) |fi| {
                                try forced_list.append(allocator, try fi.clone(allocator));
                            }
                        }
                        forced.deinit(allocator);
                        current.deinit(allocator);
                        break;
                    },
                    else => {
                        try forced_list.append(allocator, try current.clone(allocator));
                        current.deinit(allocator);
                        break;
                    },
                }
            }
            return Value.listValue(forced_list);
        },
        else => try val.clone(allocator),
    };
    return result;
}

// iterate: repeatedly apply f to init, lazily
// Mirrors Clojure: returns a lazy (infinite!) sequence of x, (f x), (f (f x)) etc.
pub fn core_iterate(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const f = args.items[0];
    const x = args.items[1];

    // Return a lazy-seq: (lazy-seq (cons x (__zig_iterate f (f x))))
    // We use __zig_iterate (a private self-reference) instead of the global
    // "iterate" symbol, so the thunk calls this Zig function directly without
    // going through any Clojure wrapper (e.g. core.clj defn delegating to zig.core/iterate).
    const thunk = try allocator.create(Value.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = try env_env.clone(allocator),
    };
    try thunk.env.put("f", try f.clone(allocator));
    try thunk.env.put("x", try x.clone(allocator));
    // Store a self-reference so the thunk body calls core_iterate directly
    try thunk.env.put("__zig_iterate", Value.builtinFnValue(core_iterate));

    // Build thunk body: (cons x (__zig_iterate f (f x)))
    const a = allocator;
    const sym_cons = try Value.symValue(a, "cons");
    const sym_x = try Value.symValue(a, "x");
    const sym_f = try Value.symValue(a, "f");
    const sym_zig_iterate = try Value.symValue(a, "__zig_iterate");

    // (f x)
    var f_call: list.List = .empty;
    try f_call.append(a, sym_f);
    try f_call.append(a, sym_x);

    // (__zig_iterate f (f x))
    var iterate_call: list.List = .empty;
    try iterate_call.append(a, sym_zig_iterate);
    try iterate_call.append(a, sym_f);
    try iterate_call.append(a, Value.listValue(f_call));

    // (cons x (__zig_iterate f (f x)))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, sym_x);
    try cons_call.append(a, Value.listValue(iterate_call));

    thunk.body = cons_call;
    return Value.lazySeqValue(thunk);
}

// cycle: returns a lazy (infinite) sequence of repetitions of the items in coll
// Mirrors Clojure: (lazy-seq (when-let [s (seq coll)] (concat s (cycle coll))))
// Uses cons-based approach to avoid concat's lazy-seq embedding issue
pub fn core_cycle(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    const coll = args.items[0];

    // Return a lazy-seq: (lazy-seq (let [s (seq coll)] (when s (cons (first s) (__zig_cycle (conj (vec (rest s)) (first s)))))))
    const thunk = try allocator.create(Value.LazySeqThunk);
    thunk.* = .{ .params = list.empty(), .body = list.empty(), .env = try env_env.clone(allocator) };
    try thunk.env.put("coll", try coll.clone(allocator));
    // Self-reference: thunk calls core_cycle directly, not via global symbol
    try thunk.env.put("__zig_cycle", Value.builtinFnValue(core_cycle));

    const a = allocator;
    const sym_let = try Value.symValue(a, "let");
    const sym_s = try Value.symValue(a, "s");
    const sym_seq = try Value.symValue(a, "seq");
    const sym_coll = try Value.symValue(a, "coll");
    const sym_when = try Value.symValue(a, "when");
    const sym_cons = try Value.symValue(a, "cons");
    const sym_first = try Value.symValue(a, "first");
    const sym_zig_cycle = try Value.symValue(a, "__zig_cycle");
    const sym_conj = try Value.symValue(a, "conj");
    const sym_vec = try Value.symValue(a, "vec");
    const sym_rest = try Value.symValue(a, "rest");

    // (seq coll)
    var seq_call: list.List = .empty;
    try seq_call.append(a, sym_seq);
    try seq_call.append(a, sym_coll);

    // [s (seq coll)]
    var bindings: list.List = .empty;
    try bindings.append(a, sym_s);
    try bindings.append(a, Value.listValue(seq_call));

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
    try vec_call.append(a, Value.listValue(rest_call));

    // (conj (vec (rest s)) (first s))
    var conj_call: list.List = .empty;
    try conj_call.append(a, sym_conj);
    try conj_call.append(a, Value.listValue(vec_call));
    try conj_call.append(a, Value.listValue(first_call));

    // (__zig_cycle (conj (vec (rest s)) (first s)))
    var cycle_call: list.List = .empty;
    try cycle_call.append(a, sym_zig_cycle);
    try cycle_call.append(a, Value.listValue(conj_call));

    // (cons (first s) (cycle ...))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, Value.listValue(first_call));
    try cons_call.append(a, Value.listValue(cycle_call));

    // (when s (cons ...))
    var when_call: list.List = .empty;
    try when_call.append(a, sym_when);
    try when_call.append(a, sym_s);
    try when_call.append(a, Value.listValue(cons_call));

    // (let [s (seq coll)] (when s (cons ...)))
    var body: list.List = .empty;
    try body.append(a, sym_let);
    try body.append(a, Value.listValue(bindings));
    try body.append(a, Value.listValue(when_call));

    thunk.body = body;
    return Value.lazySeqValue(thunk);
}

pub fn registerSequenceOpFunctions(env: *Env) anyerror!void {
    try env.put("map", Value.builtinFnValue(core_map));
    try env.put("mapcat", Value.builtinFnValue(core_mapcat));
    try env.put("reduce", Value.builtinFnValue(core_reduce));
    try env.put("flatten", Value.builtinFnValue(core_flatten));
    try env.put("filter", Value.builtinFnValue(core_filter));
    try env.put("remove", Value.builtinFnValue(core_remove));
    try env.put("every?", Value.builtinFnValue(core_every_q));
    try env.put("some", Value.builtinFnValue(core_some));
    try env.put("distinct?", Value.builtinFnValue(core_distinct_q));
    try env.put("next", Value.builtinFnValue(core_next));
    try env.put("nthnext", Value.builtinFnValue(core_nthnext));
    try env.put("drop", Value.builtinFnValue(core_drop));
    try env.put("doall*", Value.builtinFnValue(core_doall_star));
    try env.put("iterate", Value.builtinFnValue(core_iterate));
    try env.put("cycle", Value.builtinFnValue(core_cycle));

    // Reduced wrapper functions
    try env.put("reduced", Value.builtinFnValue(core_reduced));
    try env.put("reduced?", Value.builtinFnValue(core_reduced_q));
    try env.put("ensure-reduced", Value.builtinFnValue(core_ensure_reduced));
    try env.put("unreduced", Value.builtinFnValue(core_unreduced));
}

const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "seq_ops::flatten: nested list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    // Build: (1 (2 3) 4)
    var inner: list.List = .empty;
    _ = inner.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = inner.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    var outer: list.List = .empty;
    _ = outer.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = outer.append(std.heap.page_allocator, Value.listValue(inner)) catch unreachable;
    _ = outer.append(std.heap.page_allocator, Value.intValue(4)) catch unreachable;
    const lv = Value.listValue(outer);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_flatten(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 4);
    try std.testing.expect(result.list_val.items[0].int_val == 1);
    try std.testing.expect(result.list_val.items[1].int_val == 2);
    try std.testing.expect(result.list_val.items[2].int_val == 3);
    try std.testing.expect(result.list_val.items[3].int_val == 4);
}

test "seq_ops::distinct_q: all distinct" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_distinct_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "seq_ops::distinct_q: has duplicates" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_distinct_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "seq_ops::drop: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(4)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ Value.intValue(2), lv });
    var result = core_drop(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 2);
    try std.testing.expect(result.list_val.items[0].int_val == 3);
}

test "seq_ops::drop: more than length returns empty" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ Value.intValue(5), lv });
    var result = core_drop(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 0);
}

test "seq_ops::next: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_next(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 2);
    try std.testing.expect(result.list_val.items[0].int_val == 2);
}

test "seq_ops::next: single element returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_next(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .nil);
}

test "seq_ops::nthnext: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(4)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ Value.intValue(2), lv });
    var result = core_nthnext(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 2);
    try std.testing.expect(result.list_val.items[0].int_val == 3);
}

test "seq_ops::nthnext: out of range returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ Value.intValue(5), lv });
    var result = core_nthnext(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .nil);
}


test "seq_ops::reduced: wraps value" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_reduced(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .reduced);
    try std.testing.expect(result.reduced_val.?.int_val == 42);
}

test "seq_ops::reduced_q: true for reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var reduced_val = Value.reducedValue(std.heap.page_allocator, Value.intValue(42)) catch unreachable;
    defer reduced_val.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ reduced_val });
    var result = core_reduced_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .bool);
    try std.testing.expect(result.bool_val == true);
}

test "seq_ops::reduced_q: false for non-reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_reduced_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .bool);
    try std.testing.expect(result.bool_val == false);
}

test "seq_ops::ensure_reduced: wraps non-reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_ensure_reduced(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .reduced);
}

test "seq_ops::ensure_reduced: passes through reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var reduced_val = Value.reducedValue(std.heap.page_allocator, Value.intValue(42)) catch unreachable;
    defer reduced_val.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ reduced_val });
    var result = core_ensure_reduced(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .reduced);
}

test "seq_ops::unreduced: unwraps reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var reduced_val = Value.reducedValue(std.heap.page_allocator, Value.intValue(42)) catch unreachable;
    defer reduced_val.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ reduced_val });
    var result = core_unreduced(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == 42);
}

test "seq_ops::unreduced: passes through non-reduced" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_unreduced(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == 42);
}
