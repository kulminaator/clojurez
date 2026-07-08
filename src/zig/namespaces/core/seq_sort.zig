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
    if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
    const allocator = env_env.allocator;

    const has_comparator = args.items.len == 2;
    const comparator = if (has_comparator) args.items[0] else null;
    const coll = if (has_comparator) args.items[1] else args.items[0];

    // Force to a list
    var items = try seq_ops.forceToConcreteList(allocator, coll);
    defer items.deinit(allocator);

    // Clone items for sorting
    var sorted: []Value = try allocator.alloc(Value, items.items.len);
    var i: usize = 0;
    while (i < items.items.len) : (i += 1) {
        sorted[i] = try vm.shallowClone(&items.items[i], allocator);
    }

    // Insertion sort
    var j: usize = 1;
    while (j < sorted.len) : (j += 1) {
        const key = sorted[j];
        var k: usize = j;
        while (k > 0) : (k -= 1) {
            const cmp_result = if (has_comparator)
                try sortCallComparator(allocator, &comparator.?, &sorted[k - 1], &key, env_env)
            else
                vm.compare(sorted[k - 1], key);
            if (cmp_result <= 0) break;
            sorted[k] = sorted[k - 1];
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
    return try vm.listValue(allocator, result);
}

// Helper: call a user comparator function with two args, return i64 result.
// Handles both numeric comparators (like compare) returning <0/0/>0
// and boolean predicates (like >, <) returning true/false.
fn sortCallComparator(
    allocator: Allocator,
    comp_fn: *const Value,
    a: *const Value,
    b: *const Value,
    env: *Env,
) anyerror!i64 {
    var arg_list: list.List = .empty;
    defer arg_list.deinit(allocator);
    try arg_list.append(allocator, try vm.shallowClone(a, allocator));
    try arg_list.append(allocator, try vm.shallowClone(b, allocator));
    const result_ptr = try eval_helpers.callBuiltin(allocator, comp_fn, &arg_list, env);
    defer allocator.destroy(result_ptr);

    // If result is boolean, wrap like JVM Clojure's comparator:
    // (pred a b) -> -1, (pred b a) -> 1, else 0
    if (std.meta.activeTag(result_ptr.*) == .bool) {
        if (result_ptr.bool) return -1;
        // Check reverse: (pred b a)
        var rev_list: list.List = .empty;
        defer rev_list.deinit(allocator);
        try rev_list.append(allocator, try vm.shallowClone(b, allocator));
        try rev_list.append(allocator, try vm.shallowClone(a, allocator));
        const rev_ptr = try eval_helpers.callBuiltin(allocator, comp_fn, &rev_list, env);
        defer allocator.destroy(rev_ptr);
        if (std.meta.activeTag(rev_ptr.*) == .bool and rev_ptr.bool) return 1;
        return 0;
    }
    return toInt(result_ptr.*);
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
        sorted[i] = try vm.shallowClone(&items.items[i], allocator);
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, try vm.shallowClone(&items.items[i], allocator));
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
        while (k > 0 and vm.compare(keys[k - 1], key_val) > 0) {
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
    return try vm.listValue(allocator, result);
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
        init_val = try vm.shallowClone(&args.items[1], allocator);
        coll = args.items[2];
        start_idx = 0;
    } else {
        // 2-arg form: (reductions f coll)
        coll = args.items[1];
        // First get the items to check if collection is empty
        var tmp_items: []const Value = undefined;
        switch (std.meta.activeTag(coll)) {
            .list => tmp_items = coll.list.items.items,
            .vector => tmp_items = coll.vector.items.items,
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
            init_val = try vm.shallowClone(&tmp_items[0], allocator);
            start_idx = 1;
        }
    }

    // Force collection to list
    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => { vm.valueDeinit(&init_val, allocator); return error.TypeError; }
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    try result.append(allocator, init_val);

    var acc = init_val;
    var i: usize = start_idx;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, try vm.shallowClone(&acc, allocator));
        try arg_list.append(allocator, try vm.shallowClone(&items[i], allocator));
        const new_acc_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        const new_acc = new_acc_ptr.*;
        allocator.destroy(new_acc_ptr);
        vm.valueDeinit(&acc, allocator);
        acc = new_acc;
        try result.append(allocator, acc);
        acc = try vm.shallowClone(&acc, allocator);
    }
    vm.valueDeinit(&acc, allocator);
    return try vm.listValue(allocator, result);
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
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, vm.intValue(@as(i64, @intCast(i))));
        try arg_list.append(allocator, try vm.shallowClone(&items[i], allocator));
        const mapped_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        const mapped = mapped_ptr.*;
        allocator.destroy(mapped_ptr);
        try result.append(allocator, mapped);
    }
    return try vm.listValue(allocator, result);
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
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, vm.intValue(@as(i64, @intCast(i))));
        try arg_list.append(allocator, try vm.shallowClone(&items[i], allocator));
        const kept_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        const kept = kept_ptr.*;
        if (std.meta.activeTag(kept) != .nil) {
            try result.append(allocator, try vm.shallowClone(&kept, allocator));
        }
        vm.valueDeinit(&kept_ptr.*, allocator);
        allocator.destroy(kept_ptr);
    }
    return try vm.listValue(allocator, result);
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
                .list => coll.list.items.items.len,
                .vector => coll.vector.items.items.len,
                .map => coll.map.entries.items.len,
                .set => coll.set.items.items.len,
                .queue => coll.queue.items.items.len,
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
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    // Build result map
    var result_map: vm.Map = .empty;
    errdefer {
        for (result_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(result_map.items);
    }

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(allocator);
        try arg_list.append(allocator, try vm.shallowClone(&item, allocator));
        const key_ptr = try eval_helpers.callBuiltin(allocator, &f, &arg_list, env_env);
        var key = key_ptr.*;
        defer { vm.valueDeinit(&key_ptr.*, allocator); allocator.destroy(key_ptr); }

        // Find existing group or create new one
        var found_idx: ?usize = null;
        var g: usize = 0;
        while (g < result_map.items.len) : (g += 1) {
            if (vm.equals(result_map.items[g].key, key)) {
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
                for (vec_val.vector.items.items) |vitem| {
                    try new_vec.append(allocator, try vm.shallowClone(&vitem, allocator));
                }
                try new_vec.append(allocator, try vm.shallowClone(&item, allocator));
                vm.valueDeinit(&result_map.items[idx].value, allocator);
                result_map.items[idx].value = try vm.vectorValue(allocator, new_vec);
            }
        } else {
            // Create new group
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            try new_vec.append(allocator, try vm.shallowClone(&item, allocator));
            try result_map.append(allocator, .{
                .key = try vm.shallowClone(&key, allocator),
                .value = try vm.vectorValue(allocator, new_vec),
            });
        }
    }
    return try vm.mapValue(allocator, result_map);
}

// distinct: return distinct elements
pub fn core_distinct(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];

    var items: []const Value = undefined;
    switch (std.meta.activeTag(coll)) {
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    var seen: vm.Set = .empty;
    errdefer {
        for (seen.items) |*item| vm.valueDeinit(item, allocator);
        allocator.free(seen.items);
    }
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    for (items) |item| {
        var found = false;
        for (seen.items) |s| {
            if (vm.equals(item, s)) { found = true; break; }
        }
        if (!found) {
            try seen.append(allocator, try vm.shallowClone(&item, allocator));
            try result.append(allocator, try vm.shallowClone(&item, allocator));
        }
    }
    return try vm.listValue(allocator, result);
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
        .list => items = coll.list.items.items,
        .vector => items = coll.vector.items.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    for (items) |item| {
        var replaced = false;
        for (smap.map.entries.items) |entry| {
            if (vm.equals(item, entry.key)) {
                try result.append(allocator, try vm.shallowClone(&entry.value, allocator));
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try result.append(allocator, try vm.shallowClone(&item, allocator));
        }
    }
    return try vm.listValue(allocator, result);
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
