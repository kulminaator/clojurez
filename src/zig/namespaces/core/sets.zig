// Set built-in functions: set, set?, disj
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const test_utils = @import("test_utils.zig");

pub fn core_set(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    if (std.meta.activeTag(coll) == .set) return try vm.shallowClone(&coll, env_env.allocator);

    var new_set: vm.Set = .empty;
    errdefer {
        for (new_set.items) |*item| {
            vm.valueDeinit(item, env_env.allocator);
        }
        env_env.allocator.free(new_set.items);
    }

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var found = false;
        for (new_set.items) |existing| {
            if (vm.equals(existing, item)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try new_set.append(env_env.allocator, try vm.shallowClone(&item, env_env.allocator));
        }
    }
    return try vm.setValue(env_env.allocator, new_set);
}

pub fn core_set_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .set);
}

pub fn core_disj(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const set_val = args.items[0];
    if (std.meta.activeTag(set_val) != .set) return error.TypeError;

    var new_set: vm.Set = .empty;
    errdefer {
        for (new_set.items) |*item| {
            vm.valueDeinit(item, env_env.allocator);
        }
        env_env.allocator.free(new_set.items);
    }

    for (set_val.set.items.items) |item| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (vm.equals(item, args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_set.append(env_env.allocator, try vm.shallowClone(&item, env_env.allocator));
        }
    }
    return try vm.setValue(env_env.allocator, new_set);
}

pub fn registerSetFunctions(env: *Env) anyerror!void {
    try env.put("set", vm.builtinFnValue(core_set));
    try env.put("set?", vm.builtinFnValue(core_set_q));
    try env.put("disj", vm.builtinFnValue(core_disj));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "sets::set_q: set is set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ try vm.setValue(std.heap.page_allocator, .empty) });
    var result = core_set_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "sets::set_q: list is not set" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ try vm.listValue(std.heap.page_allocator, list.empty()) });
    var result = core_set_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "sets::set: from list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = try vm.listValue(std.heap.page_allocator, l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_set(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .set);
    // Duplicates removed: {1, 2}
    try std.testing.expect(result.set.items.items.len == 2);
}

test "sets::disj: removes element" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s: vm.Set = .empty;
    _ = s.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = s.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = s.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    var sv = try vm.setValue(std.heap.page_allocator, s);
    defer vm.valueDeinit(&sv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ sv, vm.intValue(2) });
    var result = core_disj(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .set);
    try std.testing.expect(result.set.items.items.len == 2);
}

