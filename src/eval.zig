const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = Value.Env;
const core = @import("core.zig");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;

pub const EvalError = error{
    UndefinedSymbol,
    NotCallable,
    TypeError,
    ArityError,
    RecursionLimit,
};

const MAX_RECURSION = 1000;

pub fn eval(allocator: Allocator, form: Value, env: *Env) anyerror!Value {
    return evalRec(allocator, form, env, 0);
}

fn evalRec(allocator: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    if (depth > MAX_RECURSION) return error.RecursionLimit;

    switch (form.type) {
        .nil, .bool, .integer, .float, .string, .keyword => {
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
    }
    unreachable;
}

fn evalList(allocator: Allocator, l: list.List, env: *Env, depth: usize) anyerror!Value {
    if (l.items.len == 0) return Value.listValue(list.empty());

    const first = l.items[0];

    // Self-evaluating symbols (special forms)
    if (first.type == .symbol) {
        const name = first.sym_val;

        // Special forms that don't evaluate their arguments
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
            const params = l.items[2];
            if (params.type != .list and params.type != .vector) return error.TypeError;
            const params_list = if (params.type == .vector) try listFromVector(allocator, params.vec_val) else params.list_val;
            const body = if (l.items.len >= 4) l.items[3..] else &[_]Value{};

            var body_list: list.List = .empty;
            errdefer body_list.deinit(allocator);
            try body_list.append(allocator, try Value.symValue(allocator, "do"));
            for (body) |form_item| {
                try body_list.append(allocator, try form_item.clone(allocator));
            }

            const cloned_params = try params_list.clone(allocator);
            const cloned_body = try body_list.clone(allocator);
            // Create fn_env with parent = env so it can see all global symbols
            // including the function itself (for recursion)
            const fn_env: Env = .{
                .allocator = allocator,
                .entries = .empty,
                .parent = env,
            };
            const fn_val = Value.fnValue(cloned_params, cloned_body, fn_env);
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

            const cloned_params = try params_list.clone(allocator);
            const cloned_body = try body_list.clone(allocator);
            const fn_env = try env.clone(allocator);
            return Value.fnValue(cloned_params, cloned_body, fn_env);
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
            if (bindings.type != .list) return error.TypeError;
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

        // map - apply f to each element
        if (std.mem.eql(u8, name, "map")) {
            if (l.items.len != 3) return error.ArityError;
            return try evalMap(allocator, l.items[1], l.items[2], env, depth + 1);
        }

        // take - take first n elements from a (possibly lazy) collection
        if (std.mem.eql(u8, name, "take")) {
            if (l.items.len != 3) return error.ArityError;
            return try evalTake(allocator, l.items[1], l.items[2], env, depth);
        }
    }

    // Evaluate the operator
    const op = try evalRec(allocator, first, env, depth + 1);

    // Evaluate all arguments
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    _ = &args; // silence unused warning
    for (l.items[1..]) |arg| {
        try args.append(allocator, try evalRec(allocator, arg, env, depth + 1));
    }

    // Call the function
    return try call(allocator, op, args, env, depth + 1);
}

fn evalDo(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    var result: Value = Value.nilValue();
    errdefer result.deinit(allocator);

    for (forms) |form| {
        result.deinit(allocator);
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
            var new_env = try fn_data.env.clone(allocator);
            defer new_env.deinit(allocator);

            // Bind parameters to arguments (with destructuring support)
            if (args.items.len != fn_data.params.items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < fn_data.params.items.len) : (i += 1) {
                const param = fn_data.params.items[i];
                try bindParam(allocator, param, args.items[i], &new_env);
            }

            // Evaluate the function body
            return try evalRec(allocator, Value.listValue(fn_data.body), &new_env, depth);
        },
        .builtin_fn => {
            var op_mut = op;
            return op_mut.builtin_fn_val(&op_mut, args, env);
        },
        else => return error.NotCallable,
    }
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
        else => coll = try evalRec(allocator, coll_form, env, depth),
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
        else => coll = try evalRec(allocator, coll_form, env, depth),
    }
    defer coll.deinit(allocator);

    const n: i64 = switch (n_val.type) {
        .integer => n_val.int_val,
        .float => @as(i64, @intFromFloat(n_val.float_val)),
        else => return error.TypeError,
    };

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
            var new_env = try fn_data.env.clone(allocator);
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
