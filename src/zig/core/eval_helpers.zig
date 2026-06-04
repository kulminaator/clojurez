// Shared evaluation helpers for calling user-defined functions from built-ins
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");

const Allocator = std.mem.Allocator;

pub fn listFromVector(allocator: Allocator, v: vec.Vector) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    for (v.items) |item| {
        try result.append(allocator, try item.clone(allocator));
    }
    return result;
}

pub fn callBuiltin(allocator: Allocator, f: Value, args_list: list.List, env: *Value.Env) anyerror!Value {
    switch (f.type) {
        .function => {
            const fn_data = f.fn_val;
            const arg_count = args_list.items.len;

            // Find matching arity
            var matched_arity: ?*const Value.Arity = null;
            var ai: usize = 0;
            while (ai < fn_data.arities.items.len) : (ai += 1) {
                const arity = &fn_data.arities.items[ai];
                const min_args = arity.params.items.len;
                const has_rest = arity.rest_name != null;
                if (has_rest) {
                    if (arg_count >= min_args) {
                        matched_arity = arity;
                        break;
                    }
                } else {
                    if (arg_count == min_args) {
                        matched_arity = arity;
                        break;
                    }
                }
            }
            if (matched_arity == null) return error.ArityError;
            const arity = matched_arity.?;

            // Optimization: if function env has no local entries, skip clone
            // and create a thin wrapper pointing to the parent
            var new_env: Value.Env = undefined;
            const has_locals = fn_data.env.entries.entries.len > 0;
            if (has_locals) {
                new_env = try fn_data.env.clone(allocator);
            } else {
                new_env = .{
                    .allocator = allocator,
                    .entries = .empty,
                    .parent = fn_data.env.parent,
                };
            }
            defer new_env.deinit(allocator);

            const min_args = arity.params.items.len;
            const has_rest = arity.rest_name != null;

            var i: usize = 0;
            while (i < arity.params.items.len) : (i += 1) {
                const param = arity.params.items[i];
                if (param.type == .symbol) {
                    try new_env.put(param.sym_val, try args_list.items[i].clone(allocator));
                }
            }

            if (has_rest and args_list.items.len > min_args) {
                var rest_list: list.List = .empty;
                errdefer rest_list.deinit(allocator);
                var j: usize = min_args;
                while (j < args_list.items.len) : (j += 1) {
                    try rest_list.append(allocator, try args_list.items[j].clone(allocator));
                }
                try new_env.put(arity.rest_name.?, Value.listValue(rest_list));
            } else if (has_rest) {
                try new_env.put(arity.rest_name.?, Value.listValue(.empty));
            }

            return try evalBody(allocator, arity.body, &new_env);
        },
        .builtin_fn => {
            var f_mut = f;
            return f_mut.builtin_fn_val(&f_mut, args_list, env);
        },
        else => return error.NotCallable,
    }
}

pub fn evalBody(allocator: Allocator, body: list.List, env: *Value.Env) anyerror!Value {
    if (body.items.len == 0) return Value.nilValue();
    var cloned_body: list.List = .empty;
    errdefer cloned_body.deinit(allocator);
    try cloned_body.ensureTotalCapacity(allocator, body.items.len);
    for (body.items) |item| {
        try cloned_body.append(allocator, try item.clone(allocator));
    }
    return try evalForm(allocator, Value.listValue(cloned_body), env);
}

pub fn evalForm(allocator: Allocator, form: Value, env: *Value.Env) anyerror!Value {
    switch (form.type) {
        .nil, .bool, .integer, .float, .string, .keyword => return try form.clone(allocator),
        .symbol => {
            if (env.get(form.sym_val)) |v| return try v.clone(allocator);
            return error.UndefinedSymbol;
        },
        .list => {
            if (form.list_val.items.len == 0) return Value.listValue(list.empty());
            const first = form.list_val.items[0];
            if (first.type == .symbol) {
                if (std.mem.eql(u8, first.sym_val, "quote")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    return try form.list_val.items[1].clone(allocator);
                }
                if (std.mem.eql(u8, first.sym_val, "do")) {
                    var result: Value = Value.nilValue();
                    errdefer result.deinit(allocator);
                    for (form.list_val.items[1..]) |arg| {
                        result.deinit(allocator);
                        result = try evalForm(allocator, arg, env);
                    }
                    return result;
                }
                if (std.mem.eql(u8, first.sym_val, "if")) {
                    if (form.list_val.items.len < 3) return error.ArityError;
                    var test_val = try evalForm(allocator, form.list_val.items[1], env);
                    defer test_val.deinit(allocator);
                    if (test_val.isTruthy()) {
                        return try evalForm(allocator, form.list_val.items[2], env);
                    } else if (form.list_val.items.len >= 4) {
                        return try evalForm(allocator, form.list_val.items[3], env);
                    } else {
                        return Value.nilValue();
                    }
                }
                if (std.mem.eql(u8, first.sym_val, "when")) {
                    if (form.list_val.items.len < 3) return error.ArityError;
                    var test_val = try evalForm(allocator, form.list_val.items[1], env);
                    defer test_val.deinit(allocator);
                    if (test_val.isTruthy()) {
                        var result: Value = Value.nilValue();
                        errdefer result.deinit(allocator);
                        for (form.list_val.items[2..]) |arg| {
                            result.deinit(allocator);
                            result = try evalForm(allocator, arg, env);
                        }
                        return result;
                    }
                    return Value.nilValue();
                }
                if (std.mem.eql(u8, first.sym_val, "and")) {
                    if (form.list_val.items.len == 1) return Value.boolValue(true);
                    var i: usize = 1;
                    while (i < form.list_val.items.len) : (i += 1) {
                        var val = try evalForm(allocator, form.list_val.items[i], env);
                        if (!val.isTruthy()) {
                            return val;
                        }
                        if (i == form.list_val.items.len - 1) {
                            return val;
                        }
                        val.deinit(allocator);
                    }
                    return Value.nilValue();
                }
                if (std.mem.eql(u8, first.sym_val, "or")) {
                    if (form.list_val.items.len == 0) return Value.nilValue();
                    var i: usize = 1;
                    while (i < form.list_val.items.len) : (i += 1) {
                        var val = try evalForm(allocator, form.list_val.items[i], env);
                        if (val.isTruthy()) return val;
                        val.deinit(allocator);
                    }
                    return Value.nilValue();
                }
                if (std.mem.eql(u8, first.sym_val, "cond")) {
                    var i: usize = 1;
                    while (i < form.list_val.items.len) : (i += 2) {
                        if (i + 1 >= form.list_val.items.len) return error.ArityError;
                        var test_val = try evalForm(allocator, form.list_val.items[i], env);
                        defer test_val.deinit(allocator);
                        if (test_val.isTruthy()) {
                            return try evalForm(allocator, form.list_val.items[i + 1], env);
                        }
                    }
                    return Value.nilValue();
                }
                if (std.mem.eql(u8, first.sym_val, "let")) {
                    if (form.list_val.items.len < 3) return error.ArityError;
                    const bindings = form.list_val.items[1];
                    if (bindings.type != .list and bindings.type != .vector) return error.TypeError;
                    const bind_items = if (bindings.type == .list) bindings.list_val.items else bindings.vec_val.items;
                    var new_env = try env.clone(allocator);
                    defer new_env.deinit(allocator);
                    var bi: usize = 0;
                    while (bi < bind_items.len) : (bi += 2) {
                        const sym = bind_items[bi];
                        if (sym.type != .symbol) return error.TypeError;
                        const val = try evalForm(allocator, bind_items[bi + 1], &new_env);
                        try new_env.put(sym.sym_val, val);
                    }
                    var result: Value = Value.nilValue();
                    errdefer result.deinit(allocator);
                    for (form.list_val.items[2..]) |arg| {
                        result.deinit(allocator);
                        result = try evalForm(allocator, arg, &new_env);
                    }
                    return result;
                }
                if (std.mem.eql(u8, first.sym_val, "fn")) {
                    if (form.list_val.items.len < 2) return error.ArityError;
                    const params = form.list_val.items[1];
                    if (params.type != .list and params.type != .vector) return error.TypeError;
                    const params_list = if (params.type == .vector) try listFromVector(allocator, params.vec_val) else params.list_val;
                    const body = if (form.list_val.items.len >= 3) form.list_val.items[2..] else &[_]Value{};
                    var body_list: list.List = .empty;
                    errdefer body_list.deinit(allocator);
                    try body_list.append(allocator, try Value.symValue(allocator, "do"));
                    for (body) |form_item| {
                        try body_list.append(allocator, try form_item.clone(allocator));
                    }
                    const cloned_params = try params_list.clone(allocator);
                    const cloned_body = try body_list.clone(allocator);
                    const fn_env = try env.clone(allocator);
                    return try Value.fnValueSingle(allocator, cloned_params, cloned_body, fn_env, null, false);
                }
                if (std.mem.eql(u8, first.sym_val, "lazy-seq")) {
                    if (form.list_val.items.len < 2) return error.ArityError;
                    // Build the thunk body as a list of forms to evaluate
                    var body: list.List = .empty;
                    errdefer body.deinit(allocator);
                    try body.append(allocator, try Value.symValue(allocator, "do"));
                    for (form.list_val.items[1..]) |f_item| {
                        try body.append(allocator, try f_item.clone(allocator));
                    }
                    const thunk = try allocator.create(Value.LazySeqThunk);
                    thunk.* = .{
                        .params = list.empty(),
                        .body = body,
                        .env = try env.clone(allocator),
                    };
                    return Value.lazySeqValue(thunk);
                }
            }
            var op = try evalForm(allocator, first, env);
            defer op.deinit(allocator);

            // Check if operator is a macro
            if (op.type == .function and op.fn_val.is_macro) {
                // Macro: pass unevaluated arguments
                var macro_args: list.List = .empty;
                errdefer macro_args.deinit(allocator);
                for (form.list_val.items[1..]) |arg| {
                    try macro_args.append(allocator, try arg.clone(allocator));
                }
                // Call the macro with unevaluated args
                var expanded = try callBuiltin(allocator, op, macro_args, env);
                // Evaluate the expanded form
                const result = try evalForm(allocator, expanded, env);
                expanded.deinit(allocator);
                return result;
            }

            var args: list.List = .empty;
            errdefer args.deinit(allocator);
            for (form.list_val.items[1..]) |arg| {
                try args.append(allocator, try evalForm(allocator, arg, env));
            }
            return try callBuiltin(allocator, op, args, env);
        },
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            for (form.vec_val.items) |item| {
                try new_vec.append(allocator, try evalForm(allocator, item, env));
            }
            return Value.vectorValue(new_vec);
        },
        else => return try form.clone(allocator),
    }
}
