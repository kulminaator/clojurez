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

test "sets::set_q: set is set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.setValue(.empty) });
    var result = core_set_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "sets::set_q: list is not set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_set_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "sets::set: from list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_set(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .set);
    // Duplicates removed: {1, 2}
    try std.testing.expect(result.set_val.items.len == 2);
}

test "sets::disj: removes element" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s: Value.Set = .empty;
    _ = s.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = s.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = s.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    var sv = Value.setValue(s);
    defer sv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ sv, Value.intValue(2) });
    var result = core_disj(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .set);
    try std.testing.expect(result.set_val.items.len == 2);
}

