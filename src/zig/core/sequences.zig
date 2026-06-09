// Basic sequence/collection functions: count, first, rest, nth, concat, list, vec
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const Env = Value.Env;
const eval_helpers = @import("eval_helpers.zig");
const helpers = @import("helpers.zig");
const test_utils = @import("test_utils.zig");
const Allocator = std.mem.Allocator;

/// Force a value and append to target list.
/// If val is a lazy_seq, append it as-is (don't force recursively).
/// Otherwise, clone and append as a single element.
fn forceAndAppend(allocator: Allocator, val: Value, target: *list.List) anyerror!void {
    // Don't recursively force nested lazy-seqs - keep them lazy
    // They will be forced on demand by first/rest/seq
    try target.append(allocator, try val.clone(allocator));
}

/// Force a lazy-seq to a realized list (recursively forces nested lazy_seqs)
pub fn forceLazySeqHelper(allocator: Allocator, lazy: Value) anyerror!Value {
    if (lazy.lazy_seq_val.thunk) |thunk| {
        const cloned_body = try list.clone(&thunk.body, allocator);
        var thunk_env = try thunk.env.clone(allocator);

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
                // Force the lazy_seq and flatten its contents.
                // This is safe now because seq no longer forces lazy-seqs,
                // breaking the recursion chain.
                var forced_inner = try forceLazySeqHelper(allocator, result);
                defer forced_inner.deinit(allocator);
                for (forced_inner.list_val.items) |item| {
                    try forceAndAppend(allocator, item, &final_list);
                }
            },
            .cons => {
                // Walk the cons chain and flatten into the list
                try flattenConsToList(allocator, result, &final_list);
            },
            else => {
                try final_list.append(allocator, result);
            },
        }
        return Value.listValue(final_list);
    }
    return Value.listValue(list.empty());
}

/// Flatten a cons chain into a list, forcing nested lazy_seqs.
fn flattenConsToList(allocator: Allocator, val: Value, target: *list.List) anyerror!void {
    var current = val;
    errdefer current.deinit(allocator);

    while (true) {
        switch (current.type) {
            .cons => {
                const cdata = current.cons_val.?;
                // Append the head as a single element.
                // If head is a lazy_seq, force it but keep it as one element.
                if (cdata.head.type == .lazy_seq) {
                    const head_forced = try forceLazySeqHelper(allocator, cdata.head);
                    try target.append(allocator, head_forced);
                } else {
                    try target.append(allocator, try cdata.head.clone(allocator));
                }
                // Move to tail
                const tail = try cdata.tail.clone(allocator);
                current.deinit(cdata.allocator);
                current = tail;
            },
            .list => {
                // Splice in the list elements
                for (current.list_val.items) |item| {
                    try forceAndAppend(allocator, item, target);
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                // Force the lazy_seq and flatten its contents
                var forced = try forceLazySeqHelper(allocator, current);
                defer forced.deinit(allocator);
                for (forced.list_val.items) |item| {
                    try target.append(allocator, try item.clone(allocator));
                }
                break;
            },
            else => {
                // Dotted pair — append as-is
                try target.append(allocator, current);
                current = Value.nilValue();
                break;
            },
        }
    }
    current.deinit(allocator);
}

pub fn core_count(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var val = args.items[0];
    // Force lazy_seq to count its elements
    if (val.type == .lazy_seq) {
        var forced = try forceLazySeqHelper(allocator, val);
        defer forced.deinit(allocator);
        val = forced;
    }
    switch (val.type) {
        .list => return Value.intValue(@as(i64, @intCast(val.list_val.items.len))),
        .vector => return Value.intValue(@as(i64, @intCast(val.vec_val.items.len))),
        .map => return Value.intValue(@as(i64, @intCast(args.items[0].map_val.items.len))),
        .set => return Value.intValue(@as(i64, @intCast(args.items[0].set_val.items.len))),
        .queue => return Value.intValue(@as(i64, @intCast(args.items[0].queue_val.items.len))),
        .string => return Value.intValue(@as(i64, @intCast(Value.utf8CodepointCount(args.items[0].str_val)))),
        .cons => {
            // Count = 1 + count of tail (recursively)
            return countConsSeq(allocator, val);
        },
        else => return error.TypeError,
    }
}

/// Recursively count elements in a cons chain.
fn countConsSeq(allocator: Allocator, val: Value) anyerror!Value {
    var count: i64 = 0;
    var current = val;
    errdefer current.deinit(allocator);

    while (true) {
        switch (current.type) {
            .cons => {
                count += 1;
                const cdata = current.cons_val.?;
                const tail = try cdata.tail.clone(allocator);
                current.deinit(cdata.allocator);
                current = tail;
            },
            .list => {
                count += @as(i64, @intCast(current.list_val.items.len));
                break;
            },
            .nil => break,
            .lazy_seq => {
                // Force the lazy-seq and count its elements
                var forced = try forceLazySeqHelper(allocator, current);
                defer forced.deinit(allocator);
                count += @as(i64, @intCast(forced.list_val.items.len));
                break;
            },
            else => {
                // Dotted pair — count just the cons chain
                break;
            },
        }
    }
    current.deinit(allocator);
    return Value.intValue(count);
}

pub fn core_first(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var val = try args.items[0].clone(allocator);
    defer val.deinit(allocator);
    // Handle lazy_seq: evaluate thunk, get result
    if (val.type == .lazy_seq) {
        val = try forceLazySeqGetResult(allocator, &val);
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
        .cons => {
            // Cons cell: first is the head directly
            const cdata = val.cons_val.?;
            return try cdata.head.clone(allocator);
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
    // Handle lazy_seq: evaluate thunk, get result
    if (val.type == .lazy_seq) {
        val = try forceLazySeqGetResult(allocator, &val);
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
        .cons => {
            // Cons cell: rest is the tail directly.
            // If tail is nil, return empty list (matching Clojure's more() behavior).
            const cdata = val.cons_val.?;
            if (cdata.tail.type == .nil) {
                return Value.listValue(list.empty());
            }
            return try cdata.tail.clone(allocator);
        },
        else => return Value.listValue(list.empty()),
    }
}

/// Force a lazy-seq and return the first element.
/// Caches the result so subsequent forces return the cached value.
/// Force a lazy-seq by evaluating its thunk once.
/// Returns the direct result (cons, list, vector, nil, or lazy_seq).
fn forceLazySeqGetResult(allocator: Allocator, lazy: *const Value) anyerror!Value {
    if (lazy.lazy_seq_val.thunk) |thunk| {
        const cloned_body = try list.clone(&thunk.body, allocator);
        var thunk_env = try thunk.env.clone(allocator);

        // Evaluate the thunk body (already wrapped in 'do') as a list
        const body_val = Value.listValue(cloned_body);
        return try eval_helpers.evalForm(allocator, body_val, &thunk_env);
    }
    return Value.listValue(list.empty());
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
    _ = switch (n_val.type) {
        .integer, .float => {},
        else => return error.TypeError,
    };

    // Return a lazy-seq that yields at most n elements
    // Mirrors Clojure: (lazy-seq (when (pos? n) (when-let [s (seq coll)] (cons (first s) (take (dec n) (rest s))))))
    const thunk = try allocator.create(Value.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = try env_env.clone(allocator),
    };
    try thunk.env.put("n", try n_val.clone(allocator));
    try thunk.env.put("coll", try args.items[1].clone(allocator));

    // Build thunk body matching JVM clojure:
    // (lazy-seq (when (pos? n) (when-let [s (seq coll)] (cons (first s) (take (dec n) (rest s))))))
    // Equivalent to:
    // (if (pos? n)
    //   (let [s (seq coll)]
    //     (if s
    //       (cons (first s) (take (dec n) (rest s)))
    //       nil))
    //   nil)
    // CRITICAL: (pos? n) must be checked BEFORE (seq coll) to avoid
    // forcing the lazy-seq when n <= 0.
    const a = allocator;
    const sym_let = try Value.symValue(a, "let");
    const sym_s = try Value.symValue(a, "s");
    const sym_seq = try Value.symValue(a, "seq");
    const sym_coll = try Value.symValue(a, "coll");
    const sym_if = try Value.symValue(a, "if");
    const sym_pos_q = try Value.symValue(a, "pos?");
    const sym_n = try Value.symValue(a, "n");
    const sym_cons = try Value.symValue(a, "cons");
    const sym_first = try Value.symValue(a, "first");
    const sym_take = try Value.symValue(a, "take");
    const sym_dec = try Value.symValue(a, "dec");
    const sym_rest = try Value.symValue(a, "rest");
    const sym_nil = Value.nilValue();

    // (seq coll)
    var seq_call: list.List = .empty;
    try seq_call.append(a, sym_seq);
    try seq_call.append(a, sym_coll);

    // [s (seq coll)]
    var bindings: list.List = .empty;
    try bindings.append(a, sym_s);
    try bindings.append(a, Value.listValue(seq_call));

    // (pos? n)
    var pos_call: list.List = .empty;
    try pos_call.append(a, sym_pos_q);
    try pos_call.append(a, sym_n);

    // (first s)
    var first_call: list.List = .empty;
    try first_call.append(a, sym_first);
    try first_call.append(a, sym_s);

    // (rest s)
    var rest_call: list.List = .empty;
    try rest_call.append(a, sym_rest);
    try rest_call.append(a, sym_s);

    // (dec n)
    var dec_call: list.List = .empty;
    try dec_call.append(a, sym_dec);
    try dec_call.append(a, sym_n);

    // (take (dec n) (rest s))
    var take_call: list.List = .empty;
    try take_call.append(a, sym_take);
    try take_call.append(a, Value.listValue(dec_call));
    try take_call.append(a, Value.listValue(rest_call));

    // (cons (first s) (take (dec n) (rest s)))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, Value.listValue(first_call));
    try cons_call.append(a, Value.listValue(take_call));

    // (if s (cons ...) nil) — inner check, only reached when (pos? n) is true
    var inner_if: list.List = .empty;
    try inner_if.append(a, sym_if);
    try inner_if.append(a, sym_s);
    try inner_if.append(a, Value.listValue(cons_call));
    try inner_if.append(a, sym_nil);

    // (let [s (seq coll)] (if s (cons ...) nil))
    var let_form: list.List = .empty;
    try let_form.append(a, sym_let);
    try let_form.append(a, Value.listValue(bindings));
    try let_form.append(a, Value.listValue(inner_if));

    // (if (pos? n) (let ...) nil) — outer check, prevents (seq coll) when n <= 0
    var body: list.List = .empty;
    try body.append(a, sym_if);
    try body.append(a, Value.listValue(pos_call));
    try body.append(a, Value.listValue(let_form));
    try body.append(a, sym_nil);

    thunk.body = body;
    return Value.lazySeqValue(thunk);
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
    const allocator = env_env.allocator;

    // Handle lazy_seq: force it to check if it's empty
    // This is needed for map/filter/etc. to properly detect end of sequence
    if (args.items[0].type == .lazy_seq) {
        var val = try forceLazySeqGetResult(allocator, &args.items[0]);
        // After forcing, handle the result type
        switch (val.type) {
            .cons => return val, // cons is non-empty seq
            .nil => return Value.nilValue(),
            .list => {
                if (val.list_val.items.len == 0) {
                    val.deinit(allocator);
                    return Value.nilValue();
                }
                return val;
            },
            .vector => {
                if (val.vec_val.items.len == 0) {
                    val.deinit(allocator);
                    return Value.nilValue();
                }
                return val;
            },
            .lazy_seq => return val, // nested lazy_seq, return as-is
            else => {
                val.deinit(allocator);
                return Value.nilValue();
            },
        }
    }

    const coll = args.items[0];

    // Handle cons: it's already a seq, return it directly
    if (coll.type == .cons) {
        return try coll.clone(allocator);
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
    return try coll.clone(allocator);
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

// cons - returns a lazy-seq where x is the first element and xs is the rest.
// This is a built-in because the Clojure (concat (list x) xs) version
// creates a concrete list (x <lazy-seq>) which breaks rest/seq semantics.
// In Clojure, (rest (cons x lazy-seq)) returns the lazy-seq directly.
pub fn core_cons(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const x = args.items[0];
    const xs = args.items[1];

    // Return a cons cell: (x . xs)
    // This mirrors Clojure's Cons — head is x, tail is xs (any sequence).
    // first returns x directly, rest returns xs directly (no forcing).
    return Value.consValue(allocator, try x.clone(allocator), try xs.clone(allocator));
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
    try env.put("cons", Value.builtinFnValue(core_cons));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

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

