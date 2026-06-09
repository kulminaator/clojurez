// General collection operations: conj, pop, last, reverse, peek, contains?
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = Value.Env;
const sequences = @import("sequences.zig");
const helpers = @import("helpers.zig");
const test_utils = @import("test_utils.zig");

const toInt = helpers.toInt;

pub fn core_conj(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            for (coll.vec_val.items) |item| {
                try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            for (args.items[1..]) |item| {
                try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.vectorValue(new_vec);
        },
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var i: usize = args.items.len - 1;
            while (true) {
                try new_list.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
                if (i == 1) break;
                i -= 1;
            }
            for (coll.list_val.items) |item| {
                try new_list.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        .set => {
            var new_set: Value.Set = .empty;
            errdefer {
                for (new_set.items) |*item| {
                    item.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_set.items);
            }
            for (coll.set_val.items) |item| {
                try new_set.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            for (args.items[1..]) |item| {
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
        },
        .queue => {
            var new_queue: Value.Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    item.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_queue.items);
            }
            for (coll.queue_val.items) |item| {
                try new_queue.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            for (args.items[1..]) |item| {
                try new_queue.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.queueValue(new_queue);
        },
        .map => {
            var new_map: Value.Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    entry.key.deinit(env_env.allocator);
                    entry.value.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_map.items);
            }
            for (coll.map_val.items) |entry| {
                try new_map.append(env_env.allocator, .{
                    .key = try entry.key.clone(env_env.allocator),
                    .value = try entry.value.clone(env_env.allocator),
                });
            }
            for (args.items[1..]) |item| {
                var entry_items: []const Value = undefined;
                switch (item.type) {
                    .vector => entry_items = item.vec_val.items,
                    .list => entry_items = item.list_val.items,
                    else => { new_map.deinit(env_env.allocator); return error.TypeError; },
                }
                if (entry_items.len != 2) { new_map.deinit(env_env.allocator); return error.ArityError; }
                var found = false;
                var j: usize = 0;
                while (j < new_map.items.len) : (j += 1) {
                    if (new_map.items[j].key.equals(entry_items[0])) {
                        new_map.items[j].value.deinit(env_env.allocator);
                        new_map.items[j].value = try entry_items[1].clone(env_env.allocator);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try new_map.append(env_env.allocator, .{
                        .key = try entry_items[0].clone(env_env.allocator),
                        .value = try entry_items[1].clone(env_env.allocator),
                    });
                }
            }
            return Value.mapValue(new_map);
        },
        else => return error.TypeError,
    }
}

pub fn core_pop(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .vector => {
            if (coll.vec_val.items.len == 0) return Value.vectorValue(.empty);
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            const len = coll.vec_val.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_vec.append(env_env.allocator, try coll.vec_val.items[i].clone(env_env.allocator));
            }
            return Value.vectorValue(new_vec);
        },
        .list => {
            if (coll.list_val.items.len == 0) return Value.listValue(.empty);
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            const len = coll.list_val.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_list.append(env_env.allocator, try coll.list_val.items[i].clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        .queue => {
            if (coll.queue_val.items.len == 0) return Value.queueValue(.empty);
            var new_queue: Value.Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    item.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_queue.items);
            }
            var i: usize = 1;
            while (i < coll.queue_val.items.len) : (i += 1) {
                try new_queue.append(env_env.allocator, try coll.queue_val.items[i].clone(env_env.allocator));
            }
            return Value.queueValue(new_queue);
        },
        else => return error.TypeError,
    }
}

pub fn core_last(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var coll = try args.items[0].clone(allocator);
    defer coll.deinit(allocator);

    // Force lazy_seq
    if (coll.type == .lazy_seq) {
        coll = try sequences.forceLazySeqHelper(allocator, coll);
    }

    switch (coll.type) {
        .vector => {
            if (coll.vec_val.items.len == 0) return Value.nilValue();
            return try coll.vec_val.items[coll.vec_val.items.len - 1].clone(allocator);
        },
        .list => {
            if (coll.list_val.items.len == 0) return Value.nilValue();
            return try coll.list_val.items[coll.list_val.items.len - 1].clone(allocator);
        },
        else => return error.TypeError,
    }
}

pub fn core_reverse(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            var i: usize = coll.vec_val.items.len;
            while (i > 0) {
                i -= 1;
                try new_vec.append(env_env.allocator, try coll.vec_val.items[i].clone(env_env.allocator));
            }
            return Value.vectorValue(new_vec);
        },
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var i: usize = coll.list_val.items.len;
            while (i > 0) {
                i -= 1;
                try new_list.append(env_env.allocator, try coll.list_val.items[i].clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        .lazy_seq => {
            var forced = try sequences.forceLazySeqHelper(env_env.allocator, coll);
            defer forced.deinit(env_env.allocator);
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var i: usize = forced.list_val.items.len;
            while (i > 0) {
                i -= 1;
                try new_list.append(env_env.allocator, try forced.list_val.items[i].clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        else => return error.TypeError,
    }
}

pub fn core_peek(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .queue => {
            if (coll.queue_val.items.len == 0) return Value.nilValue();
            return try coll.queue_val.items[0].clone(env_env.allocator);
        },
        .vector => {
            if (coll.vec_val.items.len == 0) return Value.nilValue();
            return try coll.vec_val.items[coll.vec_val.items.len - 1].clone(env_env.allocator);
        },
        .list => {
            if (coll.list_val.items.len == 0) return Value.nilValue();
            return try coll.list_val.items[coll.list_val.items.len - 1].clone(env_env.allocator);
        },
        else => return error.TypeError,
    }
}

pub fn core_contains_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const coll = args.items[0];
    const key = args.items[1];

    switch (coll.type) {
        .map => {
            for (coll.map_val.items) |entry| {
                if (entry.key.equals(key)) return Value.boolValue(true);
            }
            return Value.boolValue(false);
        },
        .set => {
            for (coll.set_val.items) |item| {
                if (item.equals(key)) return Value.boolValue(true);
            }
            return Value.boolValue(false);
        },
        .vector, .list => {
            if (key.type != .integer) return Value.boolValue(false);
            const idx = key.int_val;
            if (idx < 0) return Value.boolValue(false);
            const len: usize = switch (coll.type) {
                .vector => coll.vec_val.items.len,
                .list => coll.list_val.items.len,
                else => unreachable,
            };
            return Value.boolValue(@as(usize, @intCast(idx)) < len);
        },
        else => return error.TypeError,
    }
}

pub fn registerCollectionFunctions(env: *Env) anyerror!void {
    try env.put("conj", Value.builtinFnValue(core_conj));
    try env.put("pop", Value.builtinFnValue(core_pop));
    try env.put("last", Value.builtinFnValue(core_last));
    try env.put("reverse", Value.builtinFnValue(core_reverse));

    try env.put("peek", Value.builtinFnValue(core_peek));
    try env.put("contains?", Value.builtinFnValue(core_contains_q));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "collections::conj: vector" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    var vv = Value.vectorValue(v);
    defer vv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv, Value.intValue(3) });
    var result = core_conj(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .vector);
    try std.testing.expect(result.vec_val.items.len == 3);
}

test "collections::conj: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    var lv = Value.listValue(l);
    defer lv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ lv, Value.intValue(3) });
    var result = core_conj(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    // conj on list adds to front: (3 1 2)
    try std.testing.expect(result.list_val.items.len == 3);
    try std.testing.expect(result.list_val.items[0].int_val == 3);
}

test "collections::pop: vector" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = v.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    var vv = Value.vectorValue(v);
    defer vv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv });
    var result = core_pop(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .vector);
    try std.testing.expect(result.vec_val.items.len == 2);
}

test "collections::last: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    var lv = Value.listValue(l);
    defer lv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_last(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 3);
}

test "collections::last: empty list returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_last(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .nil);
}

test "collections::reverse: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    var lv = Value.listValue(l);
    defer lv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_reverse(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items[0].int_val == 3);
    try std.testing.expect(result.list_val.items[2].int_val == 1);
}

test "collections::contains_q: map has key" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m: Value.Map = .empty;
    _ = m.append(std.heap.page_allocator, .{ .key = Value.intValue(1), .value = Value.intValue(10) }) catch unreachable;
    var mv = Value.mapValue(m);
    defer mv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ mv, Value.intValue(1) });
    var result = core_contains_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "collections::contains_q: map missing key" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m: Value.Map = .empty;
    _ = m.append(std.heap.page_allocator, .{ .key = Value.intValue(1), .value = Value.intValue(10) }) catch unreachable;
    var mv = Value.mapValue(m);
    defer mv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ mv, Value.intValue(99) });
    var result = core_contains_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "collections::contains_q: vector index in range" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    var vv = Value.vectorValue(v);
    defer vv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv, Value.intValue(0) });
    var result = core_contains_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "collections::contains_q: vector index out of range" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    var vv = Value.vectorValue(v);
    defer vv.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv, Value.intValue(5) });
    var result = core_contains_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

