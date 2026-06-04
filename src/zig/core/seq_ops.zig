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

const Allocator = std.mem.Allocator;

const toInt = helpers.toInt;

// Force a lazy_map into a concrete list
fn forceLazyMap(allocator: Allocator, lm: *Value.LazyMapData, env: *Env) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var coll_items: []const Value = undefined;
    const coll_len: usize = switch (lm.coll.type) {
        .list => lm.coll.list_val.items.len,
        .vector => lm.coll.vec_val.items.len,
        else => return result,
    };
    switch (lm.coll.type) {
        .list => coll_items = lm.coll.list_val.items,
        .vector => coll_items = lm.coll.vec_val.items,
        else => return result,
    }
    var i: usize = lm.idx;
    while (i < coll_len) : (i += 1) {
        var arg_list: list.List = .empty;
        errdefer arg_list.deinit(allocator);
        try arg_list.append(allocator, try coll_items[i].clone(allocator));
        const mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env);
        try result.append(allocator, mapped);
    }
    return result;
}

// Force any lazy value (lazy_seq or lazy_map) into a concrete list
fn forceToConcreteList(allocator: Allocator, val: Value, env: *Env) anyerror!list.List {
    return switch (val.type) {
        .lazy_map => {
            const lm = val.lazy_map_val.?;
            return forceLazyMap(allocator, lm, env);
        },
        .lazy_seq => {
            // Use forceValue which handles lazy_seq thunks
            var forced = try forceValue(allocator, val);
            defer forced.deinit(allocator);
            switch (forced.type) {
                .list => return try forced.list_val.clone(allocator),
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
        },
        else => {
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            switch (val.type) {
                .list => return try val.list_val.clone(allocator),
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
    var coll = args.items[1];

    // Force lazy sequences to concrete lists before mapping
    switch (coll.type) {
        .lazy_seq, .lazy_map => {
            const concrete_list = try forceToConcreteList(allocator, coll, env_env);
            coll = Value.listValue(concrete_list);
        },
        .list, .vector => {},
        else => return error.TypeError,
    }

    // Return a lazy_map — elements are computed on demand by dorun
    const cloned_f = try f.clone(allocator);
    const cloned_coll = try coll.clone(allocator);
    return Value.lazyMapValue(allocator, cloned_f, cloned_coll);
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
                .lazy_map, .lazy_seq => {
                    var concrete = try forceToConcreteList(allocator, mapped, env_env);
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
        .lazy_map => {
            const concrete_list = try forceToConcreteList(env_env.allocator, coll, env_env);
            // Null out the pointer before deinit so we don't free caller-owned data
            coll.lazy_map_val = null;
            coll.deinit(env_env.allocator);
            coll = Value.listValue(concrete_list);
            owned_coll = true;
        },
        .lazy_seq => {
            const concrete_list = try forceToConcreteList(env_env.allocator, coll, env_env);
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
    var rest = try core_rest(self, args, env_env);
    if (rest.type == .list and rest.list_val.items.len == 0) {
        rest.deinit(env_env.allocator);
        return Value.nilValue();
    }
    return rest;
}

fn core_rest(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    switch (args.items[0].type) {
        .list => {
            if (args.items[0].list_val.items.len <= 1) return Value.listValue(list.empty());
            const rest = args.items[0].list_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            for (rest) |item| {
                try new_list.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        .vector => {
            if (args.items[0].vec_val.items.len <= 1) return Value.listValue(list.empty());
            const rest = args.items[0].vec_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            for (rest) |item| {
                try new_list.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        else => return Value.listValue(list.empty()),
    }
}

pub fn core_nthnext(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    if (args.items.len != 2) return error.ArityError;
    const n = try toInt(args.items[0]);
    if (n <= 0) return try core_seq(self, args, env_env);

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

fn core_seq(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (coll.type) {
        .list => coll.list_val.items.len,
        .vector => coll.vec_val.items.len,
        .map => coll.map_val.items.len,
        .set => coll.set_val.items.len,
        .queue => coll.queue_val.items.len,
        else => return Value.nilValue(),
    };
    if (len == 0) return Value.nilValue();
    return try coll.clone(env_env.allocator);
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

                const cloned_params = try thunk.params.clone(arena_alloc);
                const cloned_body = try thunk.body.clone(arena_alloc);
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
                            const forced_item = try forceValue(allocator, item);
                            try forced_list.append(allocator, forced_item);
                        }
                        result.deinit(arena_alloc);
                        arena.deinit();
                        return Value.listValue(forced_list);
                    },
                    .vector => {
                        var forced_vec: vec.Vector = .empty;
                        errdefer forced_vec.deinit(allocator);
                        for (result.vec_val.items) |item| {
                            const forced_item = try forceValue(allocator, item);
                            try forced_vec.append(allocator, forced_item);
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
                const forced_item = try forceValue(allocator, item);
                try forced_list.append(allocator, forced_item);
            }
            return Value.listValue(forced_list);
        },
        .vector => {
            var forced_vec: vec.Vector = .empty;
            errdefer forced_vec.deinit(allocator);
            for (val.vec_val.items) |item| {
                const forced_item = try forceValue(allocator, item);
                try forced_vec.append(allocator, forced_item);
            }
            return Value.vectorValue(forced_vec);
        },
        else => try val.clone(allocator),
    };
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
}

