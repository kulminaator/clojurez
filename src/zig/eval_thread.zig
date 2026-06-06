// Threading macro implementations: ->, ->>, cond->, cond->>
const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const Env = Value.Env;
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

// Thread-last macro: (->> x (f 1) (g 2 3)) => (g 2 3 (f 1 x))
// Inserts value as the LAST argument
pub fn evalThreadLast(allocator: Allocator, arena_alloc: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    var current = try eval.evalRec(allocator, arena_alloc, forms[0], env, depth);

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = forms[i];

        // Handle non-list forms: (->> x inc) => (inc x)
        if (form.type != .list) {
            var new_call: list.List = .empty;
            errdefer new_call.deinit(arena_alloc);
            try new_call.append(arena_alloc, try form.clone(arena_alloc));
            try new_call.append(arena_alloc, try current.clone(arena_alloc));
            const next_val = try eval.evalRec(allocator, arena_alloc, Value.listValue(new_call), env, depth);
            current.deinit(arena_alloc);
            current = next_val;
            continue;
        }

        if (form.list_val.items.len == 0) {
            current.deinit(arena_alloc);
            return error.ArityError;
        }

        // Build a new list: (op arg1 arg2 ... current)
        var new_call: list.List = .empty;
        errdefer new_call.deinit(arena_alloc);

        var j: usize = 0;
        while (j < form.list_val.items.len) : (j += 1) {
            try new_call.append(arena_alloc, try form.list_val.items[j].clone(arena_alloc));
        }
        try new_call.append(arena_alloc, try current.clone(arena_alloc));

        const next_val = try eval.evalRec(allocator, arena_alloc, Value.listValue(new_call), env, depth);
        current.deinit(arena_alloc);
        current = next_val;
    }
    return current;
}

// Thread-first macro: (-> x (f 1) (g 2 3)) => (g (f 1 x) 2 3)
pub fn evalThreadFirst(allocator: Allocator, arena_alloc: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    var current = try eval.evalRec(allocator, arena_alloc, forms[0], env, depth);

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = forms[i];

        // Handle non-list forms: (-> x inc) => (inc x)
        if (form.type != .list) {
            var new_call: list.List = .empty;
            errdefer new_call.deinit(arena_alloc);
            try new_call.append(arena_alloc, try form.clone(arena_alloc));
            try new_call.append(arena_alloc, try current.clone(arena_alloc));
            const next_val = try eval.evalRec(allocator, arena_alloc, Value.listValue(new_call), env, depth);
            current.deinit(arena_alloc);
            current = next_val;
            continue;
        }

        if (form.list_val.items.len == 0) {
            current.deinit(arena_alloc);
            return error.ArityError;
        }

        // Build a new list: (op current arg3 ...)
        var new_call: list.List = .empty;
        errdefer new_call.deinit(arena_alloc);

        try new_call.append(arena_alloc, try form.list_val.items[0].clone(arena_alloc));
        var j: usize = 1;
        while (j < form.list_val.items.len) : (j += 1) {
            if (j == 1) {
                try new_call.append(arena_alloc, try current.clone(arena_alloc));
            }
            try new_call.append(arena_alloc, try form.list_val.items[j].clone(arena_alloc));
        }

        const next_val = try eval.evalRec(allocator, arena_alloc, Value.listValue(new_call), env, depth);
        current.deinit(arena_alloc);
        current = next_val;
    }
    return current;
}

// cond-> - thread-first with conditions
// (cond-> expr test1 step1 test2 step2 ...)
pub fn evalCondThreadFirst(allocator: Allocator, arena_alloc: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    var current = try eval.evalRec(allocator, arena_alloc, forms[0], env, depth);

    var i: usize = 1;
    while (i + 1 < forms.len) : (i += 2) {
        var test_val_form = try eval.evalRec(allocator, arena_alloc, forms[i], env, depth);
        if (test_val_form.isTruthy()) {
            const step = forms[i + 1];
            if (step.type == .list and step.list_val.items.len > 0) {
                // Evaluate operator and args, inserting current as second arg
                var op = try eval.evalRec(allocator, arena_alloc, step.list_val.items[0], env, depth);
                defer op.deinit(arena_alloc);
                var args: list.List = .empty;
                errdefer args.deinit(arena_alloc);
                try args.append(arena_alloc, try current.clone(arena_alloc));
                var j: usize = 1;
                while (j < step.list_val.items.len) : (j += 1) {
                    try args.append(arena_alloc, try eval.evalRec(allocator, arena_alloc, step.list_val.items[j], env, depth));
                }
                const next_val = try eval.call(allocator, arena_alloc, op, args, env, depth);
                current.deinit(arena_alloc);
                current = next_val;
            } else {
                var new_call: list.List = .empty;
                errdefer new_call.deinit(arena_alloc);
                try new_call.append(arena_alloc, try step.clone(arena_alloc));
                try new_call.append(arena_alloc, try current.clone(arena_alloc));
                const next_val = try eval.evalRec(allocator, arena_alloc, Value.listValue(new_call), env, depth);
                current.deinit(arena_alloc);
                current = next_val;
            }
        }
        test_val_form.deinit(arena_alloc);
    }
    return current;
}

// cond->> - thread-last with conditions
// (cond->> expr test1 step1 test2 step2 ...)
pub fn evalCondThreadLast(allocator: Allocator, arena_alloc: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    var current = try eval.evalRec(allocator, arena_alloc, forms[0], env, depth);

    var i: usize = 1;
    while (i + 1 < forms.len) : (i += 2) {
        var test_val_form = try eval.evalRec(allocator, arena_alloc, forms[i], env, depth);
        if (test_val_form.isTruthy()) {
            const step = forms[i + 1];
            if (step.type == .list and step.list_val.items.len > 0) {
                // Evaluate operator and args, then call with current as last arg
                var op = try eval.evalRec(allocator, arena_alloc, step.list_val.items[0], env, depth);
                defer op.deinit(arena_alloc);
                var args: list.List = .empty;
                errdefer args.deinit(arena_alloc);
                var j: usize = 1;
                while (j < step.list_val.items.len) : (j += 1) {
                    try args.append(arena_alloc, try eval.evalRec(allocator, arena_alloc, step.list_val.items[j], env, depth));
                }
                try args.append(arena_alloc, try current.clone(arena_alloc));
                const next_val = try eval.call(allocator, arena_alloc, op, args, env, depth);
                current.deinit(arena_alloc);
                current = next_val;
            } else {
                var new_call: list.List = .empty;
                errdefer new_call.deinit(arena_alloc);
                try new_call.append(arena_alloc, try step.clone(arena_alloc));
                try new_call.append(arena_alloc, try current.clone(arena_alloc));
                const next_val = try eval.evalRec(allocator, arena_alloc, Value.listValue(new_call), env, depth);
                current.deinit(arena_alloc);
                current = next_val;
            }
        }
        test_val_form.deinit(arena_alloc);
    }
    return current;
}
