// Basic sequence/collection functions: count, first, rest, nth, concat, list, vec
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const Env = Value.Env;

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
    switch (args.items[0].type) {
        .list => {
            if (args.items[0].list_val.items.len == 0) return Value.nilValue();
            return try args.items[0].list_val.items[0].clone(env_env.allocator);
        },
        .vector => {
            if (args.items[0].vec_val.items.len == 0) return Value.nilValue();
            return try args.items[0].vec_val.items[0].clone(env_env.allocator);
        },
        else => return Value.nilValue(),
    }
}

pub fn core_rest(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
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

pub fn core_concat(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);

    for (args.items) |arg| {
        switch (arg.type) {
            .list => {
                for (arg.list_val.items) |item| {
                    try result.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            .vector => {
                for (arg.vec_val.items) |item| {
                    try result.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            else => try result.append(env_env.allocator, try arg.clone(env_env.allocator)),
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

pub fn registerSequenceFunctions(env: *Env) anyerror!void {
    const allocator = env.allocator;
    try env.put(allocator, "count", Value.builtinFnValue(core_count));
    try env.put(allocator, "first", Value.builtinFnValue(core_first));
    try env.put(allocator, "rest", Value.builtinFnValue(core_rest));
    try env.put(allocator, "nth", Value.builtinFnValue(core_nth));
    try env.put(allocator, "concat", Value.builtinFnValue(core_concat));
    try env.put(allocator, "list", Value.builtinFnValue(core_list));
    try env.put(allocator, "vec", Value.builtinFnValue(core_vec));
}

