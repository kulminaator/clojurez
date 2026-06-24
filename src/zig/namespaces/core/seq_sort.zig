// Sequence sorting, grouping, and transformation operations:
// sort, sort-by, reductions, map-indexed, keep-indexed, bounded-count,
// group-by, distinct, replace
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;
const helpers = @import("helpers.zig");
const eval_helpers = @import("eval_helpers.zig");
const seq_ops = @import("seq_ops.zig");

const Allocator = std.mem.Allocator;

const toInt = helpers.toInt;

// sort: returns a sorted sequence of the items in coll
// Uses a simple insertion sort (fine for small collections)
pub fn core_sort(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    const coll = args.items[0];

    // Force to a list
    var items = try seq_ops.forceToConcreteList(allocator, coll);
    defer items.deinit(allocator);

    // Clone items for sorting
    var sorted: []Value = try allocator.alloc(Value, items.items.len);
    var i: usize = 0;
    while (i < items.items.len) : (i += 1) {
        sorted[i] = try items.items[i].clone(allocator);
    }

    // Insertion sort using compare
    var j: usize = 1;
    while (j < sorted.len) : (j += 1) {
        const key = sorted[j];
        var k: usize = j;
        while (k > 0 and sorted[k - 1].compare(key) > 0) {
            sorted[k] = sorted[k - 1];
            k -= 1;
        }
        sorted[k] = key;
    }

    // Build result list
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    i = 0;
    while (i < sorted.len) : (i += 1) {
        try result.append(allocator, sorted[i]);
    }
    allocator.free(sorted);
    return vm.listValue(result);
}

// sort-by: returns a sorted sequence of coll, sorted by the comparison of (keyfn item)
pub fn core_sort_by(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const keyfn = args.items[0];
    const coll = args.items[1];

    // Force to a list
    var items = try seq_ops.forceToConcreteList(allocator, coll);
    defer items.deinit(allocator);

    // Pre-compute keys for each item
    var keys: []Value = try allocator.alloc(Value, items.items.len);
    var sorted: []Value = try allocator.alloc(Value, items.items.len);
    var i: usize = 0;
    while (i < items.items.len) : (i += 1) {
        sorted[i] = try items.items[i].clone(allocator);
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, try items.items[i].clone(allocator));
        const key_ptr = try eval_helpers.callBuiltin(allocator, &keyfn, &arg_list, env_env);
        keys[i] = key_ptr.*;
        allocator.destroy(key_ptr);
    }

    // Insertion sort using key comparison
    var j: usize = 1;
    while (j < sorted.len) : (j += 1) {
        const key_item = sorted[j];
        const key_val = keys[j];
        var k: usize = j;
        while (k > 0 and keys[k - 1].compare(key_val) > 0) {
            sorted[k] = sorted[k - 1];
            keys[k] = keys[k - 1];
            k -= 1;
        }
        sorted[k] = key_item;
        keys[k] = key_val;
    }

    // Build result list
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    i = 0;
    while (i < sorted.len) : (i += 1) {
        try result.append(allocator, sorted[i]);
    }
    allocator.free(sorted);
    allocator.free(keys);
    return vm.listValue(result);
}

// reductions: return all intermediate reduce results
pub fn core_reductions(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2 and args.items.len != 3) return error.ArityError;

    const f = args.items[0];
    var init_val: Value = undefined;
    var coll: Value = undefined;
    var start_idx: usize = 0;

    if (args.items.len == 3) {
        init_val = try args.items[1].clone(allocator);
        coll = args.items[2];
        start_idx = 0;
    } else {
        // 2-arg form: (reductions f coll)
        coll = args.items[1];
        // First get the items to check if collection is empty
        var tmp_items: []const Value = undefined;
        switch (std.meta.activeTag(coll)) {
            .list => tmp_items = coll.list_val.items,
            .vector => tmp_items = coll.vec_val.items,
            else => return error.TypeError,
        }
        if (tmp_items.len == 0) {
            // Empty collection: start with (f)
            const empty_args: list.List = .empty;
            const init_ptr = try eval_helpers.callBuiltin(allocator, &f, &empty_args, env_env);
            init_val = init_ptr.*;
            allocator.destroy(init_ptr);
        } else {
            // Non-empty: start with first element
            init_val = try tmp_items[0].clone(allocator);
            start_idx = 1;
        }
    }

    // Force collection to list
    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => { init_val.deinit(allocator); return error.TypeError; }
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    try result.append(allocator, init_val);

    var acc = init_val;
    var i: usize = start_idx;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, try acc.clone(allocator));
        try arg_list.append(allocator, try items[i].clone(allocator));
        const new_acc_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        const new_acc = new_acc_ptr.*;
        allocator.destroy(new_acc_ptr);
        acc.deinit(allocator);
        acc = new_acc;
        try result.append(allocator, acc);
        acc = try acc.clone(allocator);
    }
    acc.deinit(allocator);
    return vm.listValue(result);
}

// map-indexed: map with index
pub fn core_map_indexed(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, vm.intValue(@as(i64, @intCast(i))));
        try arg_list.append(allocator, try items[i].clone(allocator));
        const mapped_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        const mapped = mapped_ptr.*;
        allocator.destroy(mapped_ptr);
        try result.append(allocator, mapped);
    }
    return vm.listValue(result);
}

// keep-indexed: keep with index
pub fn core_keep_indexed(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, vm.intValue(@as(i64, @intCast(i))));
        try arg_list.append(allocator, try items[i].clone(allocator));
        const kept_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        const kept = kept_ptr.*;
        if (std.meta.activeTag(kept) != .nil) {
            try result.append(allocator, try kept.clone(allocator));
        }
        kept_ptr.*.deinit(allocator);
        allocator.destroy(kept_ptr);
    }
    return vm.listValue(result);
}

// bounded-count: count with upper bound
pub fn core_bounded_count(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const n = try toInt(args.items[0]);
    const coll = args.items[1];

    // For collections with known count, just return it
    switch (std.meta.activeTag(coll)) {
        .list, .vector, .map, .set, .queue => {
            const c: usize = switch (std.meta.activeTag(coll)) {
                .list => coll.list_val.items.len,
                .vector => coll.vec_val.items.len,
                .map => coll.map_val.items.len,
                .set => coll.set_val.items.len,
                .queue => coll.queue_val.items.len,
                else => unreachable,
            };
            if (c <= @as(usize, @intCast(n))) return vm.intValue(@as(i64, @intCast(c)));
            return vm.intValue(n);
        },
        else => return error.TypeError,
    }
}

// group-by: group by key function
pub fn core_group_by(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    // Build result map
    var result_map: vm.Map = .empty;
    errdefer result_map.deinit(allocator);

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, try item.clone(allocator));
        const key_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        var key = key_ptr.*;
        defer { key_ptr.*.deinit(allocator); allocator.destroy(key_ptr); }

        // Find existing group or create new one
        var found_idx: ?usize = null;
        var g: usize = 0;
        while (g < result_map.items.len) : (g += 1) {
            if (result_map.items[g].key.equals(key)) {
                found_idx = g;
                break;
            }
        }

        if (found_idx) |idx| {
            // Append to existing vector
            const vec_val = result_map.items[idx].value;
            if (std.meta.activeTag(vec_val) == .vector) {
                var new_vec: vec.Vector = .empty;
                errdefer new_vec.deinit(allocator);
                for (vec_val.vec_val.items) |vitem| {
                    try new_vec.append(allocator, try vitem.clone(allocator));
                }
                try new_vec.append(allocator, try item.clone(allocator));
                result_map.items[idx].value.deinit(allocator);
                result_map.items[idx].value = vm.vectorValue(new_vec);
            }
        } else {
            // Create new group
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            try new_vec.append(allocator, try item.clone(allocator));
            try result_map.append(allocator, .{
                .key = try key.clone(allocator),
                .value = vm.vectorValue(new_vec),
            });
        }
    }
    return vm.mapValue(result_map);
}

// distinct: return distinct elements
pub fn core_distinct(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var seen: vm.Set = .empty;
    errdefer seen.deinit(allocator);
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    for (items) |item| {
        var found = false;
        for (seen.items) |s| {
            if (item.equals(s)) { found = true; break; }
        }
        if (!found) {
            try seen.append(allocator, try item.clone(allocator));
            try result.append(allocator, try item.clone(allocator));
        }
    }
    return vm.listValue(result);
}

// replace: replace values using map
pub fn core_replace(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    const smap = args.items[0];
    if (std.meta.activeTag(smap) != .map) return error.TypeError;
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    for (items) |item| {
        var replaced = false;
        for (smap.map_val.items) |entry| {
            if (item.equals(entry.key)) {
                try result.append(allocator, try entry.value.clone(allocator));
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try result.append(allocator, try item.clone(allocator));
        }
    }
    return vm.listValue(result);
}



pub fn registerSeqSortFunctions(env: *Env) anyerror!void {
    try env.put("sort", vm.builtinFnValue(core_sort));
    try env.put("sort-by", vm.builtinFnValue(core_sort_by));
    try env.put("reductions", vm.builtinFnValue(core_reductions));
    try env.put("map-indexed", vm.builtinFnValue(core_map_indexed));
    try env.put("keep-indexed", vm.builtinFnValue(core_keep_indexed));
    try env.put("bounded-count", vm.builtinFnValue(core_bounded_count));
    try env.put("group-by", vm.builtinFnValue(core_group_by));
    try env.put("distinct", vm.builtinFnValue(core_distinct));
    try env.put("replace", vm.builtinFnValue(core_replace));
}
