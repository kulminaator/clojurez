// Map built-in functions: get, assoc, keys, vals, dissoc, merge, hash-map
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = Value.Env;
const test_utils = @import("test_utils.zig");

const Allocator = std.mem.Allocator;

pub fn core_get(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const val = args.items[0];
    if (val.type != .map and val.type != .record) return error.TypeError;
    if (args.items.len == 1) return Value.nilValue();
    const key = args.items[1];

    if (val.type == .record) {
        // Look up in fields map first
        for (val.record_val.?.fields.items) |entry| {
            if (entry.key.equals(key)) {
                return try entry.value.clone(env_env.allocator);
            }
        }
        // Then in extmap
        for (val.record_val.?.extmap.items) |entry| {
            if (entry.key.equals(key)) {
                return try entry.value.clone(env_env.allocator);
            }
        }
    } else {
        for (val.map_val.items) |entry| {
            if (entry.key.equals(key)) {
                return try entry.value.clone(env_env.allocator);
            }
        }
    }
    // Return default value if provided, otherwise nil
    if (args.items.len >= 3) {
        return try args.items[2].clone(env_env.allocator);
    }
    return Value.nilValue();
}

pub fn core_assoc(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 3) return error.ArityError;
    const first = args.items[0];

    // Vector assoc: (assoc vec index val & more-kvs)
    if (first.type == .vector) {
        return assocVector(first, args, env_env);
    }

    // Record assoc: (assoc record key val & more-kvs)
    if (first.type == .record) {
        return assocRecord(first, args, env_env);
    }

    // Map assoc: (assoc map key val & more-kvs)
    // If map is nil, start with an empty map (Clojure behavior)
    if (first.type == .nil) {
        return assocMap(Value.mapValue(.empty), args, env_env);
    }
    if (first.type != .map) return error.TypeError;
    return assocMap(first, args, env_env);
}

fn assocVector(orig: Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var new_vec: vec.Vector = .empty;
    errdefer {
        for (new_vec.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(new_vec.items);
    }

    // Clone the original vector
    for (orig.vec_val.items) |item| {
        try new_vec.append(allocator, try item.clone(allocator));
    }

    // Process key-value pairs: key is an integer index
    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];

        // Key must be an integer index
        if (key.type != .integer) return error.TypeError;
        const idx: usize = @intCast(key.int_val);
        if (key.int_val < 0) return error.TypeError;
        if (idx > new_vec.items.len) return error.TypeError;

        // Grow vector if index == count (append)
        if (idx == new_vec.items.len) {
            try new_vec.append(allocator, try value.clone(allocator));
        } else {
            // Replace existing element
            new_vec.items[idx].deinit(allocator);
            new_vec.items[idx] = try value.clone(allocator);
        }
    }

    return Value.vectorValue(new_vec);
}

fn assocMap(map_val: Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_map.items);
    }

    for (map_val.map_val.items) |entry| {
        try new_map.append(allocator, .{
            .key = try entry.key.clone(allocator),
            .value = try entry.value.clone(allocator),
        });
    }

    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];
        var found = false;
        var j: usize = 0;
        while (j < new_map.items.len) : (j += 1) {
            if (new_map.items[j].key.equals(key)) {
                new_map.items[j].value.deinit(allocator);
                new_map.items[j].value = try value.clone(allocator);
                found = true;
                break;
            }
        }
        if (!found) {
            try new_map.append(allocator, .{
                .key = try key.clone(allocator),
                .value = try value.clone(allocator),
            });
        }
    }

    return Value.mapValue(new_map);
}

pub fn core_keys(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const val = args.items[0];
    if (val.type != .map and val.type != .record) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    if (val.type == .record) {
        for (val.record_val.?.fields.items) |entry| {
            try result.append(env_env.allocator, try entry.key.clone(env_env.allocator));
        }
        for (val.record_val.?.extmap.items) |entry| {
            try result.append(env_env.allocator, try entry.key.clone(env_env.allocator));
        }
    } else {
        for (val.map_val.items) |entry| {
            try result.append(env_env.allocator, try entry.key.clone(env_env.allocator));
        }
    }
    return Value.listValue(result);
}

pub fn core_vals(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const val = args.items[0];
    if (val.type != .map and val.type != .record) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    if (val.type == .record) {
        for (val.record_val.?.fields.items) |entry| {
            try result.append(env_env.allocator, try entry.value.clone(env_env.allocator));
        }
        for (val.record_val.?.extmap.items) |entry| {
            try result.append(env_env.allocator, try entry.value.clone(env_env.allocator));
        }
    } else {
        for (val.map_val.items) |entry| {
            try result.append(env_env.allocator, try entry.value.clone(env_env.allocator));
        }
    }
    return Value.listValue(result);
}

pub fn core_dissoc(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const val = args.items[0];
    if (val.type != .map and val.type != .record) return error.TypeError;

    if (val.type == .record) {
        return dissocRecord(val, args, env_env);
    }

    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(env_env.allocator);
            entry.value.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_map.items);
    }

    for (val.map_val.items) |entry| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (entry.key.equals(args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_map.append(env_env.allocator, .{
                .key = try entry.key.clone(env_env.allocator),
                .value = try entry.value.clone(env_env.allocator),
            });
        }
    }
    return Value.mapValue(new_map);
}

pub fn core_hash_map(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len % 2 != 0) return error.ArityError;

    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(env_env.allocator);
            entry.value.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_map.items);
    }

    var i: usize = 0;
    while (i < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];
        var found = false;
        var j: usize = 0;
        while (j < new_map.items.len) : (j += 1) {
            if (new_map.items[j].key.equals(key)) {
                new_map.items[j].value.deinit(env_env.allocator);
                new_map.items[j].value = try value.clone(env_env.allocator);
                found = true;
                break;
            }
        }
        if (!found) {
            try new_map.append(env_env.allocator, .{
                .key = try key.clone(env_env.allocator),
                .value = try value.clone(env_env.allocator),
            });
        }
    }
    return Value.mapValue(new_map);
}

pub fn core_merge(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return Value.mapValue(.empty);

    const allocator = env_env.allocator;
    // If first arg is a record, start with record's fields as base
    var base_map: Value.Map = .empty;
    errdefer {
        for (base_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(base_map.items);
    }

    // Collect all key-value pairs from all args into base_map
    for (args.items) |arg| {
        switch (arg.type) {
            .map => {
                for (arg.map_val.items) |entry| {
                    var found = false;
                    var j: usize = 0;
                    while (j < base_map.items.len) : (j += 1) {
                        if (base_map.items[j].key.equals(entry.key)) {
                            base_map.items[j].value.deinit(allocator);
                            base_map.items[j].value = try entry.value.clone(allocator);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try base_map.append(allocator, .{
                            .key = try entry.key.clone(allocator),
                            .value = try entry.value.clone(allocator),
                        });
                    }
                }
            },
            .record => {
                for (arg.record_val.?.fields.items) |entry| {
                    var found = false;
                    var j: usize = 0;
                    while (j < base_map.items.len) : (j += 1) {
                        if (base_map.items[j].key.equals(entry.key)) {
                            base_map.items[j].value.deinit(allocator);
                            base_map.items[j].value = try entry.value.clone(allocator);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try base_map.append(allocator, .{
                            .key = try entry.key.clone(allocator),
                            .value = try entry.value.clone(allocator),
                        });
                    }
                }
                for (arg.record_val.?.extmap.items) |entry| {
                    var found = false;
                    var j: usize = 0;
                    while (j < base_map.items.len) : (j += 1) {
                        if (base_map.items[j].key.equals(entry.key)) {
                            base_map.items[j].value.deinit(allocator);
                            base_map.items[j].value = try entry.value.clone(allocator);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try base_map.append(allocator, .{
                            .key = try entry.key.clone(allocator),
                            .value = try entry.value.clone(allocator),
                        });
                    }
                }
            },
            else => continue,
        }
    }

    // If first arg was a record, try to reconstruct a record
    if (args.items[0].type == .record) {
        return mergeToRecord(args.items[0], base_map, allocator);
    }
    // Transfer ownership
    const result = base_map;
    base_map = .empty;
    return Value.mapValue(result);
}

/// Check if a key is a defined field of a record (exists in fields map).
pub fn isRecordDefinedField(record: *const Value, key: Value) bool {
    for (record.record_val.?.fields.items) |entry| {
        if (entry.key.equals(key)) return true;
    }
    return false;
}

/// Convert a record to a plain map (for dissoc of a defined field).
fn recordToMap(record: Value, allocator: Allocator) anyerror!Value {
    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_map.items);
    }
    for (record.record_val.?.fields.items) |entry| {
        try new_map.append(allocator, .{
            .key = try entry.key.clone(allocator),
            .value = try entry.value.clone(allocator),
        });
    }
    for (record.record_val.?.extmap.items) |entry| {
        try new_map.append(allocator, .{
            .key = try entry.key.clone(allocator),
            .value = try entry.value.clone(allocator),
        });
    }
    return Value.mapValue(new_map);
}

/// Assoc on a record. Returns a new record (assoc never demotes a record).
fn assocRecord(record: Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var current = record;
    defer current.deinit(allocator);

    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];
        const rd = current.record_val orelse return error.TypeError;

        if (isRecordDefinedField(&current, key)) {
            // Update field value - create new record with updated field
            var new_fields: Value.Map = .empty;
            errdefer {
                for (new_fields.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(new_fields.items);
            }
            for (rd.fields.items) |entry| {
                if (entry.key.equals(key)) {
                    try new_fields.append(allocator, .{
                        .key = try entry.key.clone(allocator),
                        .value = try value.clone(allocator),
                    });
                } else {
                    try new_fields.append(allocator, .{
                        .key = try entry.key.clone(allocator),
                        .value = try entry.value.clone(allocator),
                    });
                }
            }
            const cloned_extmap = try Value.cloneMap(allocator, rd.extmap);
            const cloned_meta = if (rd.meta) |m|
                try Value.cloneMap(allocator, m)
            else
                null;
            errdefer {
                if (cloned_meta) |cm| {
                    for (cm.items) |*entry| {
                        entry.key.deinit(allocator);
                        entry.value.deinit(allocator);
                    }
                    allocator.free(cm.items);
                }
                for (cloned_extmap.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(cloned_extmap.items);
            }
            const new_type_name = try allocator.dupe(u8, rd.type_name);
            errdefer allocator.free(new_type_name);

            current.deinit(allocator);
            current = try Value.recordValue(allocator, new_type_name, new_fields, cloned_extmap, cloned_meta);
            new_fields = .empty;
        } else {
            // Add/update in extmap - create new record with updated extmap
            var new_extmap: Value.Map = .empty;
            errdefer {
                for (new_extmap.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(new_extmap.items);
            }
            var found_in_extmap = false;
            for (rd.extmap.items) |entry| {
                if (entry.key.equals(key)) {
                    try new_extmap.append(allocator, .{
                        .key = try entry.key.clone(allocator),
                        .value = try value.clone(allocator),
                    });
                    found_in_extmap = true;
                } else {
                    try new_extmap.append(allocator, .{
                        .key = try entry.key.clone(allocator),
                        .value = try entry.value.clone(allocator),
                    });
                }
            }
            if (!found_in_extmap) {
                try new_extmap.append(allocator, .{
                    .key = try key.clone(allocator),
                    .value = try value.clone(allocator),
                });
            }
            const cloned_fields = try Value.cloneMap(allocator, rd.fields);
            const cloned_meta = if (rd.meta) |m|
                try Value.cloneMap(allocator, m)
            else
                null;
            errdefer {
                if (cloned_meta) |cm| {
                    for (cm.items) |*entry| {
                        entry.key.deinit(allocator);
                        entry.value.deinit(allocator);
                    }
                    allocator.free(cm.items);
                }
                for (cloned_fields.items) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(cloned_fields.items);
            }
            const new_type_name = try allocator.dupe(u8, rd.type_name);
            errdefer allocator.free(new_type_name);

            current.deinit(allocator);
            current = try Value.recordValue(allocator, new_type_name, cloned_fields, new_extmap, cloned_meta);
            new_extmap = .empty;
        }
    }

    const result = current;
    current = Value.nilValue();
    return result;
}

/// Dissoc on a record. If a defined field is removed, demote to plain map.
fn dissocRecord(record: Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;

    // Check if any key to dissoc is a defined field
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (isRecordDefinedField(&record, args.items[i])) {
            // Demote to plain map, then dissoc from map
            var plain_map = try recordToMap(record, allocator);
            defer plain_map.deinit(allocator);
            // Now dissoc from the plain map
            return core_dissocMap(plain_map, args, env);
        }
    }

    // All keys are in extmap - create new record with updated extmap
    var new_extmap: Value.Map = .empty;
    errdefer {
        for (new_extmap.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_extmap.items);
    }
    for (record.record_val.?.extmap.items) |entry| {
        var should_keep = true;
        var j: usize = 1;
        while (j < args.items.len) : (j += 1) {
            if (entry.key.equals(args.items[j])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_extmap.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
    }

    const cloned_fields = try Value.cloneMap(allocator, record.record_val.?.fields);
    const cloned_meta = if (record.record_val.?.meta) |m|
        try Value.cloneMap(allocator, m)
    else
        null;
    errdefer {
        if (cloned_meta) |cm| {
            for (cm.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(cm.items);
        }
        for (cloned_fields.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(cloned_fields.items);
    }
    const new_type_name = try allocator.dupe(u8, record.record_val.?.type_name);
    errdefer allocator.free(new_type_name);

    return try Value.recordValue(allocator, new_type_name, cloned_fields, new_extmap, cloned_meta);
}

/// Dissoc on a plain map (used internally by dissocRecord after demotion).
fn core_dissocMap(map_val: Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_map.items);
    }

    for (map_val.map_val.items) |entry| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (entry.key.equals(args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_map.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
    }
    return Value.mapValue(new_map);
}

/// Merge result back to a record if the first arg was a record.
/// If all keys in the merged map are defined fields, return a record.
/// Otherwise return a record with extmap for extra keys.
fn mergeToRecord(original_record: Value, merged_map: Value.Map, allocator: Allocator) anyerror!Value {
    const rd = original_record.record_val orelse return error.TypeError;

    // Build new fields map from merged_map entries that match defined fields
    var new_fields: Value.Map = .empty;
    errdefer {
        for (new_fields.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_fields.items);
    }
    var new_extmap: Value.Map = .empty;
    errdefer {
        for (new_extmap.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_extmap.items);
    }

    // First, get all defined field values from merged_map
    for (rd.fields.items) |entry| {
        // Look up in merged_map
        for (merged_map.items) |m_entry| {
            if (m_entry.key.equals(entry.key)) {
                try new_fields.append(allocator, .{
                    .key = try entry.key.clone(allocator),
                    .value = try m_entry.value.clone(allocator),
                });
                break;
            }
        }
    }

    // Then, collect any extra keys from merged_map into extmap
    for (merged_map.items) |m_entry| {
        var is_defined = false;
        for (rd.fields.items) |entry| {
            if (entry.key.equals(m_entry.key)) {
                is_defined = true;
                break;
            }
        }
        if (!is_defined) {
            try new_extmap.append(allocator, .{
                .key = try m_entry.key.clone(allocator),
                .value = try m_entry.value.clone(allocator),
            });
        }
    }

    const cloned_meta = if (rd.meta) |m|
        try Value.cloneMap(allocator, m)
    else
        null;
    errdefer {
        if (cloned_meta) |cm| {
            for (cm.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(cm.items);
        }
    }
    const new_type_name = try allocator.dupe(u8, rd.type_name);
    errdefer allocator.free(new_type_name);

    return try Value.recordValue(allocator, new_type_name, new_fields, new_extmap, cloned_meta);
}

pub fn registerMapFunctions(env: *Env) anyerror!void {
    try env.put("get", Value.builtinFnValue(core_get));
    try env.put("assoc", Value.builtinFnValue(core_assoc));
    try env.put("keys", Value.builtinFnValue(core_keys));
    try env.put("vals", Value.builtinFnValue(core_vals));
    try env.put("dissoc", Value.builtinFnValue(core_dissoc));
    try env.put("merge", Value.builtinFnValue(core_merge));
    try env.put("hash-map", Value.builtinFnValue(core_hash_map));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

fn makeMap(kvs: []const Value) Value {
    const a = std.heap.page_allocator;
    var m: Value.Map = .empty;
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        _ = m.append(a, .{ .key = kvs[i], .value = kvs[i + 1] }) catch unreachable;
    }
    return Value.mapValue(m);
}

test "maps::get: finds key" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ Value.intValue(1), Value.intValue(10), Value.intValue(2), Value.intValue(20) });
    defer m.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m, Value.intValue(1) });
    var result = core_get(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 10);
}

test "maps::get: missing key returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ Value.intValue(1), Value.intValue(10) });
    defer m.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m, Value.intValue(99) });
    var result = core_get(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .nil);
}

test "maps::keys: returns all keys" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ Value.intValue(1), Value.intValue(10), Value.intValue(2), Value.intValue(20) });
    defer m.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m });
    var result = core_keys(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 2);
}

test "maps::vals: returns all values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ Value.intValue(1), Value.intValue(10), Value.intValue(2), Value.intValue(20) });
    defer m.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m });
    var result = core_vals(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .list);
    try std.testing.expect(result.list_val.items.len == 2);
}

test "maps::merge: merges two maps" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m1 = makeMap(&[_]Value{ Value.intValue(1), Value.intValue(10) });
    defer m1.deinit(std.heap.page_allocator);
    var m2 = makeMap(&[_]Value{ Value.intValue(2), Value.intValue(20) });
    defer m2.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m1, m2 });
    var result = core_merge(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .map);
    try std.testing.expect(result.map_val.items.len == 2);
}

test "maps::merge: no args returns empty map" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_merge(testSelf(), &args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .map);
    try std.testing.expect(result.map_val.items.len == 0);
}

