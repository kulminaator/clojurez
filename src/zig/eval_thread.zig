// Threading macro implementations: ->, ->>, cond->, cond->>
const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const Env = Value.Env;
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

// Thread-last macro: (->> x (f 1) (g 2 3)) => (g 2 3 (f 1 x))
// Inserts value as the LAST argument
pub fn evalThreadLast(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    const first_ptr = try eval.evalRec(allocator, forms[0], env, depth);
    var current = first_ptr.*;

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = &forms[i];

        // Handle non-list forms: (->> x inc) => (inc x)
        if (form.type != .list) {
            var new_call: list.List = .empty;
            errdefer new_call.deinit(allocator);
            try new_call.append(allocator, try form.clone(allocator));
            try new_call.append(allocator, try current.clone(allocator));
            const next_ptr = try eval.evalRec(allocator, Value.listValue(new_call), env, depth);
            current.deinit(allocator);
            current = next_ptr.*;
            continue;
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

        const next_ptr = try eval.evalRec(allocator, Value.listValue(new_call), env, depth);
        current.deinit(allocator);
        current = next_ptr.*;
    }
    return current;
}

// Thread-first macro: (-> x (f 1) (g 2 3)) => (g (f 1 x) 2 3)
pub fn evalThreadFirst(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    const first_ptr = try eval.evalRec(allocator, forms[0], env, depth);
    var current = first_ptr.*;

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = &forms[i];

        // Handle non-list forms: (-> x inc) => (inc x)
        if (form.type != .list) {
            var new_call: list.List = .empty;
            errdefer new_call.deinit(allocator);
            try new_call.append(allocator, try form.clone(allocator));
            try new_call.append(allocator, try current.clone(allocator));
            const next_ptr = try eval.evalRec(allocator, Value.listValue(new_call), env, depth);
            current.deinit(allocator);
            current = next_ptr.*;
            continue;
        }

        if (form.list_val.items.len == 0) {
            current.deinit(allocator);
            return error.ArityError;
        }

        // Build a new list: (op current arg3 ...)
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

        const next_ptr = try eval.evalRec(allocator, Value.listValue(new_call), env, depth);
        current.deinit(allocator);
        current = next_ptr.*;
    }
    return current;
}

// cond-> - thread-first with conditions
// (cond-> expr test1 step1 test2 step2 ...)
pub fn evalCondThreadFirst(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    const first_ptr = try eval.evalRec(allocator, forms[0], env, depth);
    var current = first_ptr.*;

    var i: usize = 1;
    while (i + 1 < forms.len) : (i += 2) {
        const test_ptr = try eval.evalRec(allocator, forms[i], env, depth);
        if (test_ptr.isTruthy()) {
            const step = &forms[i + 1];
            if (step.type == .list and step.list_val.items.len > 0) {
                // Evaluate operator and args, inserting current as second arg
                const op_ptr = try eval.evalRec(allocator, step.list_val.items[0], env, depth);
                defer op_ptr.*.deinit(allocator);
                var args: list.List = .empty;
                errdefer args.deinit(allocator);
                try args.append(allocator, try current.clone(allocator));
                var j: usize = 1;
                while (j < step.list_val.items.len) : (j += 1) {
                    const arg_ptr = try eval.evalRec(allocator, step.list_val.items[j], env, depth);
                    try args.append(allocator, arg_ptr.*);
                }
                const next = try eval.call(allocator, op_ptr, &args, env, depth);
                current.deinit(allocator);
                current = next;
            } else {
                var new_call: list.List = .empty;
                errdefer new_call.deinit(allocator);
                try new_call.append(allocator, try step.clone(allocator));
                try new_call.append(allocator, try current.clone(allocator));
                const next_ptr = try eval.evalRec(allocator, Value.listValue(new_call), env, depth);
                current.deinit(allocator);
                current = next_ptr.*;
            }
        }
        test_ptr.*.deinit(allocator);
    }
    return current;
}

// cond->> - thread-last with conditions
// (cond->> expr test1 step1 test2 step2 ...)
pub fn evalCondThreadLast(allocator: Allocator, forms: []const Value, env: *Env, depth: usize) anyerror!Value {
    if (forms.len == 0) return Value.nilValue();

    const first_ptr = try eval.evalRec(allocator, forms[0], env, depth);
    var current = first_ptr.*;

    var i: usize = 1;
    while (i + 1 < forms.len) : (i += 2) {
        const test_ptr = try eval.evalRec(allocator, forms[i], env, depth);
        if (test_ptr.isTruthy()) {
            const step = &forms[i + 1];
            if (step.type == .list and step.list_val.items.len > 0) {
                // Evaluate operator and args, then call with current as last arg
                const op_ptr = try eval.evalRec(allocator, step.list_val.items[0], env, depth);
                defer op_ptr.*.deinit(allocator);
                var args: list.List = .empty;
                errdefer args.deinit(allocator);
                var j: usize = 1;
                while (j < step.list_val.items.len) : (j += 1) {
                    const arg_ptr = try eval.evalRec(allocator, step.list_val.items[j], env, depth);
                    try args.append(allocator, arg_ptr.*);
                }
                try args.append(allocator, try current.clone(allocator));
                const next = try eval.call(allocator, op_ptr, &args, env, depth);
                current.deinit(allocator);
                current = next;
            } else {
                var new_call: list.List = .empty;
                errdefer new_call.deinit(allocator);
                try new_call.append(allocator, try step.clone(allocator));
                try new_call.append(allocator, try current.clone(allocator));
                const next_ptr = try eval.evalRec(allocator, Value.listValue(new_call), env, depth);
                current.deinit(allocator);
                current = next_ptr.*;
            }
        }
        test_ptr.*.deinit(allocator);
    }
    return current;
}
