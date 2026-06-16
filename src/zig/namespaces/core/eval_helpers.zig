// Shared evaluation helpers for calling user-defined functions from built-ins
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const phm = @import("../../persistent_hash_map.zig");
const helpers = @import("helpers.zig");
const eval_ns = @import("../../eval_ns.zig");
const eval_macro = @import("../../eval_macro.zig");

const Allocator = std.mem.Allocator;

// Bind a parameter to an argument, supporting destructuring
fn bindParam(allocator: Allocator, param: Value, arg: Value, env: *Value.Env) anyerror!void {
    switch (param.type) {
        .symbol => {
            try env.put(param.sym_val, try arg.clone(allocator));
        },
        .vector => {
            var arg_items: []const Value = undefined;
            switch (arg.type) {
                .list => arg_items = arg.list_val.items,
                .vector => arg_items = arg.vec_val.items,
                else => return error.TypeError,
            }
            if (param.vec_val.items.len != arg_items.len) return error.ArityError;
            var i: usize = 0;
            while (i < param.vec_val.items.len) : (i += 1) {
                try bindParam(allocator, param.vec_val.items[i], arg_items[i], env);
            }
        },
        .list => {
            if (param.list_val.items.len != arg.list_val.items.len) return error.ArityError;
            var i: usize = 0;
            while (i < param.list_val.items.len) : (i += 1) {
                try bindParam(allocator, param.list_val.items[i], arg.list_val.items[i], env);
            }
        },
        else => {},
    }
}

pub fn callBuiltin(allocator: Allocator, f: Value, args_list: list.List, env: *Value.Env) anyerror!Value {
    switch (f.type) {
        .function => {
            const fn_data = f.fn_val orelse return error.TypeError;
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

            // Fast path: 2-param, no-rest, body is a single 2-arg call with matching params.
            // Covers wrapper functions like (defn + [a b] (zig.core/+ a b)).
            // Avoids env creation, hash-map param binding, body cloning, and symbol resolution.
            if (arity.params.items.len == 2 and arity.rest_name == null and arg_count == 2) {
                if (arity.params.items[0].type == .symbol and arity.params.items[1].type == .symbol) {
                    // Body is wrapped as (do <call>). Find the actual call.
                    var body_call: list.List = undefined;
                    if (arity.body.items.len >= 2 and
                        arity.body.items[0].type == .symbol and
                        std.mem.eql(u8, arity.body.items[0].sym_val, "do") and
                        arity.body.items[1].type == .list)
                    {
                        body_call = arity.body.items[1].list_val;
                    } else if (arity.body.items.len == 1 and arity.body.items[0].type == .list) {
                        body_call = arity.body.items[0].list_val;
                    } else {
                        body_call = list.empty();
                    }
                    if (body_call.items.len == 3) {
                        const body_op = body_call.items[0];
                        const body_arg0 = body_call.items[1];
                        const body_arg1 = body_call.items[2];
                        if (body_arg0.type == .symbol and body_arg1.type == .symbol and
                            std.mem.eql(u8, body_arg0.sym_val, arity.params.items[0].sym_val) and
                            std.mem.eql(u8, body_arg1.sym_val, arity.params.items[1].sym_val))
                        {
                            var resolved_op = try evalForm(allocator, body_op, env);
                            defer resolved_op.deinit(allocator);
                            var call_args: list.List = .empty;
                            errdefer call_args.deinit(allocator);
                            try call_args.append(allocator, try args_list.items[0].clone(allocator));
                            try call_args.append(allocator, try args_list.items[1].clone(allocator));
                            return try callBuiltin(allocator, resolved_op, call_args, env);
                        }
                    }
                }
            }

            // Optimization: if function env has no local entries, skip clone
            // and create a thin wrapper pointing to the parent
            var new_env: Value.Env = undefined;
            const has_locals = !fn_data.env.entries.isEmpty();
            if (has_locals) {
                new_env = try fn_data.env.clone(allocator);
            } else {
                new_env = .{
                    .allocator = allocator,
                    .entries = phm.PersistentHashMap.empty(),
                    .parent = fn_data.env.parent,
                    .ns_manager = null,
                };
            }
            defer new_env.deinit(allocator);

            // Bind function name for self-reference (e.g., (fn self [x] (self (dec x))))
            if (fn_data.name) |fn_name| {
                const fn_clone = try f.clone(allocator);
                try new_env.put(fn_name, fn_clone);
            }

            const min_args = arity.params.items.len;
            const has_rest = arity.rest_name != null;

            var i: usize = 0;
            while (i < arity.params.items.len) : (i += 1) {
                const param = arity.params.items[i];
                try bindParam(allocator, param, args_list.items[i], &new_env);
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
        .keyword => {
            // Keyword as function: looks up the keyword in a map
            if (args_list.items.len != 1) return error.ArityError;
            const coll = args_list.items[0];
            if (coll.type != .map) return Value.nilValue();
            for (coll.map_val.items) |entry| {
                if (entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, f.kw_val)) {
                    return try entry.value.clone(allocator);
                }
            }
            return Value.nilValue();
        },
        else => {
            std.debug.print("NotCallable in eval_helpers: type={s}\n", .{@tagName(f.type)});
            return error.NotCallable;
        }
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
            // Handle qualified symbols: alias/name or namespace/name
            if (std.mem.indexOfScalar(u8, form.sym_val, '/')) |slash_idx| {
                const alias = form.sym_val[0..slash_idx];
                const name = form.sym_val[slash_idx + 1 ..];
                const ns_mgr = eval_ns.findNsManager(env) orelse {
                    const val2 = env.get(form.sym_val);
                    if (val2) |v| return try v.clone(allocator);
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
                    return error.UndefinedSymbol;
                };
                const current_ns = ns_mgr.getCurrentNamespace();
                const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
                const target_env = ns_mgr.getNamespace(target_ns) orelse {
                    const val3 = env.get(form.sym_val);
                    if (val3) |v| return try v.clone(allocator);
                    std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
                    return error.UndefinedSymbol;
                };
                const val4 = target_env.get(name);
                if (val4) |v| return try v.clone(allocator);
                std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
                    return error.UndefinedSymbol;
            }
            if (env.get(form.sym_val)) |v| return try v.clone(allocator);
            std.debug.print("Undefined symbol: '{s}'\n", .{form.sym_val});
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
                if (std.mem.eql(u8, first.sym_val, "quasiquote")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    return try eval_macro.unquoteProcess(allocator, form.list_val.items[1], env, 0);
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
                    var idx: usize = 1;
                    // Skip optional name for self-reference
                    var fn_name: ?[]const u8 = null;
                    if (form.list_val.items[idx].type == .symbol) {
                        fn_name = try allocator.dupe(u8, form.list_val.items[idx].sym_val);
                        idx += 1;
                    }
                    if (idx >= form.list_val.items.len) return error.ArityError;
                    const params = form.list_val.items[idx];
                    if (params.type != .list and params.type != .vector) return error.TypeError;
                    const params_list = if (params.type == .vector) try helpers.listFromVector(allocator, params.vec_val) else params.list_val;
                    const body = if (form.list_val.items.len >= idx + 1) form.list_val.items[idx + 1 ..] else &[_]Value{};
                    var body_list: list.List = .empty;
                    errdefer body_list.deinit(allocator);
                    try body_list.append(allocator, try Value.symValue(allocator, "do"));
                    for (body) |form_item| {
                        try body_list.append(allocator, try form_item.clone(allocator));
                    }
                    const cloned_params = try params_list.clone(allocator);
                    const cloned_body = try body_list.clone(allocator);
                    const fn_env = try env.clone(allocator);
                    return try Value.fnValueSingleNamed(allocator, cloned_params, cloned_body, fn_env, null, false, fn_name);
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
            if (op.type == .function and op.fn_val.?.is_macro) {
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
        .cons => {
            // Evaluate cons cell as a function call: (operator arg1 arg2 ... . tail)
            // First, convert cons to list for uniform handling
            var cons_list: list.List = .empty;
            errdefer cons_list.deinit(allocator);
            var c = form;
            while (c.type == .cons) {
                const cdata = c.cons_val.?;
                try cons_list.append(allocator, try cdata.head.clone(allocator));
                c = try cdata.tail.clone(allocator);
            }
            if (c.type == .list) {
                // Splice the list elements (not append as single element)
                for (c.list_val.items) |item| {
                    try cons_list.append(allocator, try item.clone(allocator));
                }
            } else if (c.type != .nil) {
                try cons_list.append(allocator, c);
            }
            // Now evaluate the list as a function call
            if (cons_list.items.len == 0) {
                return Value.listValue(list.empty());
            }
            const first = cons_list.items[0];
            if (first.type == .symbol) {
                // Re-create as a proper list for special form handling
                var proper_list: list.List = .empty;
                errdefer proper_list.deinit(allocator);
                for (cons_list.items) |item| {
                    try proper_list.append(allocator, item);
                }
                const list_val = Value.listValue(proper_list);
                return try evalForm(allocator, list_val, env);
            }
            // Non-symbol operator: evaluate normally
            var op = try evalForm(allocator, first, env);
            defer op.deinit(allocator);
            var args: list.List = .empty;
            errdefer args.deinit(allocator);
            for (cons_list.items[1..]) |arg| {
                try args.append(allocator, try evalForm(allocator, arg, env));
            }
            return try callBuiltin(allocator, op, args, env);
        },
        else => return try form.clone(allocator),
    }
}

/// macroexpand-1: expand a macro call once, or return the form unchanged.
/// Takes a single argument: the form to expand.
pub fn core_macroexpand_1(self: *Value, args: list.List, env_env: *Value.Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const form = args.items[0];

    // Only lists can be macro calls
    if (form.type != .list or form.list_val.items.len == 0) {
        return try form.clone(env_env.allocator);
    }

    const allocator = env_env.allocator;
    const first = form.list_val.items[0];

    // Resolve the operator
    var op: Value = undefined;
    if (first.type == .symbol) {
        if (env_env.get(first.sym_val)) |v| {
            op = try v.clone(allocator);
        } else {
            // Symbol not found - return form unchanged
            return try form.clone(allocator);
        }
    } else {
        // Not a symbol - return form unchanged
        return try form.clone(allocator);
    }
    defer op.deinit(allocator);

    // Check if operator is a macro
    if (op.type == .function and op.fn_val.?.is_macro) {
        // Macro: pass unevaluated arguments
        var macro_args: list.List = .empty;
        defer macro_args.deinit(allocator);
        for (form.list_val.items[1..]) |arg| {
            try macro_args.append(allocator, try arg.clone(allocator));
        }
        // Call the macro with unevaluated args and return the result WITHOUT evaluating
        return try callBuiltin(allocator, op, macro_args, env_env);
    }

    // Not a macro - return form unchanged
    return try form.clone(allocator);
}

/// macroexpand: repeatedly expand macros until no more expansion.
/// Takes a single argument: the form to expand.
pub fn core_macroexpand(self: *Value, args: list.List, env_env: *Value.Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;

    var current = try args.items[0].clone(env_env.allocator);
    errdefer current.deinit(env_env.allocator);

    while (true) {
        var call_args: list.List = .empty;
        errdefer call_args.deinit(env_env.allocator);
        try call_args.append(env_env.allocator, try current.clone(env_env.allocator));
        const expanded = try core_macroexpand_1(self, call_args, env_env);
        current.deinit(env_env.allocator);

        // Check if anything changed by comparing
        // If the expanded form is the same type and structure, stop
        if (expanded.type != .list or expanded.list_val.items.len == 0) {
            return expanded;
        }
        const exp_first = expanded.list_val.items[0];
        if (exp_first.type != .symbol) {
            return expanded;
        }
        // Check if the expanded first element is a macro
        if (env_env.get(exp_first.sym_val)) |v| {
            if (v.type == .function and v.fn_val.?.is_macro) {
                current = expanded;
                continue;
            }
        }
        return expanded;
    }
}
