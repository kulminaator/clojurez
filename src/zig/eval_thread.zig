// Threading macro implementations: ->, ->>, cond->, cond->>
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const Env = vm.Env;
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

// Thread-last macro: (->> x (f 1) (g 2 3)) => (g 2 3 (f 1 x))
// Inserts value as the LAST argument
pub fn evalThreadLast(allocator: Allocator, forms: []const Value, env: *Env, depth: usize, ctx: ?*eval.TrampolineStack) anyerror!Value {
    if (forms.len == 0) return vm.nilValue();

    const first_ptr_r = try eval.evalRec(allocator, &forms[0], env, depth, ctx);
    const first_ptr = first_ptr_r.value;
    var current = first_ptr.*;

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = &forms[i];

        // Handle non-list forms: (->> x inc) => (inc x)
        if (std.meta.activeTag(form.*) != .list) {
            var new_call: list.List = .empty;
            errdefer new_call.deinit(allocator);
            try new_call.append(allocator, try vm.clone(form, allocator));
            try new_call.append(allocator, try vm.clone(&current, allocator));
            const call_list = try vm.listValue(allocator, new_call);
            const next_ptr_r = try eval.evalRec(allocator, &call_list, env, depth, ctx);
    const next_ptr = next_ptr_r.value;
            vm.valueDeinit(&current, allocator);
            current = next_ptr.*;
            continue;
        }

        if (form.*.list.items.items.len == 0) {
            vm.valueDeinit(&current, allocator);
            return error.ArityError;
        }

        // Build a new list: (op arg1 arg2 ... current)
        var new_call: list.List = .empty;
        errdefer new_call.deinit(allocator);

        var j: usize = 0;
        while (j < form.*.list.items.items.len) : (j += 1) {
            try new_call.append(allocator, try vm.clone(&form.*.list.items.items[j], allocator));
        }
        try new_call.append(allocator, try vm.clone(&current, allocator));

        const call_list = try vm.listValue(allocator, new_call);
        const next_ptr_r = try eval.evalRec(allocator, &call_list, env, depth, ctx);
    const next_ptr = next_ptr_r.value;
        vm.valueDeinit(&current, allocator);
        current = next_ptr.*;
    }
    return current;
}

// Thread-first macro: (-> x (f 1) (g 2 3)) => (g (f 1 x) 2 3)
pub fn evalThreadFirst(allocator: Allocator, forms: []const Value, env: *Env, depth: usize, ctx: ?*eval.TrampolineStack) anyerror!Value {
    if (forms.len == 0) return vm.nilValue();

    const first_ptr_r = try eval.evalRec(allocator, &forms[0], env, depth, ctx);
    const first_ptr = first_ptr_r.value;
    var current = first_ptr.*;

    var i: usize = 1;
    while (i < forms.len) : (i += 1) {
        const form = &forms[i];

        // Handle non-list forms: (-> x inc) => (inc x)
        if (std.meta.activeTag(form.*) != .list) {
            var new_call: list.List = .empty;
            errdefer new_call.deinit(allocator);
            try new_call.append(allocator, try vm.clone(form, allocator));
            try new_call.append(allocator, try vm.clone(&current, allocator));
            const call_list = try vm.listValue(allocator, new_call);
            const next_ptr_r = try eval.evalRec(allocator, &call_list, env, depth, ctx);
    const next_ptr = next_ptr_r.value;
            vm.valueDeinit(&current, allocator);
            current = next_ptr.*;
            continue;
        }

        if (form.*.list.items.items.len == 0) {
            vm.valueDeinit(&current, allocator);
            return error.ArityError;
        }

        // Build a new list: (op current arg3 ...)
        var new_call: list.List = .empty;
        errdefer new_call.deinit(allocator);

        try new_call.append(allocator, try vm.clone(&form.*.list.items.items[0], allocator));
        var j: usize = 1;
        while (j < form.*.list.items.items.len) : (j += 1) {
            if (j == 1) {
                try new_call.append(allocator, try vm.clone(&current, allocator));
            }
            try new_call.append(allocator, try vm.clone(&form.*.list.items.items[j], allocator));
        }

        const call_list = try vm.listValue(allocator, new_call);
        const next_ptr_r = try eval.evalRec(allocator, &call_list, env, depth, ctx);
    const next_ptr = next_ptr_r.value;
        vm.valueDeinit(&current, allocator);
        current = next_ptr.*;
    }
    return current;
}

// cond-> - thread-first with conditions
// (cond-> expr test1 step1 test2 step2 ...)
pub fn evalCondThreadFirst(allocator: Allocator, forms: []const Value, env: *Env, depth: usize, ctx: ?*eval.TrampolineStack) anyerror!Value {
    if (forms.len == 0) return vm.nilValue();

    const first_ptr_r = try eval.evalRec(allocator, &forms[0], env, depth, ctx);
    const first_ptr = first_ptr_r.value;
    var current = first_ptr.*;

    var i: usize = 1;
    while (i + 1 < forms.len) : (i += 2) {
        const test_ptr_r = try eval.evalRec(allocator, &forms[i], env, depth, ctx);
    const test_ptr = test_ptr_r.value;
        if (vm.isTruthy(test_ptr.*)) {
            const step = &forms[i + 1];
            if (std.meta.activeTag(step.*) == .list and step.*.list.items.items.len > 0) {
                // Evaluate operator and args, inserting current as second arg
                const op_ptr_r = try eval.evalRec(allocator, &step.*.list.items.items[0], env, depth, ctx);
    const op_ptr = op_ptr_r.value;
                defer vm.valueDeinit(&op_ptr.*, allocator);
                var args: list.List = .empty;
                errdefer args.deinit(allocator);
                try args.append(allocator, try vm.clone(&current, allocator));
                var j: usize = 1;
                while (j < step.*.list.items.items.len) : (j += 1) {
                    const arg_ptr_r = try eval.evalRec(allocator, &step.*.list.items.items[j], env, depth, ctx);
    const arg_ptr = arg_ptr_r.value;
                    try args.append(allocator, arg_ptr.*);
                }
                const call_result = try eval.call(allocator, op_ptr, &args, env, depth, ctx);
                const next_ptr = call_result.value;
                vm.valueDeinit(&current, allocator);
                current = next_ptr.*;
            } else {
                var new_call: list.List = .empty;
                errdefer new_call.deinit(allocator);
                try new_call.append(allocator, try vm.clone(step, allocator));
                try new_call.append(allocator, try vm.clone(&current, allocator));
                const call_list = try vm.listValue(allocator, new_call);
                const next_ptr_r = try eval.evalRec(allocator, &call_list, env, depth, ctx);
    const next_ptr = next_ptr_r.value;
                vm.valueDeinit(&current, allocator);
                current = next_ptr.*;
            }
        }
        vm.valueDeinit(&test_ptr.*, allocator);
    }
    return current;
}

// cond->> - thread-last with conditions
// (cond->> expr test1 step1 test2 step2 ...)
pub fn evalCondThreadLast(allocator: Allocator, forms: []const Value, env: *Env, depth: usize, ctx: ?*eval.TrampolineStack) anyerror!Value {
    if (forms.len == 0) return vm.nilValue();

    const first_ptr_r = try eval.evalRec(allocator, &forms[0], env, depth, ctx);
    const first_ptr = first_ptr_r.value;
    var current = first_ptr.*;

    var i: usize = 1;
    while (i + 1 < forms.len) : (i += 2) {
        const test_ptr_r = try eval.evalRec(allocator, &forms[i], env, depth, ctx);
    const test_ptr = test_ptr_r.value;
        if (vm.isTruthy(test_ptr.*)) {
            const step = &forms[i + 1];
            if (std.meta.activeTag(step.*) == .list and step.*.list.items.items.len > 0) {
                // Evaluate operator and args, then call with current as last arg
                const op_ptr_r = try eval.evalRec(allocator, &step.*.list.items.items[0], env, depth, ctx);
    const op_ptr = op_ptr_r.value;
                defer vm.valueDeinit(&op_ptr.*, allocator);
                var args: list.List = .empty;
                errdefer args.deinit(allocator);
                var j: usize = 1;
                while (j < step.*.list.items.items.len) : (j += 1) {
                    const arg_ptr_r = try eval.evalRec(allocator, &step.*.list.items.items[j], env, depth, ctx);
    const arg_ptr = arg_ptr_r.value;
                    try args.append(allocator, arg_ptr.*);
                }
                try args.append(allocator, try vm.clone(&current, allocator));
                const call_result = try eval.call(allocator, op_ptr, &args, env, depth, ctx);
                const next_ptr = call_result.value;
                vm.valueDeinit(&current, allocator);
                current = next_ptr.*;
            } else {
                var new_call: list.List = .empty;
                errdefer new_call.deinit(allocator);
                try new_call.append(allocator, try vm.clone(step, allocator));
                try new_call.append(allocator, try vm.clone(&current, allocator));
                const call_list = try vm.listValue(allocator, new_call);
                const next_ptr_r = try eval.evalRec(allocator, &call_list, env, depth, ctx);
    const next_ptr = next_ptr_r.value;
                vm.valueDeinit(&current, allocator);
                current = next_ptr.*;
            }
        }
        vm.valueDeinit(&test_ptr.*, allocator);
    }
    return current;
}
