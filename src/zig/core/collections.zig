// General collection operations: conj, pop, last, reverse, peek, contains?
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const Env = Value.Env;
const sequences = @import("sequences.zig");

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
    const coll = args.items[0];
    switch (coll.type) {
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
        .range_val => {
            const rd: *Value.RangeData = coll.range_val.?;
            const len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var v: i64 = rd.start + ((@as(i64, @intCast(len)) - 1) * rd.step);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_list.append(env_env.allocator, Value.intValue(v));
                v -= rd.step;
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

fn toInt(v: Value) anyerror!i64 {
    return switch (v.type) {
        .integer => v.int_val,
        .float => @as(i64, @intFromFloat(v.float_val)),
        else => return error.TypeError,
    };
}

pub fn registerCollectionFunctions(env: *Env) anyerror!void {
    try env.put("conj", Value.builtinFnValue(core_conj));
    try env.put("pop", Value.builtinFnValue(core_pop));
    try env.put("last", Value.builtinFnValue(core_last));
    try env.put("reverse", Value.builtinFnValue(core_reverse));

    try env.put("peek", Value.builtinFnValue(core_peek));
    try env.put("contains?", Value.builtinFnValue(core_contains_q));
}

