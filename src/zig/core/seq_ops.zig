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

const toInt = helpers.toInt;
const Allocator = std.mem.Allocator;

pub fn core_map(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    // Validate that coll is a supported collection type
    switch (coll.type) {
        .list, .vector, .range_val => {},
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

    // Handle range_val directly (no list allocation needed)
    if (coll.type == .range_val) {
        const rd: *Value.RangeData = coll.range_val.?;
        const len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;

        // Fast path: reduce + on range (all integers)
        if (f.type == .builtin_fn and f.builtin_fn_val == arithmetic.core_plus) {
            if (len == 0) {
                if (init_val) |iv| return try iv.clone(env_env.allocator);
                return Value.nilValue();
            }
            if (init_val) |iv| {
                var acc: i64 = if (iv.type == .integer) iv.int_val else @as(i64, @intFromFloat(iv.float_val));
                var v: i64 = rd.start;
                var count: usize = 0;
                while (count < len) : (count += 1) {
                    acc += v;
                    v += rd.step;
                }
                return Value.intValue(acc);
            }
            // No init: use first element as initial
            var acc: i64 = rd.start;
            var v: i64 = rd.start + rd.step;
            var count: usize = 1;
            while (count < len) : (count += 1) {
                acc += v;
                v += rd.step;
            }
            return Value.intValue(acc);
        }

        // General path for range: iterate with function calls
        if (len == 0) {
            if (init_val) |iv| return try iv.clone(env_env.allocator);
            return Value.nilValue();
        }
        var acc: Value = undefined;
        if (init_val) |iv| {
            acc = try iv.clone(env_env.allocator);
        } else {
            acc = Value.intValue(rd.start);
        }
        var v: i64 = if (init_val != null) rd.start else rd.start + rd.step;
        var count: usize = if (init_val != null) 0 else 1;
        while (count < len) : (count += 1) {
            var arg_list: list.List = .empty;
            defer arg_list.deinit(env_env.allocator);
            try arg_list.append(env_env.allocator, try acc.clone(env_env.allocator));
            try arg_list.append(env_env.allocator, Value.intValue(v));
            const new_acc = try eval_helpers.callBuiltin(env_env.allocator, f, arg_list, env_env);
            acc.deinit(env_env.allocator);
            acc = new_acc;
            v += rd.step;
        }
        return acc;
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
}

