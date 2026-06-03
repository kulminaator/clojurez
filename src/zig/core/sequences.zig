// Basic sequence/collection functions: count, first, rest, nth, concat, list, vec
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const Env = Value.Env;
const eval_helpers = @import("eval_helpers.zig");
const Allocator = std.mem.Allocator;

/// Force a lazy-seq to a realized list
fn forceLazySeqHelper(allocator: Allocator, lazy: Value) anyerror!Value {
    if (lazy.lazy_seq_val.thunk) |thunk| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        const cloned_body = try thunk.body.clone(arena_alloc);
        var thunk_env = try thunk.env.clone(arena_alloc);

        // Evaluate the thunk body (already wrapped in 'do') as a list
        const body_val = Value.listValue(cloned_body);
        const result = try eval_helpers.evalForm(allocator, body_val, &thunk_env);

        // Convert to list
        var final_list: list.List = .empty;
        errdefer final_list.deinit(allocator);
        switch (result.type) {
            .list => {
                for (result.list_val.items) |item| {
                    try final_list.append(allocator, try item.clone(allocator));
                }
            },
            .vector => {
                for (result.vec_val.items) |item| {
                    try final_list.append(allocator, try item.clone(allocator));
                }
            },
            .nil => {},
            else => {
                try final_list.append(allocator, result);
            },
        }
        arena.deinit();
        return Value.listValue(final_list);
    }
    return Value.listValue(list.empty());
}

pub fn core_count(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    switch (args.items[0].type) {
        .list => return Value.intValue(@as(i64, @intCast(args.items[0].list_val.items.len))),
        .vector => return Value.intValue(@as(i64, @intCast(args.items[0].vec_val.items.len))),
        .map => return Value.intValue(@as(i64, @intCast(args.items[0].map_val.items.len))),
        .set => return Value.intValue(@as(i64, @intCast(args.items[0].set_val.items.len))),
        .queue => return Value.intValue(@as(i64, @intCast(args.items[0].queue_val.items.len))),
        .string => return Value.intValue(@as(i64, @intCast(Value.utf8CodepointCount(args.items[0].str_val)))),
        .range_val => {
            const rd: *Value.RangeData = args.items[0].range_val.?;
            const len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
            return Value.intValue(@as(i64, @intCast(len)));
        },
        else => return error.TypeError,
    }
}

pub fn core_first(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var val = try args.items[0].clone(allocator);
    defer val.deinit(allocator);
    // Force lazy_seq
    if (val.type == .lazy_seq) {
        val = try forceLazySeqHelper(allocator, val);
    }
    switch (val.type) {
        .list => {
            if (val.list_val.items.len == 0) return Value.nilValue();
            return try val.list_val.items[0].clone(allocator);
        },
        .vector => {
            if (val.vec_val.items.len == 0) return Value.nilValue();
            return try val.vec_val.items[0].clone(allocator);
        },
        else => return Value.nilValue(),
    }
}

pub fn core_rest(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var val = try args.items[0].clone(allocator);
    defer val.deinit(allocator);
    // Force lazy_seq
    if (val.type == .lazy_seq) {
        val = try forceLazySeqHelper(allocator, val);
    }
    switch (val.type) {
        .list => {
            if (val.list_val.items.len <= 1) return Value.listValue(list.empty());
            const rest = val.list_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            for (rest) |item| {
                try new_list.append(allocator, try item.clone(allocator));
            }
            return Value.listValue(new_list);
        },
        .vector => {
            if (val.vec_val.items.len <= 1) return Value.listValue(list.empty());
            const rest = val.vec_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            for (rest) |item| {
                try new_list.append(allocator, try item.clone(allocator));
            }
            return Value.listValue(new_list);
        },
        else => return Value.listValue(list.empty()),
    }
}

pub fn core_nth(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const idx = try toInt(args.items[1]);
    switch (args.items[0].type) {
        .list => {
            if (idx < 0 or @as(usize, @intCast(idx)) >= args.items[0].list_val.items.len) return Value.nilValue();
            return try args.items[0].list_val.items[@as(usize, @intCast(idx))].clone(env_env.allocator);
        },
        .vector => {
            if (idx < 0 or @as(usize, @intCast(idx)) >= args.items[0].vec_val.items.len) return Value.nilValue();
            return try args.items[0].vec_val.items[@as(usize, @intCast(idx))].clone(env_env.allocator);
        },
        .string => {
            const s = args.items[0].str_val;
            const codepoint_count = Value.utf8CodepointCount(s);
            if (idx < 0 or @as(usize, @intCast(idx)) >= codepoint_count) return Value.nilValue();
            const cp = Value.utf8CodepointAt(s, @as(usize, @intCast(idx))) orelse return Value.nilValue();
            return Value.stringValue(env_env.allocator, cp);
        },
        else => return error.TypeError,
    }
}

fn toInt(v: Value) anyerror!i64 {
    return switch (v.type) {
        .integer => v.int_val,
        .float => @as(i64, @intFromFloat(v.float_val)),
        else => return error.TypeError,
    };
}

pub fn core_take(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const n_val = args.items[0];
    const n: usize = switch (n_val.type) {
        .integer => @as(usize, @intCast(n_val.int_val)),
        .float => @as(usize, @intFromFloat(n_val.float_val)),
        else => return error.TypeError,
    };
    var coll = try args.items[1].clone(allocator);
    defer coll.deinit(allocator);
    // Force lazy_seq
    if (coll.type == .lazy_seq) {
        coll = try forceLazySeqHelper(allocator, coll);
    }
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    switch (coll.type) {
        .list => {
            const items = coll.list_val.items;
            const count = if (n < items.len) n else items.len;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                try result.append(allocator, try items[i].clone(allocator));
            }
        },
        .vector => {
            const items = coll.vec_val.items;
            const count = if (n < items.len) n else items.len;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                try result.append(allocator, try items[i].clone(allocator));
            }
        },
        .lazy_map => {
            const lm = coll.lazy_map_val.?;
            const coll_len: usize = switch (lm.coll.type) {
                .list => lm.coll.list_val.items.len,
                .vector => lm.coll.vec_val.items.len,
                else => 0,
            };
            const count = if (n < coll_len) n else coll_len;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                var arg_list: list.List = .empty;
                errdefer arg_list.deinit(allocator);
                const item = switch (lm.coll.type) {
                    .list => lm.coll.list_val.items[i],
                    .vector => lm.coll.vec_val.items[i],
                    else => continue,
                };
                try arg_list.append(allocator, try item.clone(allocator));
                const mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env_env);
                try result.append(allocator, mapped);
            }
        },
        .range_val => {
            const rd = coll.range_val.?;
            const total_len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
            const count = if (n < total_len) n else total_len;
            var v: i64 = rd.start;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                try result.append(allocator, Value.intValue(v));
                v += rd.step;
            }
        },
        else => {},
    }
    return Value.listValue(result);
}

pub fn core_concat(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    for (args.items) |arg| {
        // nil is treated as empty sequence in concat
        if (arg.type == .nil) continue;
        var val = try arg.clone(allocator);
        defer val.deinit(allocator);
        // Force lazy_seq
        if (val.type == .lazy_seq) {
            val = try forceLazySeqHelper(allocator, val);
        }
        switch (val.type) {
            .list => {
                for (val.list_val.items) |item| {
                    try result.append(allocator, try item.clone(allocator));
                }
            },
            .vector => {
                for (val.vec_val.items) |item| {
                    try result.append(allocator, try item.clone(allocator));
                }
            },
            .nil => {},
            else => try result.append(allocator, try val.clone(allocator)),
        }
    }
    return Value.listValue(result);
}

pub fn core_list(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var new_list: list.List = .empty;
    errdefer new_list.deinit(env_env.allocator);
    for (args.items) |arg| {
        try new_list.append(env_env.allocator, try arg.clone(env_env.allocator));
    }
    return Value.listValue(new_list);
}

pub fn core_vec(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(env_env.allocator);
    for (args.items) |arg| {
        switch (arg.type) {
            .list => {
                for (arg.list_val.items) |item| {
                    try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            .vector => {
                for (arg.vec_val.items) |item| {
                    try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            .range_val => {
                const rd: *Value.RangeData = arg.range_val.?;
                const len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
                var v: i64 = rd.start;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    try new_vec.append(env_env.allocator, Value.intValue(v));
                    v += rd.step;
                }
            },
            else => try new_vec.append(env_env.allocator, try arg.clone(env_env.allocator)),
        }
    }
    return Value.vectorValue(new_vec);
}

// Global counter for gensym
var gensym_counter: usize = 0;

pub fn core_gensym(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len > 1) return error.ArityError;

    gensym_counter += 1;

    if (args.items.len == 0) {
        const name = try std.fmt.allocPrint(allocator, "G__{d}", .{gensym_counter});
        return try Value.symValue(allocator, name);
    }

    // With prefix: gensym "x" => "x_N"
    const prefix = switch (args.items[0].type) {
        .string => args.items[0].str_val,
        .symbol => args.items[0].sym_val,
        else => return error.TypeError,
    };
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, gensym_counter });
    return try Value.symValue(allocator, name);
}

pub fn registerSequenceFunctions(env: *Env) anyerror!void {
    try env.put("count", Value.builtinFnValue(core_count));
    try env.put("first", Value.builtinFnValue(core_first));
    try env.put("rest", Value.builtinFnValue(core_rest));
    try env.put("nth", Value.builtinFnValue(core_nth));
    try env.put("concat", Value.builtinFnValue(core_concat));
    try env.put("list", Value.builtinFnValue(core_list));
    try env.put("vec", Value.builtinFnValue(core_vec));
    try env.put("gensym", Value.builtinFnValue(core_gensym));
    try env.put("take", Value.builtinFnValue(core_take));
}

