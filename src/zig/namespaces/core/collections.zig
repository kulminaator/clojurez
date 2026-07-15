// General collection operations: conj, pop, last, reverse, peek, contains?
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;
const sequences = @import("sequences.zig");
const maps = @import("maps.zig");
const helpers = @import("helpers.zig");
const test_utils = @import("test_utils.zig");

const toInt = helpers.toInt;

pub fn core_conj(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const coll = args.items[0];
    switch (std.meta.activeTag(coll)) {
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            for (coll.vector.items.items) |item| {
                try new_vec.append(env_env.allocator, item);
            }
            for (args.items[1..]) |item| {
                try new_vec.append(env_env.allocator, item);
            }
            return try vm.vectorValue(env_env.allocator, new_vec);
        },
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var i: usize = args.items.len - 1;
            while (true) {
                try new_list.append(env_env.allocator, args.items[i]);
                if (i == 1) break;
                i -= 1;
            }
            for (coll.list.items.items) |item| {
                try new_list.append(env_env.allocator, item);
            }
            return try vm.listValue(env_env.allocator, new_list);
        },
        .set => {
            var new_set: vm.Set = .empty;
            errdefer {
                for (new_set.items) |*item| {
                    vm.valueDeinit(item, env_env.allocator);
                }
                env_env.allocator.free(new_set.items);
            }
            for (coll.set.items.items) |item| {
                try new_set.append(env_env.allocator, item);
            }
            for (args.items[1..]) |item| {
                var found = false;
                for (new_set.items) |existing| {
                    if (vm.equals(existing, item)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try new_set.append(env_env.allocator, item);
                }
            }
            return try vm.setValue(env_env.allocator, new_set);
        },
        .queue => {
            var new_queue: vm.Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    vm.valueDeinit(item, env_env.allocator);
                }
                env_env.allocator.free(new_queue.items);
            }
            for (coll.queue.items.items) |item| {
                try new_queue.append(env_env.allocator, item);
            }
            for (args.items[1..]) |item| {
                try new_queue.append(env_env.allocator, item);
            }
            return try vm.queueValue(env_env.allocator, new_queue);
        },
        .map => {
            var new_map: vm.Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    vm.valueDeinit(&entry.key, env_env.allocator);
                    vm.valueDeinit(&entry.value, env_env.allocator);
                }
                env_env.allocator.free(new_map.items);
            }
            for (coll.map.entries.items) |entry| {
                try new_map.append(env_env.allocator, .{
                    .key = entry.key,
                    .value = entry.value,
                });
            }
            for (args.items[1..]) |item| {
                var entry_items: []const Value = undefined;
                switch (std.meta.activeTag(item)) {
                    .vector => entry_items = item.vector.items.items,
                    .list => entry_items = item.list.items.items,
                    else => { new_map.deinit(env_env.allocator); return error.TypeError; },
                }
                if (entry_items.len != 2) { new_map.deinit(env_env.allocator); return error.ArityError; }
                var found = false;
                var j: usize = 0;
                while (j < new_map.items.len) : (j += 1) {
                    if (vm.equals(new_map.items[j].key, entry_items[0])) {
                        vm.valueDeinit(&new_map.items[j].value, env_env.allocator);
                        new_map.items[j].value = entry_items[1];
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try new_map.append(env_env.allocator, .{
                        .key = entry_items[0],
                        .value = entry_items[1],
                    });
                }
            }
            return try vm.mapValue(env_env.allocator, new_map);
        },
        .record => {
            // conj on record with map entries: (conj record [k v]) or (conj record {k v})
            // Each entry is a 2-element collection that becomes an assoc pair
            const allocator = env_env.allocator;
            var current = coll;
            defer vm.valueDeinit(&current, allocator);

            for (args.items[1..]) |item| {
                var entry_items: []const Value = undefined;
                switch (std.meta.activeTag(item)) {
                    .vector => entry_items = item.vector.items.items,
                    .list => entry_items = item.list.items.items,
                    else => return error.TypeError,
                }
                if (entry_items.len != 2) return error.ArityError;

                // Build args: (assoc current key value)
                const current_clone = current;
                var assoc_args: list.List = .empty;
                defer assoc_args.deinit(allocator);
                try assoc_args.append(allocator, current_clone);
                try assoc_args.append(allocator, entry_items[0]);
                try assoc_args.append(allocator, entry_items[1]);

                const new_val = try maps.core_assoc(&current_clone, &assoc_args, env_env);
                vm.valueDeinit(&current, allocator);
                current = new_val;
            }

            const result = current;
            current = vm.nilValue();
            return result;
        },
        else => return error.TypeError,
    }
}

pub fn core_pop(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (std.meta.activeTag(coll)) {
        .vector => {
            if (coll.vector.items.items.len == 0) return try vm.vectorValue(env_env.allocator, .empty);
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            const len = coll.vector.items.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_vec.append(env_env.allocator, coll.vector.items.items[i]);
            }
            return try vm.vectorValue(env_env.allocator, new_vec);
        },
        .list => {
            if (coll.list.items.items.len == 0) return try vm.listValue(env_env.allocator, .empty);
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            const len = coll.list.items.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_list.append(env_env.allocator, coll.list.items.items[i]);
            }
            return try vm.listValue(env_env.allocator, new_list);
        },
        .queue => {
            if (coll.queue.items.items.len == 0) return try vm.queueValue(env_env.allocator, .empty);
            var new_queue: vm.Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    vm.valueDeinit(item, env_env.allocator);
                }
                env_env.allocator.free(new_queue.items);
            }
            var i: usize = 1;
            while (i < coll.queue.items.items.len) : (i += 1) {
                try new_queue.append(env_env.allocator, coll.queue.items.items[i]);
            }
            return try vm.queueValue(env_env.allocator, new_queue);
        },
        else => return error.TypeError,
    }
}

pub fn core_last(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var coll = args.items[0];
    defer vm.valueDeinit(&coll, allocator);

    // Force lazy_seq
    if (std.meta.activeTag(coll) == .lazy_seq) {
        coll = try sequences.forceLazySeqHelper(allocator, coll);
    }

    switch (std.meta.activeTag(coll)) {
        .vector => {
            if (coll.vector.items.items.len == 0) return vm.nilValue();
            return coll.vector.items.items[coll.vector.items.items.len - 1];
        },
        .list => {
            if (coll.list.items.items.len == 0) return vm.nilValue();
            return coll.list.items.items[coll.list.items.items.len - 1];
        },
        .string => {
            const s = coll.string.slice();
            if (s.len == 0) return vm.nilValue();
            // Get the last UTF-8 code point
            const codepoint_count = vm.utf8CodepointCount(s);
            const last_cp_bytes = vm.utf8CodepointAt(s, codepoint_count - 1) orelse return vm.nilValue();
            const cp = std.unicode.utf8Decode(last_cp_bytes) catch return vm.nilValue();
            return vm.charValue(cp);
        },
        else => return error.TypeError,
    }
}

pub fn core_reverse(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (std.meta.activeTag(coll)) {
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            var i: usize = coll.vector.items.items.len;
            while (i > 0) {
                i -= 1;
                try new_vec.append(env_env.allocator, coll.vector.items.items[i]);
            }
            return try vm.vectorValue(env_env.allocator, new_vec);
        },
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var i: usize = coll.list.items.items.len;
            while (i > 0) {
                i -= 1;
                try new_list.append(env_env.allocator, coll.list.items.items[i]);
            }
            return try vm.listValue(env_env.allocator, new_list);
        },
        .lazy_seq => {
            var forced = try sequences.forceLazySeqHelper(env_env.allocator, coll);
            defer vm.valueDeinit(&forced, env_env.allocator);
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var i: usize = forced.list.items.items.len;
            while (i > 0) {
                i -= 1;
                try new_list.append(env_env.allocator, forced.list.items.items[i]);
            }
            return try vm.listValue(env_env.allocator, new_list);
        },
        else => return error.TypeError,
    }
}

pub fn core_peek(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (std.meta.activeTag(coll)) {
        .queue => {
            if (coll.queue.items.items.len == 0) return vm.nilValue();
            return coll.queue.items.items[0];
        },
        .vector => {
            if (coll.vector.items.items.len == 0) return vm.nilValue();
            return coll.vector.items.items[coll.vector.items.items.len - 1];
        },
        .list => {
            if (coll.list.items.items.len == 0) return vm.nilValue();
            return coll.list.items.items[coll.list.items.items.len - 1];
        },
        else => return error.TypeError,
    }
}

pub fn core_contains_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const coll = args.items[0];
    const key = args.items[1];

    switch (std.meta.activeTag(coll)) {
        .map => {
            for (coll.map.entries.items) |entry| {
                if (vm.equals(entry.key, key)) return vm.boolValue(true);
            }
            return vm.boolValue(false);
        },
        .record => {
            // Check fields first, then extmap
            for (coll.record.fields.items) |entry| {
                if (vm.equals(entry.key, key)) return vm.boolValue(true);
            }
            for (coll.record.extmap.items) |entry| {
                if (vm.equals(entry.key, key)) return vm.boolValue(true);
            }
            return vm.boolValue(false);
        },
        .set => {
            for (coll.set.items.items) |item| {
                if (vm.equals(item, key)) return vm.boolValue(true);
            }
            return vm.boolValue(false);
        },
        .vector, .list => {
            if (std.meta.activeTag(key) != .integer) return vm.boolValue(false);
            const idx = key.integer;
            if (idx < 0) return vm.boolValue(false);
            const len: usize = switch (std.meta.activeTag(coll)) {
                .vector => coll.vector.items.items.len,
                .list => coll.list.items.items.len,
                else => unreachable,
            };
            return vm.boolValue(@as(usize, @intCast(idx)) < len);
        },
        else => return error.TypeError,
    }
}

pub fn registerCollectionFunctions(env: *Env) anyerror!void {
    try env.put("conj", vm.builtinFnValue(core_conj));
    try env.put("pop", vm.builtinFnValue(core_pop));
    try env.put("last", vm.builtinFnValue(core_last));
    try env.put("reverse", vm.builtinFnValue(core_reverse));

    try env.put("peek", vm.builtinFnValue(core_peek));
    try env.put("contains?", vm.builtinFnValue(core_contains_q));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "collections::conj: vector" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    var vv = try vm.vectorValue(std.heap.page_allocator, v);
    defer vm.valueDeinit(&vv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv, vm.intValue(3) });
    var result = core_conj(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .vector);
    try std.testing.expect(result.vector.items.items.len == 3);
}

test "collections::conj: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    var lv = try vm.listValue(std.heap.page_allocator, l);
    defer vm.valueDeinit(&lv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ lv, vm.intValue(3) });
    var result = core_conj(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    // conj on list adds to front: (3 1 2)
    try std.testing.expect(result.list.items.items.len == 3);
    try std.testing.expect(result.list.items.items[0].integer == 3);
}

test "collections::pop: vector" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = v.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    var vv = try vm.vectorValue(std.heap.page_allocator, v);
    defer vm.valueDeinit(&vv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv });
    var result = core_pop(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .vector);
    try std.testing.expect(result.vector.items.items.len == 2);
}

test "collections::last: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    var lv = try vm.listValue(std.heap.page_allocator, l);
    defer vm.valueDeinit(&lv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_last(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 3);
}

test "collections::last: empty list returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ try vm.listValue(std.heap.page_allocator, list.empty()) });
    var result = core_last(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "collections::reverse: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    var lv = try vm.listValue(std.heap.page_allocator, l);
    defer vm.valueDeinit(&lv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_reverse(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items[0].integer == 3);
    try std.testing.expect(result.list.items.items[2].integer == 1);
}

test "collections::contains_q: map has key" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m: vm.Map = .empty;
    _ = m.append(std.heap.page_allocator, .{ .key = vm.intValue(1), .value = vm.intValue(10) }) catch unreachable;
    var mv = try vm.mapValue(std.heap.page_allocator, m);
    defer vm.valueDeinit(&mv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ mv, vm.intValue(1) });
    var result = core_contains_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "collections::contains_q: map missing key" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m: vm.Map = .empty;
    _ = m.append(std.heap.page_allocator, .{ .key = vm.intValue(1), .value = vm.intValue(10) }) catch unreachable;
    var mv = try vm.mapValue(std.heap.page_allocator, m);
    defer vm.valueDeinit(&mv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ mv, vm.intValue(99) });
    var result = core_contains_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "collections::contains_q: vector index in range" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    var vv = try vm.vectorValue(std.heap.page_allocator, v);
    defer vm.valueDeinit(&vv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv, vm.intValue(0) });
    var result = core_contains_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "collections::contains_q: vector index out of range" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    var vv = try vm.vectorValue(std.heap.page_allocator, v);
    defer vm.valueDeinit(&vv, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vv, vm.intValue(5) });
    var result = core_contains_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

