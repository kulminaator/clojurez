// Basic sequence/collection functions: count, first, rest, nth, concat, list, vec
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;
const phm = @import("../../persistent_hash_map.zig");
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
        // Use custom handler if available (bypasses Clojure evaluator)
        var result: Value = undefined;
        if (thunk.custom_handler) |handler| {
            result = try forceLazySeqCustomHandler(allocator, handler, @constCast(&thunk.env), thunk);
        } else {
            const cloned_body = try list.clone(&thunk.body, allocator);
            var thunk_env = try thunk.env.clone(allocator);
            const body_val = vm.listValue(cloned_body);
            const result_ptr = try eval_helpers.evalForm(allocator, &body_val, &thunk_env);
            result = result_ptr.*;
            allocator.destroy(result_ptr);
        }

        // Convert to list, recursively forcing any nested lazy_seq elements
        var final_list: list.List = .empty;
        errdefer final_list.deinit(allocator);
        switch (std.meta.activeTag(result)) {
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
                var forced_inner = try forceLazySeqHelper(allocator, result);
                defer forced_inner.deinit(allocator);
                for (forced_inner.list_val.items) |item| {
                    try forceAndAppend(allocator, item, &final_list);
                }
            },
            .cons => {
                try flattenConsToList(allocator, result, &final_list);
            },
            else => {
                try final_list.append(allocator, result);
            },
        }
        return vm.listValue(final_list);
    }
    return vm.listValue(list.empty());
}

/// Flatten a cons chain into a list, forcing nested lazy_seqs.
/// Fully iterative — evaluates lazy_seq thunks inline to avoid stack overflow.
fn flattenConsToList(allocator: Allocator, val: Value, target: *list.List) anyerror!void {
    var current = val;
    errdefer current.deinit(allocator);

    while (true) {
        switch (std.meta.activeTag(current)) {
            .cons => {
                const cdata = current.cons_val.?;
                // Append the head
                if (std.meta.activeTag(cdata.head) == .lazy_seq) {
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
                for (current.list_val.items) |item| {
                    try forceAndAppend(allocator, item, target);
                }
                break;
            },
            .nil => break,
            .lazy_seq => {
                // Evaluate the thunk inline — if it returns a cons, continue the loop.
                // This avoids recursion that would blow the stack on long cons chains.
                const next = try evalLazySeqThunk(allocator, current);
                current.deinit(allocator);
                current = next;
                // Loop continues with the new value (cons, list, nil, or lazy_seq)
            },
            else => {
                try target.append(allocator, current);
                current = vm.nilValue();
                break;
            },
        }
    }
    current.deinit(allocator);
}

/// Evaluate a lazy-seq thunk and return the result value.
/// Uses custom handler if available, otherwise evaluates through the Clojure evaluator.
fn evalLazySeqThunk(allocator: Allocator, lazy: Value) anyerror!Value {
    if (lazy.lazy_seq_val.thunk) |thunk| {
        var result: Value = undefined;
        if (thunk.custom_handler) |handler| {
            result = try forceLazySeqCustomHandler(allocator, handler, @constCast(&thunk.env), thunk);
        } else {
            const cloned_body = try list.clone(&thunk.body, allocator);
            var thunk_env = try thunk.env.clone(allocator);
            const body_val = vm.listValue(cloned_body);
            const result_ptr = try eval_helpers.evalForm(allocator, &body_val, &thunk_env);
            result = result_ptr.*;
            allocator.destroy(result_ptr);
        }

        // If the thunk returned a lazy_seq, force it (rare)
        if (std.meta.activeTag(result) == .lazy_seq) {
            const forced = try forceLazySeqHelper(allocator, result);
            return forced;
        }
        return result;
    }
    return vm.nilValue();
}

pub fn core_count(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var val = args.items[0];
    // Force lazy_seq to count its elements
    if (std.meta.activeTag(val) == .lazy_seq) {
        var forced = try forceLazySeqHelper(allocator, val);
        defer forced.deinit(allocator);
        val = forced;
    }
    switch (std.meta.activeTag(val)) {
        .list => return vm.intValue(@as(i64, @intCast(val.list_val.items.len))),
        .vector => return vm.intValue(@as(i64, @intCast(val.vec_val.items.len))),
        .map => return vm.intValue(@as(i64, @intCast(args.items[0].map_val.items.len))),
        .record => {
            const rd = args.items[0].record_val orelse return error.TypeError;
            const total: i64 = @as(i64, @intCast(rd.fields.items.len)) + @as(i64, @intCast(rd.extmap.items.len));
            return vm.intValue(total);
        },
        .set => return vm.intValue(@as(i64, @intCast(args.items[0].set_val.items.len))),
        .queue => return vm.intValue(@as(i64, @intCast(args.items[0].queue_val.items.len))),
        .string => return vm.intValue(@as(i64, @intCast(Value.utf8CodepointCount(args.items[0].str_val)))),
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
        switch (std.meta.activeTag(current)) {
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
    return vm.intValue(count);
}

pub fn core_first(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var val = try args.items[0].clone(allocator);
    defer val.deinit(allocator);
    // Handle lazy_seq: evaluate thunk, get result
    if (std.meta.activeTag(val) == .lazy_seq) {
        val = try forceLazySeqGetResult(allocator, &val);
    }
    switch (std.meta.activeTag(val)) {
        .list => {
            if (val.list_val.items.len == 0) return vm.nilValue();
            return try val.list_val.items[0].clone(allocator);
        },
        .vector => {
            if (val.vec_val.items.len == 0) return vm.nilValue();
            return try val.vec_val.items[0].clone(allocator);
        },
        .cons => {
            // Cons cell: first is the head directly
            const cdata = val.cons_val.?;
            return try cdata.head.clone(allocator);
        },
        .string => {
            const s = val.str_val;
            if (s.len == 0) return vm.nilValue();
            // Get the first UTF-8 code point as a char
            const cp_bytes = Value.utf8CodepointAt(s, 0) orelse return vm.nilValue();
            const cp = std.unicode.utf8Decode(cp_bytes) catch return vm.nilValue();
            return vm.charValue(cp);
        },
        else => return vm.nilValue(),
    }
}

pub fn core_rest(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    var val = try args.items[0].clone(allocator);
    defer val.deinit(allocator);
    // Handle lazy_seq: evaluate thunk, get result
    if (std.meta.activeTag(val) == .lazy_seq) {
        val = try forceLazySeqGetResult(allocator, &val);
    }
    switch (std.meta.activeTag(val)) {
        .list => {
            if (val.list_val.items.len <= 1) return vm.listValue(list.empty());
            const rest = val.list_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            for (rest) |item| {
                try new_list.append(allocator, try item.clone(allocator));
            }
            return vm.listValue(new_list);
        },
        .vector => {
            if (val.vec_val.items.len <= 1) return vm.listValue(list.empty());
            const rest = val.vec_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            for (rest) |item| {
                try new_list.append(allocator, try item.clone(allocator));
            }
            return vm.listValue(new_list);
        },
        .cons => {
            // Cons cell: rest is the tail directly.
            // If tail is nil, return empty list (matching Clojure's more() behavior).
            const cdata = val.cons_val.?;
            if (std.meta.activeTag(cdata.tail) == .nil) {
                return vm.listValue(list.empty());
            }
            return try cdata.tail.clone(allocator);
        },
        .string => {
            const s = val.str_val;
            const codepoint_count = Value.utf8CodepointCount(s);
            if (codepoint_count <= 1) return vm.listValue(list.empty());
            // Convert remaining code points (from index 1) to a list of char values
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var idx: usize = 1;
            while (idx < codepoint_count) : (idx += 1) {
                const cp_bytes = Value.utf8CodepointAt(s, idx) orelse break;
                const cp = std.unicode.utf8Decode(cp_bytes) catch break;
                try result.append(allocator, vm.charValue(cp));
            }
            return vm.listValue(result);
        },
        else => return vm.listValue(list.empty()),
    }
}

/// Force a lazy-seq and return the first element.
/// Caches the result so subsequent forces return the cached value.
/// Force a lazy-seq by evaluating its thunk once.
/// Returns the direct result (cons, list, vector, nil, or lazy_seq).
fn forceLazySeqGetResult(allocator: Allocator, lazy: *const Value) anyerror!Value {
    if (lazy.lazy_seq_val.thunk) |thunk| {
        // Check for custom handler (bypasses Clojure evaluator)
        if (thunk.custom_handler) |handler| {
            return forceLazySeqCustomHandler(allocator, handler, @constCast(&thunk.env), thunk);
        }

        const cloned_body = try list.clone(&thunk.body, allocator);
        var thunk_env = try thunk.env.clone(allocator);

        // Evaluate the thunk body (already wrapped in 'do') as a list
        const body_val = vm.listValue(cloned_body);
        const result_ptr = try eval_helpers.evalForm(allocator, &body_val, &thunk_env);
        const result = result_ptr.*;
        allocator.destroy(result_ptr);
        return result;
    }
    return vm.listValue(list.empty());
}

/// Handle lazy-seq forcing for custom handlers (map, filter, etc.)
/// These bypass the Clojure evaluator for per-element processing.
fn forceLazySeqCustomHandler(allocator: Allocator, handler: Value.LazySeqHandler, env: *Env, thunk: *const vm.LazySeqThunk) anyerror!Value {
    return switch (handler) {
        .map => forceMapStep(allocator, env, thunk),
    };
}

/// Execute one step of (map f coll) directly in Zig.
/// Returns a cons cell: (cons (f first) (map f rest))
/// or nil if the collection is empty.
///
/// Two paths:
/// - Concrete collections (list/vector): index-based iteration, no cloning.
///   Uses shared_coll pointer — collection is never cloned.
/// - Lazy collections (lazy_seq/cons): step-by-step, keeping the tail lazy.
fn forceMapStep(allocator: Allocator, env: *Env, thunk: *const vm.LazySeqThunk) anyerror!Value {
    const f = env.get("f") orelse return error.RuntimeError;

    // Get collection: from shared_coll pointer if available, else from env
    var coll_ptr: *const Value = undefined;
    if (thunk.shared_coll) |sc| {
        coll_ptr = @ptrCast(@alignCast(sc));
    } else {
        // Root thunk: coll is stored in env
        const coll_ref = env.getPtr("coll") orelse return error.RuntimeError;
        coll_ptr = coll_ref;
    }

    // Check if we have an index (concrete collection path)
    if (env.get("idx")) |idx_val| {
        return forceMapStepConcrete(allocator, f, coll_ptr, env, @as(usize, @intCast(idx_val.int_val)));
    }

    // Lazy collection path — step by step, keeping tail lazy
    return forceMapStepLazy(allocator, f, coll_ptr.*, env);
}

/// Index-based iteration for concrete collections (list/vector).
/// No cloning — just advance an integer index.
/// Uses shared_coll pointer so the collection is never cloned.
fn forceMapStepConcrete(allocator: Allocator, f: Value, coll: *const Value, env: *Env, idx: usize) anyerror!Value {
    const items = switch (coll.*.type) {
        .list => coll.*.list_val.items,
        .vector => coll.*.vec_val.items,
        else => return vm.nilValue(),
    };

    if (idx >= items.len) return vm.nilValue();

    // Apply f to current element
    var arg_list: list.List = .empty;
    defer arg_list.deinit(allocator);
    try arg_list.append(allocator, try items[idx].clone(allocator));
    const mapped_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env);
    const mapped = mapped_ptr.*;
    allocator.destroy(mapped_ptr);

    // Create next thunk — share the collection pointer, no clone!
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = null,
            .ns_manager = null,
            .referred_names = .empty,
        },
        .custom_handler = Value.LazySeqHandler.map,
        .shared_coll = coll, // shared pointer, no clone (*const Value → *const anyopaque)
    };
    try thunk.env.put("f", try f.clone(allocator));
    try thunk.env.put("idx", vm.intValue(@as(i64, @intCast(idx + 1))));

    const tail = vm.lazySeqValue(thunk);
    return vm.consValue(allocator, mapped, tail);
}

/// Step-by-step iteration for lazy collections.
/// Forces one step, keeps the tail lazy.
fn forceMapStepLazy(allocator: Allocator, f: Value, coll: Value, env: *Env) anyerror!Value {
    // Get seq of coll — forces one step for lazy_seq
    var s = try getSeqValue(allocator, coll);
    // Check if collection is empty
    if (std.meta.activeTag(s) == .nil) {
        s.deinit(allocator);
        return vm.nilValue();
    }
    if (std.meta.activeTag(s) == .list and s.list_val.items.len == 0) {
        s.deinit(allocator);
        return vm.nilValue();
    }
    if (std.meta.activeTag(s) == .vector and s.vec_val.items.len == 0) {
        s.deinit(allocator);
        return vm.nilValue();
    }

    // Get first element (does not consume s)
    var first_val = try getFirstValue(allocator, s);
    defer first_val.deinit(allocator);

    // Apply f to first
    var arg_list: list.List = .empty;
    defer arg_list.deinit(allocator);
    try arg_list.append(allocator, try first_val.clone(allocator));
    const mapped_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env);
    const mapped = mapped_ptr.*;
    allocator.destroy(mapped_ptr);

    // Get rest — this consumes s
    const rest_val = try getRestValue(allocator, s);

    // Create next thunk with the remaining lazy tail
    const thunk = try allocator.create(vm.LazySeqThunk);
    thunk.* = .{
        .params = list.empty(),
        .body = list.empty(),
        .env = .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = null,
            .ns_manager = null,
            .referred_names = .empty,
        },
        .custom_handler = Value.LazySeqHandler.map,
    };
    try thunk.env.put("f", try f.clone(allocator));
    try thunk.env.put("coll", rest_val);

    const tail = vm.lazySeqValue(thunk);
    return vm.consValue(allocator, mapped, tail);
}

/// Get seq of a value (handles lazy_seq forcing, passes through others).
/// Returns a value allocated from `allocator`.
fn getSeqValue(allocator: Allocator, val: Value) anyerror!Value {
    if (std.meta.activeTag(val) == .lazy_seq) {
        var v = try val.clone(allocator);
        var result = try forceLazySeqGetResult(allocator, &v);
        v.deinit(allocator);
        // Clone result to our allocator (forceLazySeqGetResult may use different allocator)
        const cloned = try result.clone(allocator);
        result.deinit(allocator);
        return cloned;
    }
    return try val.clone(allocator);
}

/// Get the first element of a seq value. Does not consume the value.
fn getFirstValue(allocator: Allocator, val: Value) anyerror!Value {
    switch (std.meta.activeTag(val)) {
        .cons => {
            const cdata = val.cons_val.?;
            return try cdata.head.clone(allocator);
        },
        .list => {
            if (val.list_val.items.len == 0) return vm.nilValue();
            return try val.list_val.items[0].clone(allocator);
        },
        .vector => {
            if (val.vec_val.items.len == 0) return vm.nilValue();
            return try val.vec_val.items[0].clone(allocator);
        },
        else => return vm.nilValue(),
    }
}

/// Get the rest of a seq value. Consumes the input value.
fn getRestValue(allocator: Allocator, val: Value) anyerror!Value {
    var v = val;
    switch (std.meta.activeTag(v)) {
        .cons => {
            const cdata = v.cons_val.?;
            const tail = try cdata.tail.clone(allocator);
            v.deinit(allocator);
            return tail;
        },
        .list => {
            if (v.list_val.items.len <= 1) {
                v.deinit(allocator);
                return vm.nilValue();
            }
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var i: usize = 1;
            while (i < v.list_val.items.len) : (i += 1) {
                try result.append(allocator, try v.list_val.items[i].clone(allocator));
            }
            v.deinit(allocator);
            return vm.listValue(result);
        },
        .vector => {
            if (v.vec_val.items.len <= 1) {
                v.deinit(allocator);
                return vm.nilValue();
            }
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var i: usize = 1;
            while (i < v.vec_val.items.len) : (i += 1) {
                try result.append(allocator, try v.vec_val.items[i].clone(allocator));
            }
            v.deinit(allocator);
            return vm.listValue(result);
        },
        else => {
            v.deinit(allocator);
            return vm.nilValue();
        },
    }
}

pub fn core_nth(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const allocator = env_env.allocator;
    const idx = try helpers.toInt(args.items[1]);
    const not_found: ?Value = if (args.items.len >= 3) args.items[2] else null;

    switch (std.meta.activeTag(args.items[0])) {
        .list => {
            if (idx < 0 or @as(usize, @intCast(idx)) >= args.items[0].list_val.items.len) {
                if (not_found) |nf| return try nf.clone(allocator);
                return vm.nilValue();
            }
            return try args.items[0].list_val.items[@as(usize, @intCast(idx))].clone(allocator);
        },
        .vector => {
            if (idx < 0 or @as(usize, @intCast(idx)) >= args.items[0].vec_val.items.len) {
                if (not_found) |nf| return try nf.clone(allocator);
                return vm.nilValue();
            }
            return try args.items[0].vec_val.items[@as(usize, @intCast(idx))].clone(allocator);
        },
        .string => {
            const s = args.items[0].str_val;
            const codepoint_count = Value.utf8CodepointCount(s);
            if (idx < 0 or @as(usize, @intCast(idx)) >= codepoint_count) {
                if (not_found) |nf| return try nf.clone(allocator);
                return vm.nilValue();
            }
            const cp_bytes = Value.utf8CodepointAt(s, @as(usize, @intCast(idx))) orelse {
                if (not_found) |nf| return try nf.clone(allocator);
                return vm.nilValue();
            };
            const cp = std.unicode.utf8Decode(cp_bytes) catch {
                if (not_found) |nf| return try nf.clone(allocator);
                return vm.nilValue();
            };
            return vm.charValue(cp);
        },
        .lazy_seq, .cons => {
            // Iterate lazily — don't force the entire sequence
            return nthOnSeq(allocator, args.items[0], idx, not_found);
        },
        else => return error.TypeError,
    }
}

/// Iterate through a sequence (lazy_seq or cons) to find the nth element.
/// Only realizes elements up to the requested index.
fn nthOnSeq(allocator: Allocator, val: Value, idx: i64, not_found: ?Value) anyerror!Value {
    if (idx < 0) {
        if (not_found) |nf| return try nf.clone(allocator);
        return vm.nilValue();
    }

    var current = try val.clone(allocator);
    errdefer current.deinit(allocator);

    var i: i64 = 0;
    while (i <= idx) {
        // Get seq of current (handles lazy_seq forcing, cons pass-through, etc.)
        const seqed = try getSeq(allocator, &current);
        if (std.meta.activeTag(seqed) == .nil) {
            // Sequence ended before reaching index
            if (not_found) |nf| return try nf.clone(allocator);
            return vm.nilValue();
        }
        if (i == idx) {
            // Got the element at idx
            const first = try getFirst(allocator, seqed);
            return first;
        }
        // Move to rest
        const rest = try getRest(allocator, seqed);
        current.deinit(allocator);
        current = rest;
        i += 1;
    }
    // Should not reach here
    if (not_found) |nf| return try nf.clone(allocator);
    return vm.nilValue();
}

/// Get the seq of a value (forces lazy_seq, passes through cons/list/vector).
fn getSeq(allocator: Allocator, val: *Value) anyerror!Value {
    if (std.meta.activeTag(val) == .lazy_seq) {
        return try forceLazySeqGetResult(allocator, val);
    }
    return try val.clone(allocator);
}

/// Get the first element of a seq value. Consumes the seq value.
fn getFirst(allocator: Allocator, val: Value) anyerror!Value {
    var v = val;
    switch (std.meta.activeTag(v)) {
        .cons => {
            const cdata = v.cons_val.?;
            const head = try cdata.head.clone(allocator);
            v.deinit(allocator);
            return head;
        },
        .list => {
            if (v.list_val.items.len == 0) {
                v.deinit(allocator);
                return vm.nilValue();
            }
            const first = try v.list_val.items[0].clone(allocator);
            v.deinit(allocator);
            return first;
        },
        .vector => {
            if (v.vec_val.items.len == 0) {
                v.deinit(allocator);
                return vm.nilValue();
            }
            const first = try v.vec_val.items[0].clone(allocator);
            v.deinit(allocator);
            return first;
        },
        else => {
            v.deinit(allocator);
            return vm.nilValue();
        },
    }
}

/// Get the rest of a seq value. Consumes the seq value.
fn getRest(allocator: Allocator, val: Value) anyerror!Value {
    var v = val;
    switch (std.meta.activeTag(v)) {
        .cons => {
            const cdata = v.cons_val.?;
            const tail = try cdata.tail.clone(allocator);
            v.deinit(allocator);
            return tail;
        },
        .list => {
            if (v.list_val.items.len <= 1) {
                v.deinit(allocator);
                return vm.nilValue();
            }
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var i: usize = 1;
            while (i < v.list_val.items.len) : (i += 1) {
                try result.append(allocator, try v.list_val.items[i].clone(allocator));
            }
            v.deinit(allocator);
            return vm.listValue(result);
        },
        .vector => {
            if (v.vec_val.items.len <= 1) {
                v.deinit(allocator);
                return vm.nilValue();
            }
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var i: usize = 1;
            while (i < v.vec_val.items.len) : (i += 1) {
                try result.append(allocator, try v.vec_val.items[i].clone(allocator));
            }
            v.deinit(allocator);
            return vm.listValue(result);
        },
        else => {
            v.deinit(allocator);
            return vm.nilValue();
        },
    }
}

/// subvec - returns a persistent vector of the items in vector from
/// start (inclusive) to end (exclusive). If end is not supplied,
/// defaults to (count vector).
pub fn core_subvec(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    const allocator = env_env.allocator;
    if (std.meta.activeTag(args.items[0]) != .vector) return error.TypeError;
    const v = args.items[0].vec_val;
    const start = try helpers.toInt(args.items[1]);
    var end: i64 = @as(i64, @intCast(v.items.len));
    if (args.items.len == 3) {
        end = try helpers.toInt(args.items[2]);
    }
    if (start < 0 or start > @as(i64, @intCast(v.items.len))) return error.IndexOutOfBounds;
    if (end < start or end > @as(i64, @intCast(v.items.len))) return error.IndexOutOfBounds;

    var result: vec.Vector = .empty;
    errdefer result.deinit(allocator);
    var i: usize = @as(usize, @intCast(start));
    while (i < @as(usize, @intCast(end))) : (i += 1) {
        try result.append(allocator, try v.items[i].clone(allocator));
    }
    return vm.vectorValue(result);
}

pub fn core_take(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const n_val = args.items[0];
    _ = switch (std.meta.activeTag(n_val)) {
        .integer, .float => {},
        else => return error.TypeError,
    };

    // Return a lazy-seq that yields at most n elements
    // Mirrors Clojure: (lazy-seq (when (pos? n) (when-let [s (seq coll)] (cons (first s) (take (dec n) (rest s))))))
    const thunk = try allocator.create(vm.LazySeqThunk);
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
    const sym_let = try vm.symValue(a, "let");
    const sym_s = try vm.symValue(a, "s");
    const sym_seq = try vm.symValue(a, "seq");
    const sym_coll = try vm.symValue(a, "coll");
    const sym_if = try vm.symValue(a, "if");
    const sym_pos_q = try vm.symValue(a, "pos?");
    const sym_n = try vm.symValue(a, "n");
    const sym_cons = try vm.symValue(a, "cons");
    const sym_first = try vm.symValue(a, "first");
    const sym_take = try vm.symValue(a, "take");
    const sym_dec = try vm.symValue(a, "dec");
    const sym_rest = try vm.symValue(a, "rest");
    const sym_nil = vm.nilValue();

    // (seq coll)
    var seq_call: list.List = .empty;
    try seq_call.append(a, sym_seq);
    try seq_call.append(a, sym_coll);

    // [s (seq coll)]
    var bindings: list.List = .empty;
    try bindings.append(a, sym_s);
    try bindings.append(a, vm.listValue(seq_call));

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
    try take_call.append(a, vm.listValue(dec_call));
    try take_call.append(a, vm.listValue(rest_call));

    // (cons (first s) (take (dec n) (rest s)))
    var cons_call: list.List = .empty;
    try cons_call.append(a, sym_cons);
    try cons_call.append(a, vm.listValue(first_call));
    try cons_call.append(a, vm.listValue(take_call));

    // (if s (cons ...) nil) — inner check, only reached when (pos? n) is true
    var inner_if: list.List = .empty;
    try inner_if.append(a, sym_if);
    try inner_if.append(a, sym_s);
    try inner_if.append(a, vm.listValue(cons_call));
    try inner_if.append(a, sym_nil);

    // (let [s (seq coll)] (if s (cons ...) nil))
    var let_form: list.List = .empty;
    try let_form.append(a, sym_let);
    try let_form.append(a, vm.listValue(bindings));
    try let_form.append(a, vm.listValue(inner_if));

    // (if (pos? n) (let ...) nil) — outer check, prevents (seq coll) when n <= 0
    var body: list.List = .empty;
    try body.append(a, sym_if);
    try body.append(a, vm.listValue(pos_call));
    try body.append(a, vm.listValue(let_form));
    try body.append(a, sym_nil);

    thunk.body = body;
    return vm.lazySeqValue(thunk);
}

pub fn core_concat(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    for (args.items) |arg| {
        // nil is treated as empty sequence in concat
        if (std.meta.activeTag(arg) == .nil) continue;
        var val = try arg.clone(allocator);
        defer val.deinit(allocator);
        // Don't force lazy_seq here — keep it lazy for cons/map recursion
        // The lazy_seq will be forced when the containing list is realized
        if (std.meta.activeTag(val) == .lazy_seq) {
            try result.append(allocator, val);
            // Transfer ownership: reset val so defer deinit is harmless
            val = vm.nilValue();
            continue;
        }
        switch (std.meta.activeTag(val)) {
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
    return vm.listValue(result);
}

pub fn core_list(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var new_list: list.List = .empty;
    errdefer new_list.deinit(env_env.allocator);
    for (args.items) |arg| {
        try new_list.append(env_env.allocator, try arg.clone(env_env.allocator));
    }
    return vm.listValue(new_list);
}

pub fn core_vec(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(env_env.allocator);
    for (args.items) |arg| {
        switch (std.meta.activeTag(arg)) {
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
    return vm.vectorValue(new_vec);
}

// Global counter for gensym
var gensym_counter: usize = 0;

pub fn core_gensym(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len > 1) return error.ArityError;

    gensym_counter += 1;

    if (args.items.len == 0) {
        const name = try std.fmt.allocPrint(allocator, "G__{d}", .{gensym_counter});
        return try vm.symValue(allocator, name);
    }

    // With prefix: gensym "x" => "x_N"
    const prefix = switch (std.meta.activeTag(args.items[0])) {
        .string => args.items[0].str_val,
        .symbol => args.items[0].sym_val,
        else => return error.TypeError,
    };
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, gensym_counter });
    return try vm.symValue(allocator, name);
}

pub fn core_seq(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;

    // Handle lazy_seq: force it to check if it's empty
    // This is needed for map/filter/etc. to properly detect end of sequence
    if (std.meta.activeTag(args.items[0]) == .lazy_seq) {
        var val = try forceLazySeqGetResult(allocator, &args.items[0]);
        // Keep forcing nested lazy_seqs until we get a concrete result
        while (std.meta.activeTag(val) == .lazy_seq) {
            var nested = val;
            val = try forceLazySeqGetResult(allocator, &nested);
            nested.deinit(allocator);
        }
        // After forcing, handle the result type
        switch (std.meta.activeTag(val)) {
            .cons => return val, // cons is non-empty seq
            .nil => return vm.nilValue(),
            .list => {
                if (val.list_val.items.len == 0) {
                    val.deinit(allocator);
                    return vm.nilValue();
                }
                return val;
            },
            .vector => {
                if (val.vec_val.items.len == 0) {
                    val.deinit(allocator);
                    return vm.nilValue();
                }
                return val;
            },
            else => {
                val.deinit(allocator);
                return vm.nilValue();
            },
        }
    }

    const coll = args.items[0];

    // Handle cons: it's already a seq, return it directly
    if (std.meta.activeTag(coll) == .cons) {
        return try coll.clone(allocator);
    }

    const len: usize = switch (std.meta.activeTag(coll)) {
        .list => coll.list_val.items.len,
        .vector => coll.vec_val.items.len,
        .map => coll.map_val.items.len,
        .record => coll.record_val.?.fields.items.len + coll.record_val.?.extmap.items.len,
        .set => coll.set_val.items.len,
        .queue => coll.queue_val.items.len,
        .string => {
            // For strings, seq returns the string itself (iterable via first/rest/nth)
            // But only if non-empty
            if (coll.str_val.len == 0) return vm.nilValue();
            return try coll.clone(allocator);
        },
        else => return vm.nilValue(),
    };
    if (len == 0) return vm.nilValue();

    // For records, seq returns a list of [key value] pairs
    if (std.meta.activeTag(coll) == .record) {
        return seqRecord(coll, allocator);
    }

    return try coll.clone(allocator);
}

// range - generate a sequence of integers (eager, iterative)
// Implemented as a built-in to avoid the lazy-seq recursion that causes
// stack overflow with large ranges (range's Clojure impl uses cons->concat
// which forces lazy-seqs, creating deep recursion).
pub fn core_range(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
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
        try result.append(allocator, vm.intValue(i));
    }

    return vm.listValue(result);
}

// cons - returns a lazy-seq where x is the first element and xs is the rest.
// This is a built-in because the Clojure (concat (list x) xs) version
// creates a concrete list (x <lazy-seq>) which breaks rest/seq semantics.
// In Clojure, (rest (cons x lazy-seq)) returns the lazy-seq directly.
pub fn core_cons(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const x = args.items[0];
    const xs = args.items[1];

    // Return a cons cell: (x . xs)
    // This mirrors Clojure's Cons — head is x, tail is xs (any sequence).
    // first returns x directly, rest returns xs directly (no forcing).
    return vm.consValue(allocator, try x.clone(allocator), try xs.clone(allocator));
}

/// Build seq for a record: list of [key value] pairs from fields + extmap.
fn seqRecord(record: Value, allocator: Allocator) anyerror!Value {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    // Add field pairs in declaration order
    for (record.record_val.?.fields.items) |entry| {
        var pair: vec.Vector = .empty;
        try pair.append(allocator, try entry.key.clone(allocator));
        try pair.append(allocator, try entry.value.clone(allocator));
        try result.append(allocator, vm.vectorValue(pair));
    }

    // Add extmap pairs
    for (record.record_val.?.extmap.items) |entry| {
        var pair: vec.Vector = .empty;
        try pair.append(allocator, try entry.key.clone(allocator));
        try pair.append(allocator, try entry.value.clone(allocator));
        try result.append(allocator, vm.vectorValue(pair));
    }

    return vm.listValue(result);
}

pub fn registerSequenceFunctions(env: *Env) anyerror!void {
    try env.put("count", vm.builtinFnValue(core_count));
    try env.put("first", vm.builtinFnValue(core_first));
    try env.put("rest", vm.builtinFnValue(core_rest));
    try env.put("nth", vm.builtinFnValue(core_nth));
    try env.put("concat", vm.builtinFnValue(core_concat));
    try env.put("list", vm.builtinFnValue(core_list));
    try env.put("vec", vm.builtinFnValue(core_vec));
    try env.put("gensym", vm.builtinFnValue(core_gensym));
    try env.put("take", vm.builtinFnValue(core_take));
    try env.put("seq", vm.builtinFnValue(core_seq));
    try env.put("range", vm.builtinFnValue(core_range));
    try env.put("cons", vm.builtinFnValue(core_cons));
    try env.put("subvec", vm.builtinFnValue(core_subvec));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "sequences::count: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    const lv = vm.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_count(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 3);
}

test "sequences::count: vector" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var v: vec.Vector = .empty;
    _ = v.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = v.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    const vv = vm.vectorValue(v);
    const args = makeArgs(&[_]Value{ vv });
    var result = core_count(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 2);
}

test "sequences::count: string (code points)" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer s.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_count(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 5);
}

test "sequences::first: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(42)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(99)) catch unreachable;
    const lv = vm.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_first(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 42);
}

test "sequences::first: empty list returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.listValue(list.empty()) });
    var result = core_first(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "sequences::rest: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(3)) catch unreachable;
    const lv = vm.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_rest(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list_val.items.len == 2);
    try std.testing.expect(result.list_val.items[0].int_val == 2);
}

test "sequences::nth: list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(10)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(20)) catch unreachable;
    _ = l.append(std.heap.page_allocator, vm.intValue(30)) catch unreachable;
    const lv = vm.listValue(l);
    const args = makeArgs(&[_]Value{ lv, vm.intValue(1) });
    var result = core_nth(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 20);
}

test "sequences::nth: out of range returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = vm.listValue(l);
    const args = makeArgs(&[_]Value{ lv, vm.intValue(5) });
    var result = core_nth(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "sequences::list: creates list from args" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1), vm.intValue(2), vm.intValue(3) });
    var result = core_list(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list_val.items.len == 3);
}

test "sequences::seq: non-empty list returns list" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = vm.listValue(l);
    const args = makeArgs(&[_]Value{ lv });
    var result = core_seq(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
}

test "sequences::seq: empty list returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.listValue(list.empty()) });
    var result = core_seq(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "sequences::concat: two lists" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l1: list.List = .empty;
    _ = l1.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    var l2: list.List = .empty;
    _ = l2.append(std.heap.page_allocator, vm.intValue(2)) catch unreachable;
    const lv1 = vm.listValue(l1);
    const lv2 = vm.listValue(l2);
    const args = makeArgs(&[_]Value{ lv1, lv2 });
    var result = core_concat(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list_val.items.len == 2);
}

test "sequences::concat: nil treated as empty" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var l: list.List = .empty;
    _ = l.append(std.heap.page_allocator, vm.intValue(1)) catch unreachable;
    const lv = vm.listValue(l);
    const args = makeArgs(&[_]Value{ lv, vm.nilValue() });
    var result = core_concat(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.list_val.items.len == 1);
}

