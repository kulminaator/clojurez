// Basic sequence/collection functions: count, first, rest, nth, concat, list, vec
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const Env = Value.Env;
const eval_helpers = @import("eval_helpers.zig");
const helpers = @import("helpers.zig");
const Allocator = std.mem.Allocator;

/// Force a value and append to target list.
/// If val is a lazy_seq, its forced elements are appended (flattened).
/// Otherwise, val is cloned and appended as a single element.
fn forceAndAppend(allocator: Allocator, val: Value, target: *list.List) anyerror!void {
    if (val.type == .lazy_seq) {
        var forced = try forceLazySeqHelper(allocator, val);
        defer forced.deinit(allocator);
        // Flatten: append each element of the forced list
        for (forced.list_val.items) |item| {
            try target.append(allocator, try item.clone(allocator));
        }
    } else {
        try target.append(allocator, try val.clone(allocator));
    }
}

/// Force a lazy-seq to a realized list (recursively forces nested lazy_seqs)
pub fn forceLazySeqHelper(allocator: Allocator, lazy: Value) anyerror!Value {
    if (lazy.lazy_seq_val.thunk) |thunk| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        const cloned_body = try list.clone(&thunk.body, arena_alloc);
        var thunk_env = try thunk.env.clone(arena_alloc);

        // Evaluate the thunk body (already wrapped in 'do') as a list
        const body_val = Value.listValue(cloned_body);
        const result = try eval_helpers.evalForm(allocator, body_val, &thunk_env);

        // Convert to list, recursively forcing any nested lazy_seq elements
        var final_list: list.List = .empty;
        errdefer final_list.deinit(allocator);
        switch (result.type) {
            .list => {
                for (result.list_val.items) |item| {
                    try forceAndAppend(allocator, item, &final_list);
                }
            },
            .vector => {
                for (result.vec_val.items) |item| {
                    try forceAndAppend(allocator, item, &final_list);
                }
            },
            .nil => {},
            .lazy_seq => {
                // Force the lazy_seq and append its contents
                var forced = try forceLazySeqHelper(allocator, result);
                defer forced.deinit(allocator);
                for (forced.list_val.items) |item| {
                    try final_list.append(allocator, try item.clone(allocator));
                }
            },
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
    const idx = try helpers.toInt(args.items[1]);
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
                try forceAndAppend(allocator, items[i], &result);
            }
        },
        .vector => {
            const items = coll.vec_val.items;
            const count = if (n < items.len) n else items.len;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                try forceAndAppend(allocator, items[i], &result);
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
        // Don't force lazy_seq here — keep it lazy for cons/map recursion
        // The lazy_seq will be forced when the containing list is realized
        if (val.type == .lazy_seq) {
            try result.append(allocator, val);
            // Transfer ownership: reset val so defer deinit is harmless
            val = Value.nilValue();
            continue;
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
            .lazy_seq => {
                var forced = try forceLazySeqHelper(env_env.allocator, arg);
                defer forced.deinit(env_env.allocator);
                for (forced.list_val.items) |item| {
                    try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
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

pub fn core_seq(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];

    // Handle lazy_seq: force it to a list first
    if (coll.type == .lazy_seq) {
        var forced = try forceLazySeqHelper(env_env.allocator, coll);
        defer forced.deinit(env_env.allocator);
        if (forced.list_val.items.len == 0) return Value.nilValue();
        return try forced.clone(env_env.allocator);
    }

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

// range - generate a sequence of integers (eager, iterative)
// Implemented as a built-in to avoid the lazy-seq recursion that causes
// stack overflow with large ranges (range's Clojure impl uses cons->concat
// which forces lazy-seqs, creating deep recursion).
pub fn core_range(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;

    var start: i64 = 0;
    var end: i64 = 0;
    var step: i64 = 1;

    switch (args.items.len) {
        1 => end = try helpers.toInt(args.items[0]),
        2 => {
            start = try helpers.toInt(args.items[0]);
            end = try helpers.toInt(args.items[1]);
        },
        3 => {
            start = try helpers.toInt(args.items[0]);
            end = try helpers.toInt(args.items[1]);
            step = try helpers.toInt(args.items[2]);
        },
        else => return error.ArityError,
    }

    if (step == 0) return error.ArityError;

    // Calculate the number of elements to pre-allocate
    var count: usize = 0;
    if (step > 0) {
        if (start < end) {
            count = @as(usize, @intCast(@divFloor(end - start + step - 1, step)));
        }
    } else {
        if (start > end) {
            count = @as(usize, @intCast(@divFloor(start - end - step - 1, -step)));
        }
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, count);

    var i = start;
    while ((step > 0 and i < end) or (step < 0 and i > end)) : (i += step) {
        try result.append(allocator, Value.intValue(i));
    }

    return Value.listValue(result);
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
    try env.put("seq", Value.builtinFnValue(core_seq));
    try env.put("range", Value.builtinFnValue(core_range));
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

test "sequences::count: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_count(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 3);
}

test "sequences::count: vector" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    const vv = Value.vectorValue(v);
    const args = makeArgs(&[_]Value{ vv });
    var result = core_count(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 2);
}

test "sequences::count: string (code points)" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try Value.stringValue(std.heap.page_allocator, "hello");
    defer s.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_count(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 5);
}

test "sequences::first: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(42)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(99)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_first(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 42);
}

test "sequences::first: empty list returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_first(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .nil);
}

test "sequences::rest: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(3)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_rest(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 2);
    try std.testing.expect(result.list_val.items[0].int_val == 2);
}

test "sequences::nth: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(10)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(20)) catch unreachable;
    _ = l.append(std.heap.page_allocator, Value.intValue(30)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv, Value.intValue(1) });
    var result = core_nth(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 20);
}

test "sequences::nth: out of range returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv, Value.intValue(5) });
    var result = core_nth(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .nil);
}

test "sequences::list: creates list from args" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1), Value.intValue(2), Value.intValue(3) });
    var result = core_list(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 3);
}

test "sequences::seq: non-empty list returns list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_seq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
}

test "sequences::seq: empty list returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_seq(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .nil);
}

test "sequences::concat: two lists" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l1: list.List = .empty;
    _ = l1.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    var l2: list.List = .empty;
    _ = l2.append(std.heap.page_allocator, Value.intValue(2)) catch unreachable;
    const lv1 = Value.listValue(l1);
    const lv2 = Value.listValue(l2);
    const args = makeArgs(&[_]Value{ lv1, lv2 });
    var result = core_concat(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 2);
}

test "sequences::concat: nil treated as empty" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, Value.intValue(1)) catch unreachable;
    const lv = Value.listValue(l);
    const args = makeArgs(&[_]Value{ lv, Value.nilValue() });
    var result = core_concat(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.list_val.items.len == 1);
}

