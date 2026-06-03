const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = Value.Env;
const parser = @import("parser.zig");
const eval_helpers = @import("core/eval_helpers.zig");

const Allocator = std.mem.Allocator;

pub const EvalError = error{
    UndefinedSymbol,
    NotCallable,
    TypeError,
    ArityError,
    RecursionLimit,
    ReplExit,
};

const MAX_RECURSION = 1000;

pub fn eval(allocator: Allocator, form: Value, env: *Env) anyerror!Value {
    return evalRec(allocator, form, env, 0);
}

// Force a lazy_map into a concrete list (for printing/display)
pub fn forceLazyMap(allocator: Allocator, lazy: Value, env: *Env) anyerror!Value {
    const lm: *Value.LazyMapData = lazy.lazy_map_val.?;
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    // Handle range_val as inner collection
    if (lm.coll.type == .range_val) {
        const rd: *Value.RangeData = lm.coll.range_val.?;
        const coll_len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
        var v: i64 = rd.start + (@as(i64, @intCast(lm.idx)) * rd.step);
        var idx: usize = lm.idx;
        while (idx < coll_len) : (idx += 1) {
            var arg_list: list.List = .empty;
            errdefer arg_list.deinit(allocator);
            try arg_list.append(allocator, Value.intValue(v));
            const mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env);
            try result.append(allocator, mapped);
            v += rd.step;
        }
        return Value.listValue(result);
    }

    // Handle list/vector
    var coll_items: []const Value = undefined;
    const coll_len: usize = switch (lm.coll.type) {
        .list => lm.coll.list_val.items.len,
        .vector => lm.coll.vec_val.items.len,
        else => return Value.listValue(list.empty()),
    };
    switch (lm.coll.type) {
        .list => coll_items = lm.coll.list_val.items,
        .vector => coll_items = lm.coll.vec_val.items,
        else => return Value.listValue(list.empty()),
    }
    var i: usize = lm.idx;
    while (i < coll_len) : (i += 1) {
        var arg_list: list.List = .empty;
        errdefer arg_list.deinit(allocator);
        try arg_list.append(allocator, try coll_items[i].clone(allocator));
        const mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env);
        try result.append(allocator, mapped);
    }
    return Value.listValue(result);
}

fn evalRec(allocator: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    if (depth > MAX_RECURSION) return error.RecursionLimit;

    switch (form.type) {
        .nil, .bool, .integer, .float, .string, .keyword, .set, .queue, .atom, .lazy_map, .range_val => {
            return try form.clone(allocator);
        },
        .symbol => {
            if (std.mem.eql(u8, form.sym_val, "quote") or
                std.mem.eql(u8, form.sym_val, "quasiquote") or
                std.mem.eql(u8, form.sym_val, "unquote") or
                std.mem.eql(u8, form.sym_val, "unquote-splicing"))
            {
                return try form.clone(allocator);
            }
            const val = env.get(form.sym_val);
            if (val) |v| return try v.clone(allocator);
            return error.UndefinedSymbol;
        },
        .list => {
            return try evalList(allocator, form.list_val, env, depth);
        },
        .vector => {
            // Vectors evaluate element-wise
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            for (form.vec_val.items) |item| {
                try new_vec.append(allocator, try evalRec(allocator, item, env, depth + 1));
            }
            return Value.vectorValue(new_vec);
        },
        .map => {
            // Maps evaluate key-value pairs element-wise
            var new_map: Value.Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(new_map.items);
            }
            for (form.map_val.items) |entry| {
                try new_map.append(allocator, .{
                    .key = try evalRec(allocator, entry.key, env, depth + 1),
                    .value = try evalRec(allocator, entry.value, env, depth + 1),
                });
            }
            return Value.mapValue(new_map);
        },
        .function, .builtin_fn => return try form.clone(allocator),
        .lazy_seq => return try form.clone(allocator),
    }
    unreachable;
}

// Result of parsing a parameter list (may include variadic rest parameter)
const ParsedParams = struct {
    params: list.List,      // regular parameters (without & symbol)
    rest_name: ?[]const u8, // name of rest parameter, or null
};

// Parse a parameter list, extracting regular params and optional rest param.
// E.g., [a b & rest] => { params: (a b), rest_name: "rest" }
// E.g., [& args]     => { params: (), rest_name: "args" }
// E.g., [a b]        => { params: (a b), rest_name: null }
fn parseParams(allocator: Allocator, params: list.List) anyerror!ParsedParams {
    var regular_params: list.List = .empty;
    errdefer regular_params.deinit(allocator);
    var rest_name: ?[]const u8 = null;

    var i: usize = 0;
    var found_amp = false;
    while (i < params.items.len) : (i += 1) {
        const item = params.items[i];
        if (!found_amp and item.type == .symbol and std.mem.eql(u8, item.sym_val, "&")) {
            found_amp = true;
            continue;
        }
        if (found_amp) {
            // The symbol after & is the rest parameter name
            if (item.type != .symbol) return error.TypeError;
            rest_name = try allocator.dupe(u8, item.sym_val);
            // No more params expected after rest
            break;
        } else {
            try regular_params.append(allocator, try item.clone(allocator));
        }
    }

    return ParsedParams{
        .params = regular_params,
        .rest_name = rest_name,
    };
}

fn evalList(allocator: Allocator, l: list.List, env: *Env, depth: usize) anyerror!Value {
    if (l.items.len == 0) return Value.listValue(list.empty());

    const first = l.items[0];

    // Self-evaluating symbols (special forms)
    if (first.type == .symbol) {
        const name = first.sym_val;

        // Special forms that don't evaluate their arguments
        // quit / exit - signal REPL to exit
        if (std.mem.eql(u8, name, "quit") or std.mem.eql(u8, name, "exit")) {
            return error.ReplExit;
        }

        // ns - namespace declaration (no-op for our simple VM)
        if (std.mem.eql(u8, name, "ns")) {
            return Value.nilValue();
        }

        if (std.mem.eql(u8, name, "quote")) {
            if (l.items.len != 2) return error.ArityError;
            return try l.items[1].clone(allocator);
        }

        if (std.mem.eql(u8, name, "quasiquote")) {
            if (l.items.len != 2) return error.ArityError;
            return try unquoteProcess(allocator, l.items[1], env, depth + 1);
        }

        // def - define a global variable
        if (std.mem.eql(u8, name, "def")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            const docstring = if (l.items.len == 3 and l.items[2].type == .string)
                l.items[2]
            else null;
            const eval_idx: usize = if (l.items.len == 3 and l.items[2].type != .string) 2 else 1;
            const val = try evalRec(allocator, l.items[eval_idx], env, depth + 1);
            try env.put(allocator, sym.sym_val, val);
            if (docstring) |ds| {
                _ = try ds.clone(allocator); // keep docstring alive (simplified)
            }
            return try sym.clone(allocator);
        }

        // let - local bindings
        if (std.mem.eql(u8, name, "let")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLet(allocator, bindings, l.items[2..], env, depth + 1);
        }

        // if - conditional
        if (std.mem.eql(u8, name, "if")) {
            if (l.items.len < 2 or l.items.len > 4) return error.ArityError;
            const cond = try evalRec(allocator, l.items[1], env, depth + 1);
            if (cond.isTruthy()) {
                if (l.items.len >= 3) return try evalRec(allocator, l.items[2], env, depth + 1);
                return Value.nilValue();
            } else {
                if (l.items.len >= 4) return try evalRec(allocator, l.items[3], env, depth + 1);
                return Value.nilValue();
            }
        }

        // when - (when test body...)
        if (std.mem.eql(u8, name, "when")) {
            if (l.items.len < 2) return error.ArityError;
            const cond = try evalRec(allocator, l.items[1], env, depth + 1);
            if (cond.isTruthy()) {
                return try evalDo(allocator, l.items[2..], env, depth + 1);
            }
            return Value.nilValue();
        }

        // cond - multi-way conditional
        if (std.mem.eql(u8, name, "cond")) {
            return try evalCond(allocator, l.items[1..], env, depth + 1);
        }

        // defn - define a named function
        if (std.mem.eql(u8, name, "defn")) {
            if (l.items.len < 3) return error.ArityError;
            const fname = l.items[1];
            if (fname.type != .symbol) return error.TypeError;
            // Handle optional docstring
            const has_docstring = l.items.len >= 3 and l.items[2].type == .string;
            const params_idx: usize = if (has_docstring) 3 else 2;
            if (params_idx >= l.items.len) return error.ArityError;
            const params = l.items[params_idx];
            if (params.type != .list and params.type != .vector) return error.TypeError;
            const params_list = if (params.type == .vector) try listFromVector(allocator, params.vec_val) else params.list_val;
            const body = if (l.items.len >= params_idx + 1) l.items[params_idx + 1..] else &[_]Value{};

            var body_list: list.List = .empty;
            errdefer body_list.deinit(allocator);
            try body_list.append(allocator, try Value.symValue(allocator, "do"));
            for (body) |form_item| {
                try body_list.append(allocator, try form_item.clone(allocator));
            }

            // Parse params for variadic support (& rest)
            var parsed = try parseParams(allocator, params_list);
            defer {
                parsed.params.deinit(allocator);
                if (parsed.rest_name) |rn| allocator.free(rn);
            }

            const cloned_params = try parsed.params.clone(allocator);
            const cloned_body = try body_list.clone(allocator);
            const cloned_rest = if (parsed.rest_name) |rn| try allocator.dupe(u8, rn) else null;
            // Create fn_env with parent = env so it can see all global symbols
            // including the function itself (for recursion)
            const fn_env: Env = .{
                .allocator = allocator,
                .entries = .empty,
                .parent = env,
            };
            const fn_val = Value.fnValue(cloned_params, cloned_body, fn_env, cloned_rest, false);
            try env.put(allocator, fname.sym_val, fn_val);
            return try fname.clone(allocator);
        }

        // fn - define a function
        if (std.mem.eql(u8, name, "fn")) {
            if (l.items.len < 2) return error.ArityError;
            const params = l.items[1];
            if (params.type != .list and params.type != .vector) return error.TypeError;
            const params_list = if (params.type == .vector) try listFromVector(allocator, params.vec_val) else params.list_val;
            const body = if (l.items.len >= 3) l.items[2..] else &[_]Value{};

            // Wrap body in a do block
            var body_list: list.List = .empty;
            errdefer body_list.deinit(allocator);
            try body_list.append(allocator, try Value.symValue(allocator, "do"));
            for (body) |form_item| {
                try body_list.append(allocator, try form_item.clone(allocator));
            }

            // Parse params for variadic support (& rest)
            var parsed = try parseParams(allocator, params_list);
            defer {
                parsed.params.deinit(allocator);
                if (parsed.rest_name) |rn| allocator.free(rn);
            }

            const cloned_params = try parsed.params.clone(allocator);
            const cloned_body = try body_list.clone(allocator);
            const cloned_rest = if (parsed.rest_name) |rn| try allocator.dupe(u8, rn) else null;
            const fn_env = try env.clone(allocator);
            return Value.fnValue(cloned_params, cloned_body, fn_env, cloned_rest, false);
        }

        // defmacro - define a macro (like defn but args are passed unevaluated)
        if (std.mem.eql(u8, name, "defmacro")) {
            if (l.items.len < 3) return error.ArityError;
            const macro_name = l.items[1];
            if (macro_name.type != .symbol) return error.TypeError;
            // Handle optional docstring
            const has_docstring = l.items.len >= 3 and l.items[2].type == .string;
            const params_idx: usize = if (has_docstring) 3 else 2;
            if (params_idx >= l.items.len) return error.ArityError;
            const params = l.items[params_idx];
            if (params.type != .list and params.type != .vector) return error.TypeError;
            const params_list = if (params.type == .vector) try listFromVector(allocator, params.vec_val) else params.list_val;
            const body = if (l.items.len >= params_idx + 1) l.items[params_idx + 1..] else &[_]Value{};

            // Wrap body in a do block
            var body_list: list.List = .empty;
            errdefer body_list.deinit(allocator);
            try body_list.append(allocator, try Value.symValue(allocator, "do"));
            for (body) |form_item| {
                try body_list.append(allocator, try form_item.clone(allocator));
            }

            // Parse params for variadic support (& rest)
            var parsed = try parseParams(allocator, params_list);
            defer {
                parsed.params.deinit(allocator);
                if (parsed.rest_name) |rn| allocator.free(rn);
            }

            const cloned_params = try parsed.params.clone(allocator);
            const cloned_body = try body_list.clone(allocator);
            const cloned_rest = if (parsed.rest_name) |rn| try allocator.dupe(u8, rn) else null;
            const fn_env: Env = .{
                .allocator = allocator,
                .entries = .empty,
                .parent = env,
            };
            const macro_fn = Value.fnValue(cloned_params, cloned_body, fn_env, cloned_rest, true);
            try env.put(allocator, macro_name.sym_val, macro_fn);
            return try macro_name.clone(allocator);
        }

        // do - evaluate a sequence of forms
        if (std.mem.eql(u8, name, "do")) {
            return try evalDo(allocator, l.items[1..], env, depth + 1);
        }

        // set! - modify a var
        if (std.mem.eql(u8, name, "set!")) {
            if (l.items.len != 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            const val = try evalRec(allocator, l.items[2], env, depth + 1);
            try env.put(allocator, sym.sym_val, val);
            return val;
        }

        // recur - tail recursion
        if (std.mem.eql(u8, name, "recur")) {
            if (l.items.len < 2) return error.ArityError;
            // Simplified: just evaluate and return the last arg
            // Full recur would need to jump back to the loop/fn bindings
            var results: list.List = .empty;
            errdefer results.deinit(allocator);
            for (l.items[1..]) |arg| {
                try results.append(allocator, try evalRec(allocator, arg, env, depth + 1));
            }
            if (results.items.len == 1) return results.items[0];
            return Value.listValue(results);
        }

        // loop - named recursion point
        if (std.mem.eql(u8, name, "loop")) {
            if (l.items.len < 2) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
            return try evalLoop(allocator, bindings, l.items[2..], env, depth + 1);
        }

        // var - create a mutable var
        if (std.mem.eql(u8, name, "var")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const sym = l.items[1];
            if (sym.type != .symbol) return error.TypeError;
            const val = if (l.items.len >= 3)
                try evalRec(allocator, l.items[2], env, depth + 1)
            else
                Value.nilValue();
            try env.put(allocator, sym.sym_val, val);
            return try sym.clone(allocator);
        }

        // deref (deref) - get the value of a var
        if (std.mem.eql(u8, name, "deref") or std.mem.eql(u8, name, "@")) {
            if (l.items.len != 2) return error.ArityError;
            const arg = try evalRec(allocator, l.items[1], env, depth + 1);
            return arg;
        }

        // or - short-circuit or
        if (std.mem.eql(u8, name, "or")) {
            for (l.items[1..]) |form_item| {
                const val = try evalRec(allocator, form_item, env, depth + 1);
                if (val.isTruthy()) return val;
            }
            return Value.nilValue();
        }

        // and - short-circuit and
        if (std.mem.eql(u8, name, "and")) {
            for (l.items[1..]) |form_item| {
                const val = try evalRec(allocator, form_item, env, depth + 1);
                if (!val.isTruthy()) return val;
            }
            return Value.boolValue(true);
        }

        // binding - for let bindings (simplified)
        if (std.mem.eql(u8, name, "binding")) {
            if (l.items.len < 3) return error.ArityError;
            const bindings = l.items[1];
            if (bindings.type != .list) return error.TypeError;
            var new_env = try env.clone(allocator);
            defer new_env.deinit(allocator);

            var i: usize = 0;
            while (i < bindings.list_val.items.len) : (i += 2) {
                const sym = bindings.list_val.items[i];
                if (sym.type != .symbol) return error.TypeError;
                const val = try evalRec(allocator, bindings.list_val.items[i + 1], env, depth + 1);
                try new_env.put(allocator, sym.sym_val, val);
            }
            return try evalDo(allocator, l.items[2..], &new_env, depth + 1);
        }

        // ->> thread-last macro
        // (->> x (f 1) (g 2 3)) => (g (f x 1) 2 3)
        if (std.mem.eql(u8, name, "->>")) {
            return try evalThreadLast(allocator, l.items[1..], env, depth + 1);
        }

        // -> thread-first macro
        // (-> x (f 1) (g 2 3)) => (g (f 1 x) 2 3)
        if (std.mem.eql(u8, name, "->")) {
            return evalThreadFirst(allocator, l.items[1..], env, depth + 1);
        }

        // lazy-seq - create a lazy sequence
        if (std.mem.eql(u8, name, "lazy-seq")) {
            if (l.items.len < 2) return error.ArityError;
            // Build the thunk body as a list of forms to evaluate
            var body: list.List = .empty;
            errdefer body.deinit(allocator);
            try body.append(allocator, try Value.symValue(allocator, "do"));
            for (l.items[1..]) |form| {
                try body.append(allocator, try form.clone(allocator));
            }
            const thunk = try allocator.create(Value.LazySeqThunk);
            thunk.* = .{
                .params = list.empty(),
                .body = body,
                .env = try env.clone(allocator),
            };
            return Value.lazySeqValue(thunk);
        }

        // dorun - realize a lazy sequence for side effects, return nil
        // (dorun coll) or (dorun n coll)
        if (std.mem.eql(u8, name, "dorun")) {
            if (l.items.len < 2 or l.items.len > 3) return error.ArityError;
            const dorun_args = l.items[1..];
            var n: ?usize = null;
            var coll_form: Value = undefined;
            if (dorun_args.len == 2) {
                var n_val = try evalRec(allocator, dorun_args[0], env, depth + 1);
                defer n_val.deinit(allocator);
                const n_int: i64 = switch (n_val.type) {
                    .integer => n_val.int_val,
                    .float => @as(i64, @intFromFloat(n_val.float_val)),
                    else => return error.TypeError,
                };
                n = @as(usize, @intCast(n_int));
                coll_form = dorun_args[1];
            } else {
                coll_form = dorun_args[0];
            }
            var coll = try evalRec(allocator, coll_form, env, depth + 1);
            defer coll.deinit(allocator);

            // Handle lazy_map: iterate element-by-element without materializing full result
            if (coll.type == .lazy_map) {
                var lm: *Value.LazyMapData = coll.lazy_map_val.?;
                var count: usize = 0;

                // Handle range_val as inner collection
                if (lm.coll.type == .range_val) {
                    const rd: *Value.RangeData = lm.coll.range_val.?;
                    const coll_len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
                    var v: i64 = rd.start + (@as(i64, @intCast(lm.idx)) * rd.step);
                    var idx: usize = lm.idx;
                    while (idx < coll_len) {
                        if (n) |limit| { if (count >= limit) break; }
                        var arg_list: list.List = .empty;
                        errdefer arg_list.deinit(allocator);
                        try arg_list.append(allocator, Value.intValue(v));
                        var mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env);
                        if (mapped.type == .lazy_seq) {
                            const forced = try forceLazySeq(allocator, mapped, env, depth + 1);
                            mapped.deinit(allocator);
                            mapped = forced;
                        }
                        mapped.deinit(allocator);
                        v += rd.step;
                        idx += 1;
                        count += 1;
                    }
                    lm.idx = idx;
                    return Value.nilValue();
                }

                // Handle list/vector as inner collection
                var coll_items: []const Value = undefined;
                const coll_len: usize = switch (lm.coll.type) {
                    .list => lm.coll.list_val.items.len,
                    .vector => lm.coll.vec_val.items.len,
                    else => return Value.nilValue(),
                };
                switch (lm.coll.type) {
                    .list => coll_items = lm.coll.list_val.items,
                    .vector => coll_items = lm.coll.vec_val.items,
                    else => return Value.nilValue(),
                }
                while (lm.idx < coll_len) {
                    if (n) |limit| { if (count >= limit) break; }
                    var arg_list: list.List = .empty;
                    errdefer arg_list.deinit(allocator);
                    try arg_list.append(allocator, try coll_items[lm.idx].clone(allocator));
                    var mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env);
                    if (mapped.type == .lazy_seq) {
                        const forced = try forceLazySeq(allocator, mapped, env, depth + 1);
                        mapped.deinit(allocator);
                        mapped = forced;
                    }
                    mapped.deinit(allocator);
                    lm.idx += 1;
                    count += 1;
                }
                return Value.nilValue();
            }

            // Handle range_val: iterate without materializing
            if (coll.type == .range_val) {
                const rd: *Value.RangeData = coll.range_val.?;
                const len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
                var count: usize = 0;
                var v: i64 = rd.start;
                var idx: usize = 0;
                while (idx < len) : (idx += 1) {
                    if (n) |limit| { if (count >= limit) break; }
                    v += rd.step;
                    count += 1;
                }
                return Value.nilValue();
            }

            // Force lazy_seq if needed
            if (coll.type == .lazy_seq) {
                const forced = try forceLazySeq(allocator, coll, env, depth + 1);
                coll.deinit(allocator);
                coll = forced;
            }
            // Iterate through the collection (realizing it), optionally up to n elements
            var items: []const Value = undefined;
            switch (coll.type) {
                .list => items = coll.list_val.items,
                .vector => items = coll.vec_val.items,
                .set => items = coll.set_val.items,
                .queue => items = coll.queue_val.items,
                else => return Value.nilValue(),
            }
            var count: usize = 0;
            var i: usize = 0;
            while (i < items.len) : (i += 1) {
                if (n) |limit| {
                    if (count >= limit) break;
                }
                // Force nested lazy sequences
                const item = items[i];
                if (item.type == .lazy_seq) {
                    _ = try forceLazySeq(allocator, item, env, depth + 1);
                }
                count += 1;
            }
            return Value.nilValue();
        }

        // iterate - repeatedly apply f to init, collecting results
        // Handle both (iterate f init) and (iterate init f) for thread-last compatibility
        if (std.mem.eql(u8, name, "iterate")) {
            if (l.items.len != 3) return error.ArityError;
            const arg1 = l.items[1];
            const arg2 = l.items[2];
            // Detect which is the function and which is the initial value
            if (arg1.type == .function or arg1.type == .builtin_fn) {
                return try evalIterate(allocator, arg1, arg2, env, depth + 1);
            } else if (arg2.type == .function or arg2.type == .builtin_fn) {
                return try evalIterate(allocator, arg2, arg1, env, depth + 1);
            }
            return try evalIterate(allocator, arg1, arg2, env, depth + 1);
        }

        // take - take first n elements from a (possibly lazy) collection
        if (std.mem.eql(u8, name, "take")) {
            if (l.items.len != 3) return error.ArityError;
            return try evalTake(allocator, l.items[1], l.items[2], env, depth);
        }

        // doall - realize lazy sequences and return the result
        if (std.mem.eql(u8, name, "doall")) {
            if (l.items.len != 2) return error.ArityError;
            var coll = try evalRec(allocator, l.items[1], env, depth + 1);
            // Handle lazy_map: force into a list and return it
            if (coll.type == .lazy_map) {
                return try forceLazyMap(allocator, coll, env);
            }
            // Handle range_val: realize into a list
            if (coll.type == .range_val) {
                const rd: *Value.RangeData = coll.range_val.?;
                const len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
                var result: list.List = .empty;
                errdefer result.deinit(allocator);
                var v: i64 = rd.start;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    try result.append(allocator, Value.intValue(v));
                    v += rd.step;
                }
                coll.deinit(allocator);
                return Value.listValue(result);
            }
            // Handle lazy_seq: force and return
            if (coll.type == .lazy_seq) {
                const forced = try forceLazySeq(allocator, coll, env, depth + 1);
                coll.deinit(allocator);
                return forced;
            }
            // For concrete collections, just return a clone
            return try coll.clone(allocator);
        }
    }

    // Evaluate the operator
    var op = try evalRec(allocator, first, env, depth + 1);
    defer op.deinit(allocator);

    // Check if operator is a macro
    if (op.type == .function and op.fn_val.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        errdefer macro_args.deinit(allocator);
        for (l.items[1..]) |arg| {
            try macro_args.append(allocator, try arg.clone(allocator));
        }
        // Call the macro with unevaluated args
        var expanded = try call(allocator, op, macro_args, env, depth + 1);
        // Evaluate the expanded form
        const result = try evalRec(allocator, expanded, env, depth + 1);
        expanded.deinit(allocator);
        return result;
    }

    // Evaluate all arguments
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    for (l.items[1..]) |arg| {
        try args.append(allocator, try evalRec(allocator, arg, env, depth + 1));
    }

    // Transfer ownership of args to call (call will deinit it).
    // Reset local copy to prevent double-free from errdefer.
    const transferred = args;
    args = list.List.empty;

    // Call the function
    return try call(allocator, op, transferred, env, depth + 1);
}

fn evalDo(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    var result: Value = Value.nilValue();
    errdefer result.deinit(allocator);

    for (forms) |form| {
        result.deinit(allocator);
        result = Value.nilValue();
        result = try evalRec(allocator, form, env, depth);
    }
    return result;
}

fn evalLet(allocator: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (bindings.type != .list and bindings.type != .vector) return error.TypeError;

    var new_env = try env.clone(allocator);
    defer new_env.deinit(allocator);

    const items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => unreachable,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const sym = items[i];
        if (sym.type != .symbol) return error.TypeError;
        // Evaluate binding value in new_env so later bindings can reference earlier ones
        const val = try evalRec(allocator, items[i + 1], &new_env, depth);
        try new_env.put(allocator, sym.sym_val, val);
    }

    return try evalDo(allocator, body, &new_env, depth);
}

fn evalCond(allocator: Allocator, clauses: []const Value, env: *Env, depth: usize) anyerror!Value {
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const cond = clauses[i];
        // Handle :else clause
        if (cond.type == .keyword and std.mem.eql(u8, cond.kw_val, "else")) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, clauses[i + 1], env, depth);
        }

        const result = try evalRec(allocator, cond, env, depth);
        if (result.isTruthy()) {
            if (i + 1 >= clauses.len) return error.ArityError;
            return try evalRec(allocator, clauses[i + 1], env, depth);
        }
    }
    return Value.nilValue();
}

fn evalLoop(allocator: Allocator, bindings: Value, body: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (bindings.type != .list and bindings.type != .vector) return error.TypeError;

    var new_env = try env.clone(allocator);
    defer new_env.deinit(allocator);

    const items = switch (bindings.type) {
        .list => bindings.list_val.items,
        .vector => bindings.vec_val.items,
        else => unreachable,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const sym = items[i];
        if (sym.type != .symbol) return error.TypeError;
        const val = try evalRec(allocator, items[i + 1], env, depth);
        try new_env.put(allocator, sym.sym_val, val);
    }

    // For a simple loop, just evaluate the body
    // A full implementation would support recur to rebind loop variables
    return try evalDo(allocator, body, &new_env, depth);
}

fn call(allocator: Allocator, op: Value, args_list: list.List, env: *Env, depth: usize) anyerror!Value {
    var args = args_list;
    defer args.deinit(allocator);

    switch (op.type) {
        .function => {
            const fn_data = op.fn_val;

            // Optimization: skip env clone if no local entries
            var new_env: Env = undefined;
            if (fn_data.env.entries.entries.len > 0) {
                new_env = try fn_data.env.clone(allocator);
            } else {
                new_env = .{
                    .allocator = allocator,
                    .entries = .empty,
                    .parent = fn_data.env.parent,
                };
            }
            defer new_env.deinit(allocator);

            const min_args = fn_data.params.items.len;
            const has_rest = fn_data.rest_name != null;

            // Check arity: must have at least min_args, or any number if variadic
            if (!has_rest and args.items.len != min_args) {
                return error.ArityError;
            }
            if (has_rest and args.items.len < min_args) {
                return error.ArityError;
            }

            // Bind regular parameters to arguments (with destructuring support)
            var i: usize = 0;
            while (i < fn_data.params.items.len) : (i += 1) {
                const param = fn_data.params.items[i];
                try bindParam(allocator, param, args.items[i], &new_env);
            }

            // Bind rest parameter to remaining args as a list
            if (has_rest and args.items.len > min_args) {
                var rest_list: list.List = .empty;
                errdefer rest_list.deinit(allocator);
                var j: usize = min_args;
                while (j < args.items.len) : (j += 1) {
                    try rest_list.append(allocator, try args.items[j].clone(allocator));
                }
                try new_env.put(allocator, fn_data.rest_name.?, Value.listValue(rest_list));
            } else if (has_rest) {
                // No extra args: bind empty list to rest parameter
                try new_env.put(allocator, fn_data.rest_name.?, Value.listValue(.empty));
            }

            // Evaluate the function body
            return try evalRec(allocator, Value.listValue(fn_data.body), &new_env, depth);
        },
        .builtin_fn => {
            var op_mut = op;
            return op_mut.builtin_fn_val(&op_mut, args, env);
        },
        .set => {
            // Set as function: returns the element if found, nil otherwise
            if (args.items.len != 1) return error.ArityError;
            for (op.set_val.items) |item| {
                if (item.equals(args.items[0])) {
                    return try item.clone(allocator);
                }
            }
            return Value.nilValue();
        },
        .map => {
            // Map as function: returns value for key, or not-found if provided
            if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
            const key = args.items[0];
            for (op.map_val.items) |entry| {
                if (entry.key.equals(key)) {
                    return try entry.value.clone(allocator);
                }
            }
            // Return not-found value if provided
            if (args.items.len == 2) {
                return try args.items[1].clone(allocator);
            }
            return Value.nilValue();
        },
        .lazy_seq => {
            // Force evaluation of lazy sequence
            if (args.items.len != 0) return error.ArityError;
            return try forceLazySeq(allocator, op, env, depth);
        },
        else => return error.NotCallable,
    }
}

// Force evaluation of a lazy sequence, returning the resulting list
fn forceLazySeq(allocator: Allocator, lazy: Value, env: *Env, depth: usize) anyerror!Value {
    _ = env;
    // Evaluate the thunk
    if (lazy.lazy_seq_val.thunk) |thunk| {
        var thunk_env = try thunk.env.clone(allocator);
        defer thunk_env.deinit(allocator);

        // Evaluate the body to get the result
        var result = try evalRec(allocator, Value.listValue(thunk.body), &thunk_env, depth);

        // The result should be a list/vector (the sequence)
        // Convert to list if needed
        var final_list: list.List = .empty;
        errdefer final_list.deinit(allocator);

        switch (result.type) {
            .list => {
                for (result.list_val.items) |item| {
                    try final_list.append(allocator, try item.clone(allocator));
                }
            },
            .vector => {
                for (result.vec_val.items) |item| {
                    try final_list.append(allocator, try item.clone(allocator));
                }
            },
            .nil => {}, // empty sequence
            else => {
                try final_list.append(allocator, result);
            },
        }

        result.deinit(allocator);
        return Value.listValue(final_list);
    }

    return Value.listValue(list.empty());
}

// Quasiquote processing
fn unquoteProcess(allocator: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    switch (form.type) {
        .list => {
            if (form.list_val.items.len == 0) return Value.listValue(list.empty());
            const first = form.list_val.items[0];
            if (first.type == .symbol) {
                if (std.mem.eql(u8, first.sym_val, "unquote")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    return try evalRec(allocator, form.list_val.items[1], env, depth);
                }
                if (std.mem.eql(u8, first.sym_val, "unquote-splicing")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    const result = try evalRec(allocator, form.list_val.items[1], env, depth);
                    if (result.type == .list) return result;
                    return error.TypeError;
                }
            }
            // Process each element
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            for (form.list_val.items) |item| {
                var processed = try unquoteProcess(allocator, item, env, depth);
                if (processed.type == .list and isUnquoteSpliceResult(processed)) {
                    for (processed.list_val.items) |elem| {
                        try result.append(allocator, try elem.clone(allocator));
                    }
                    processed.deinit(allocator);
                } else {
                    try result.append(allocator, processed);
                }
            }
            return Value.listValue(result);
        },
        .vector => {
            var result: vec.Vector = .empty;
            errdefer result.deinit(allocator);
            for (form.vec_val.items) |item| {
                try result.append(allocator, try unquoteProcess(allocator, item, env, depth));
            }
            return Value.vectorValue(result);
        },
        else => return try form.clone(allocator),
    }
}

fn isUnquoteSpliceResult(v: Value) bool {
    _ = v;
    return false; // Simplified
}

// Bind a parameter to an argument, supporting destructuring
// e.g., param=[a b], arg=[1 2] => binds a=1, b=2
fn bindParam(allocator: Allocator, param: Value, arg: Value, env: *Env) anyerror!void {
    switch (param.type) {
        .symbol => {
            try env.put(allocator, param.sym_val, try arg.clone(allocator));
        },
        .vector => {
            // Destructure: param is [x y z], arg should be a collection
            var arg_items: []const Value = undefined;
            switch (arg.type) {
                .list => arg_items = arg.list_val.items,
                .vector => arg_items = arg.vec_val.items,
                else => return error.TypeError,
            }
            if (param.vec_val.items.len != arg_items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.vec_val.items.len) : (i += 1) {
                try bindParam(allocator, param.vec_val.items[i], arg_items[i], env);
            }
        },
        .list => {
            // Same as vector but from a list
            if (param.list_val.items.len != arg.list_val.items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < param.list_val.items.len) : (i += 1) {
                try bindParam(allocator, param.list_val.items[i], arg.list_val.items[i], env);
            }
        },
        else => {}, // Ignore other param types
    }
}

fn listFromVector(allocator: Allocator, v: vec.Vector) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    for (v.items) |item| {
        try result.append(allocator, try item.clone(allocator));
    }
    return result;
}

// Thread-last macro: (->> x (f 1) (g 2 3)) => (g 2 3 (f 1 x))
// Inserts value as the LAST argument
fn evalThreadLast(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    var current = try evalRec(allocator, forms[0], env, depth);

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = forms[i];
        if (form.type != .list) {
            current.deinit(allocator);
            return error.TypeError;
        }
        if (form.list_val.items.len == 0) {
            current.deinit(allocator);
            return error.ArityError;
        }

        // Build a new list: (op arg1 arg2 ... current)
        var new_call: list.List = .empty;
        errdefer new_call.deinit(allocator);

        var j: usize = 0;
        while (j < form.list_val.items.len) : (j += 1) {
            try new_call.append(allocator, try form.list_val.items[j].clone(allocator));
        }
        try new_call.append(allocator, try current.clone(allocator));

        const next_val = try evalRec(allocator, Value.listValue(new_call), env, depth);
        current.deinit(allocator);
        current = next_val;
    }
    return current;
}

// Thread-first macro: (-> x (f 1) (g 2 3)) => (g (f 1 x) 2 3)
fn evalThreadFirst(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    var current = try evalRec(allocator, forms[0], env, depth);

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = forms[i];
        if (form.type != .list) {
            current.deinit(allocator);
            return error.TypeError;
        }
        if (form.list_val.items.len == 0) {
            current.deinit(allocator);
            return error.ArityError;
        }

        // Build a new list: (op arg1 current arg3 ...)
        var new_call: list.List = .empty;
        errdefer new_call.deinit(allocator);

        try new_call.append(allocator, try form.list_val.items[0].clone(allocator));
        var j: usize = 1;
        while (j < form.list_val.items.len) : (j += 1) {
            if (j == 1) {
                try new_call.append(allocator, try current.clone(allocator));
            }
            try new_call.append(allocator, try form.list_val.items[j].clone(allocator));
        }

        const next_val = try evalRec(allocator, Value.listValue(new_call), env, depth);
        current.deinit(allocator);
        current = next_val;
    }
    return current;
}

// iterate: repeatedly apply f to init, collecting results in a vector
fn evalIterate(allocator: Allocator, f_form: Value, init_form: Value, env: *Env, depth: usize) anyerror!Value {
    var f = try evalRec(allocator, f_form, env, depth);
    defer f.deinit(allocator);
    var current = try evalRec(allocator, init_form, env, depth);

    var result: vec.Vector = .empty;
    errdefer result.deinit(allocator);

    const max_iter: usize = 1000;
    var i: usize = 0;
    while (i < max_iter) : (i += 1) {
        try result.append(allocator, try current.clone(allocator));

        // Call f with current as argument
        var arg_list: list.List = .empty;
        errdefer arg_list.deinit(allocator);
        try arg_list.append(allocator, try current.clone(allocator));

        const next_val = try callValue(allocator, f, arg_list, env, depth + 1);
        current.deinit(allocator);
        current = next_val;
    }
    current.deinit(allocator);
    return Value.vectorValue(result);
}

// map: apply f to each element of collection
fn evalMap(allocator: Allocator, f_form: Value, coll_form: Value, env: *Env, depth: usize) anyerror!Value {
    var f = try evalRec(allocator, f_form, env, depth);
    defer f.deinit(allocator);
    // Determine if coll_form is data or a function call to evaluate
    var coll: Value = undefined;
    switch (coll_form.type) {
        .vector => coll = try coll_form.clone(allocator),
        .list => {
            if (coll_form.list_val.items.len > 0 and
                coll_form.list_val.items[0].type == .symbol and
                !std.mem.eql(u8, coll_form.list_val.items[0].sym_val, "quote"))
            {
                coll = try evalRec(allocator, coll_form, env, depth);
            } else if (coll_form.list_val.items.len >= 2 and
                       coll_form.list_val.items[0].type == .symbol and
                       std.mem.eql(u8, coll_form.list_val.items[0].sym_val, "quote"))
            {
                coll = try coll_form.list_val.items[1].clone(allocator);
            } else {
                coll = try coll_form.clone(allocator);
            }
        },
        .lazy_seq => {
            coll = try forceLazySeq(allocator, coll_form, env, depth);
        },
        else => coll = try evalRec(allocator, coll_form, env, depth),
    }
    defer coll.deinit(allocator);

    // If we got a lazy_seq back from evaluation, force it
    if (coll.type == .lazy_seq) {
        const forced = try forceLazySeq(allocator, coll, env, depth);
        coll.deinit(allocator);
        coll = forced;
    }

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    for (items) |item| {
        var arg_list: list.List = .empty;
        errdefer arg_list.deinit(allocator);
        try arg_list.append(allocator, try item.clone(allocator));

        const mapped = try callValue(allocator, f, arg_list, env, depth + 1);
        try result.append(allocator, mapped);
    }
    return Value.listValue(result);
}

// take: take first n elements from a collection
fn evalTake(allocator: Allocator, n_form: Value, coll_form: Value, env: *Env, depth: usize) anyerror!Value {
    var n_val = try evalRec(allocator, n_form, env, depth);
    defer n_val.deinit(allocator);
    // Determine if coll_form is data or a function call to evaluate
    var coll: Value = undefined;
    switch (coll_form.type) {
        .vector => coll = try coll_form.clone(allocator),
        .list => {
            // A list is a function call if its first element is a symbol
            // (except for quote which is data)
            if (coll_form.list_val.items.len > 0 and
                coll_form.list_val.items[0].type == .symbol and
                !std.mem.eql(u8, coll_form.list_val.items[0].sym_val, "quote"))
            {
                // It's a function call, evaluate it
                coll = try evalRec(allocator, coll_form, env, depth);
            } else if (coll_form.list_val.items.len >= 2 and
                       coll_form.list_val.items[0].type == .symbol and
                       std.mem.eql(u8, coll_form.list_val.items[0].sym_val, "quote"))
            {
                // Quoted list, use the data directly
                coll = try coll_form.list_val.items[1].clone(allocator);
            } else {
                // Empty list or list starting with non-symbol: it's data
                coll = try coll_form.clone(allocator);
            }
        },
        .lazy_seq => {
            // Force the lazy sequence
            coll = try forceLazySeq(allocator, coll_form, env, depth);
        },
        .lazy_map => {
            coll = coll_form;
        },
        .range_val => {
            coll = coll_form;
        },
        else => coll = try evalRec(allocator, coll_form, env, depth),
    }

    const n: i64 = switch (n_val.type) {
        .integer => n_val.int_val,
        .float => @as(i64, @intFromFloat(n_val.float_val)),
        else => return error.TypeError,
    };

    // Handle range_val: take n elements from range
    if (coll.type == .range_val) {
        defer coll.deinit(allocator);
        const rd: *Value.RangeData = coll.range_val.?;
        const total_len: usize = if (rd.step > 0 and rd.end > rd.start) @as(usize, @intCast(@divTrunc(rd.end - rd.start + rd.step - 1, rd.step))) else 0;
        const count: usize = if (@as(usize, @intCast(n)) < total_len) @as(usize, @intCast(n)) else total_len;
        var result: list.List = .empty;
        errdefer result.deinit(allocator);
        var v: i64 = rd.start;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try result.append(allocator, Value.intValue(v));
            v += rd.step;
        }
        return Value.listValue(result);
    }

    // Handle lazy_map: iterate element-by-element, taking only n elements
    if (coll.type == .lazy_map) {
        defer coll.deinit(allocator);
        const lm: *Value.LazyMapData = coll.lazy_map_val.?;
        var coll_items: []const Value = undefined;
        const coll_len: usize = switch (lm.coll.type) {
            .list => lm.coll.list_val.items.len,
            .vector => lm.coll.vec_val.items.len,
            else => return Value.listValue(list.empty()),
        };
        switch (lm.coll.type) {
            .list => coll_items = lm.coll.list_val.items,
            .vector => coll_items = lm.coll.vec_val.items,
            else => return Value.listValue(list.empty()),
        }
        var result: list.List = .empty;
        errdefer result.deinit(allocator);
        const count: usize = if (@as(usize, @intCast(n)) < coll_len) @as(usize, @intCast(n)) else coll_len;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var arg_list: list.List = .empty;
            errdefer arg_list.deinit(allocator);
            try arg_list.append(allocator, try coll_items[i].clone(allocator));
            const mapped = try eval_helpers.callBuiltin(allocator, lm.fn_val, arg_list, env);
            try result.append(allocator, mapped);
        }
        return Value.listValue(result);
    }
    defer coll.deinit(allocator);

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    const count: usize = if (@as(usize, @intCast(n)) < items.len) @as(usize, @intCast(n)) else items.len;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try result.append(allocator, try items[i].clone(allocator));
    }
    return Value.listValue(result);
}

// Call a value (function or builtin) with arguments
fn callValue(allocator: Allocator, f: Value, args: list.List, env: *Env, depth: usize) anyerror!Value {
    switch (f.type) {
        .function => {
            const fn_data = f.fn_val;

            // Optimization: skip env clone if no local entries
            var new_env: Env = undefined;
            if (fn_data.env.entries.entries.len > 0) {
                new_env = try fn_data.env.clone(allocator);
            } else {
                new_env = .{
                    .allocator = allocator,
                    .entries = .empty,
                    .parent = fn_data.env.parent,
                };
            }
            defer new_env.deinit(allocator);

            var i: usize = 0;
            while (i < fn_data.params.items.len) : (i += 1) {
                try bindParam(allocator, fn_data.params.items[i], args.items[i], &new_env);
            }
            return try evalRec(allocator, Value.listValue(fn_data.body), &new_env, depth);
        },
        .builtin_fn => {
            var f_mut = f;
            return f_mut.builtin_fn_val(&f_mut, args, env);
        },
        else => return error.NotCallable,
    }
}
