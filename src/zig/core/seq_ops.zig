// Higher-order sequence operations: map, mapcat, reduce, flatten, filter,
// remove, every?, some, distinct?, next, nthnext, drop
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const Env = Value.Env;
const helpers = @import("helpers.zig");
const eval_helpers = @import("eval_helpers.zig");
const arithmetic = @import("arithmetic.zig");
const sequences_mod = @import("sequences.zig");

const Allocator = std.mem.Allocator;

const toInt = helpers.toInt;

// Force a lazy_seq into a concrete list
pub fn forceLazySeqToConcreteList(allocator: Allocator, val: Value) anyerror!list.List {
    var forced = try forceValue(allocator, val);
    defer forced.deinit(allocator);
    switch (forced.type) {
        .list => return try list.clone(&forced.list_val, allocator),
        .vector => {
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            for (forced.vec_val.items) |item| {
                try result.append(allocator, try item.clone(allocator));
            }
            return result;
        },
        .nil => return list.empty(),
        else => {
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            try result.append(allocator, try forced.clone(allocator));
            return result;
        },
    }
}

// Force any lazy value (lazy_seq) into a concrete list
fn forceToConcreteList(allocator: Allocator, val: Value) anyerror!list.List {
    return switch (val.type) {
        .lazy_seq => return forceLazySeqToConcreteList(allocator, val),
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

    // Build thunk body: (let [s (seq coll)] (if s (cons (f (first s)) (map f (rest s)))))
    // All symbols and the body are allocated from the persistent allocator
    const a = allocator;

    // Symbols needed in the thunk body
    const sym_let = try Value.symValue(a, "let");
    const sym_s = try Value.symValue(a, "s");
    const sym_seq = try Value.symValue(a, "seq");
    const sym_coll = try Value.symValue(a, "coll");
    const sym_if = try Value.symValue(a, "if");
    const sym_cons = try Value.symValue(a, "cons");
    const sym_f = try Value.symValue(a, "f");
    const sym_first = try Value.symValue(a, "first");
    const sym_map = try Value.symValue(a, "map");
    const sym_rest = try Value.symValue(a, "rest");

    // Build: (seq coll)
    var seq_call: list.List = .empty;
    try seq_call.append(a, sym_seq);
    try seq_call.append(a, sym_coll);

    // Build: [s (seq coll)]
    var bindings: list.List = .empty;
    try bindings.append(a, sym_s);
    try bindings.append(a, Value.listValue(seq_call));

    // Build: (f (first s))
    var first_s_call: list.List = .empty;
    try first_s_call.append(a, sym_first);
    try first_s_call.append(a, sym_s);
    var f_call: list.List = .empty;
    try f_call.append(a, sym_f);
    try f_call.append(a, Value.listValue(first_s_call));

    // Build: (rest s)
    var rest_call: list.List = .empty;
    try rest_call.append(a, sym_rest);
    try rest_call.append(a, sym_s);

    // Build: (map f (rest s))
    var map_call: list.List = .empty;
    try map_call.append(a, sym_map);
    try map_call.append(a, sym_f);
    try map_call.append(a, Value.listValue(rest_call));

    // Build: (cons (f (first s)) (map f (rest s)))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, Value.listValue(f_call));
    try cons_call.append(a, Value.listValue(map_call));

    // Build: (if s (cons ...))
    var if_form: list.List = .empty;
    try if_form.append(a, sym_if);
    try if_form.append(a, sym_s);
    try if_form.append(a, Value.listValue(cons_call));

    // Build: (let [s (seq coll)] (if s (cons ...)))
    var body: list.List = .empty;
    try body.append(a, sym_let);
    try body.append(a, Value.listValue(bindings));
    try body.append(a, Value.listValue(if_form));

    // Create thunk with persistent allocator for body and cloned env
    const thunk = try allocator.create(Value.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = body,
        .env = try env_env.clone(allocator),
    };
    // Bind f and coll in the thunk's environment
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
        var items: []const Value = undefined;
        switch (coll.type) {
            .list => items = coll.list_val.items,
            .vector => items = coll.vec_val.items,
            else => continue,
        }
        for (items) |item| {
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

        const new_acc = try eval_helpers.callBuiltin(env_env.allocator, f, arg_list, env_env);
        acc.deinit(env_env.allocator);
        acc = new_acc;
    }
    return acc;
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
    const n = try toInt(args.items[0]);
    const coll = args.items[1];

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
    return switch (val.type) {
        .lazy_seq => {
            // Evaluate the thunk
            if (val.lazy_seq_val.thunk) |thunk| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                const arena_alloc = arena.allocator();

                const cloned_params = try list.clone(&thunk.params, arena_alloc);
                const cloned_body = try list.clone(&thunk.body, arena_alloc);
                var thunk_env = try thunk.env.clone(arena_alloc);

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
                        for (result.list_val.items) |item| {
                            // Flatten lazy_seq elements
                            if (item.type == .lazy_seq) {
                                var forced = try sequences_mod.forceLazySeqHelper(allocator, item);
                                defer forced.deinit(allocator);
                                for (forced.list_val.items) |fi| {
                                    try forced_list.append(allocator, try fi.clone(allocator));
                                }
                            } else {
                                const forced_item = try forceValue(allocator, item);
                                try forced_list.append(allocator, forced_item);
                            }
                        }
                        result.deinit(arena_alloc);
                        arena.deinit();
                        return Value.listValue(forced_list);
                    },
                    .vector => {
                        var forced_vec: vec.Vector = .empty;
                        errdefer forced_vec.deinit(allocator);
                        for (result.vec_val.items) |item| {
                            // Flatten lazy_seq elements
                            if (item.type == .lazy_seq) {
                                var forced = try sequences_mod.forceLazySeqHelper(allocator, item);
                                defer forced.deinit(allocator);
                                for (forced.list_val.items) |fi| {
                                    try forced_vec.append(allocator, try fi.clone(allocator));
                                }
                            } else {
                                const forced_item = try forceValue(allocator, item);
                                try forced_vec.append(allocator, forced_item);
                            }
                        }
                        result.deinit(arena_alloc);
                        arena.deinit();
                        return Value.vectorValue(forced_vec);
                    },
                    .nil => {
                        result.deinit(arena_alloc);
                        arena.deinit();
                        return Value.nilValue();
                    },
                    else => {
                        const forced = try forceValue(allocator, result);
                        result.deinit(arena_alloc);
                        arena.deinit();
                        return forced;
                    },
                }
            }
            return Value.listValue(list.empty());
        },
        .list => {
            var forced_list: list.List = .empty;
            errdefer forced_list.deinit(allocator);
            for (val.list_val.items) |item| {
                // Flatten lazy_seq elements
                if (item.type == .lazy_seq) {
                    var forced = try sequences_mod.forceLazySeqHelper(allocator, item);
                    defer forced.deinit(allocator);
                    for (forced.list_val.items) |fi| {
                        try forced_list.append(allocator, try fi.clone(allocator));
                    }
                } else {
                    const forced_item = try forceValue(allocator, item);
                    try forced_list.append(allocator, forced_item);
                }
            }
            return Value.listValue(forced_list);
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
                        try forced_vec.append(allocator, try fi.clone(allocator));
                    }
                } else {
                    const forced_item = try forceValue(allocator, item);
                    try forced_vec.append(allocator, forced_item);
                }
            }
            return Value.vectorValue(forced_vec);
        },
        else => try val.clone(allocator),
    };
}

// iterate: repeatedly apply f to init, lazily
// Mirrors Clojure: returns a lazy (infinite!) sequence of x, (f x), (f (f x)) etc.
pub fn core_iterate(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const f = args.items[0];
    const x = args.items[1];

    // Return a lazy-seq: (lazy-seq (cons x (iterate f (f x))))
    const thunk = try allocator.create(Value.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = try env_env.clone(allocator),
    };
    try thunk.env.put("f", try f.clone(allocator));
    try thunk.env.put("x", try x.clone(allocator));

    // Build thunk body: (cons x (iterate f (f x)))
    const a = allocator;
    const sym_cons = try Value.symValue(a, "cons");
    const sym_x = try Value.symValue(a, "x");
    const sym_f = try Value.symValue(a, "f");
    const sym_iterate = try Value.symValue(a, "iterate");

    // (f x)
    var f_call: list.List = .empty;
    try f_call.append(a, sym_f);
    try f_call.append(a, sym_x);

    // (iterate f (f x))
    var iterate_call: list.List = .empty;
    try iterate_call.append(a, sym_iterate);
    try iterate_call.append(a, sym_f);
    try iterate_call.append(a, Value.listValue(f_call));

    // (cons x (iterate f (f x)))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, sym_x);
    try cons_call.append(a, Value.listValue(iterate_call));

    thunk.body = cons_call;
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
}

// ===== Unit Tests =====

fn testEnv() Value.Env {
    return Value.Env.init(std.heap.page_allocator);
}

fn makeArgs(args: []const Value) list.List {
    var result: list.List = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        _ = result.append(std.heap.page_allocator, args[i]) catch unreachable;
    }
    return result;
}

var _testSelf: Value = Value.nilValue();
fn testSelf() *Value {
    return &_testSelf;
}

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

