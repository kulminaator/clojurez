// Set built-in functions: set, set?, disj
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const Env = Value.Env;

pub fn core_set(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    if (coll.type == .set) return try coll.clone(env_env.allocator);

    var new_set: Value.Set = .empty;
    errdefer {
        for (new_set.items) |*item| {
            item.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_set.items);
    }

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var found = false;
        for (new_set.items) |existing| {
            if (existing.equals(item)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try new_set.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.setValue(new_set);
}

pub fn core_set_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .set);
}

pub fn core_disj(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const set_val = args.items[0];
    if (set_val.type != .set) return error.TypeError;

    var new_set: Value.Set = .empty;
    errdefer {
        for (new_set.items) |*item| {
            item.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_set.items);
    }

    for (set_val.set_val.items) |item| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (item.equals(args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_set.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.setValue(new_set);
}

pub fn registerSetFunctions(env: *Env) anyerror!void {
    try env.put("set", Value.builtinFnValue(core_set));
    try env.put("set?", Value.builtinFnValue(core_set_q));
    try env.put("disj", Value.builtinFnValue(core_disj));
}

