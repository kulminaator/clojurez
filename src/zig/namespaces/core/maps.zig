// Map built-in functions: get, assoc, keys, vals, dissoc, merge, hash-map
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;
const test_utils = @import("test_utils.zig");

const Allocator = std.mem.Allocator;

pub fn core_get(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const val = args.items[0];
    if (std.meta.activeTag(val) != .map and std.meta.activeTag(val) != .record) return error.TypeError;
    if (args.items.len == 1) return vm.nilValue();
    const key = args.items[1];

    if (std.meta.activeTag(val) == .record) {
        // Look up in fields map first
        for (val.record.fields.items) |entry| {
            if (vm.equals(entry.key, key)) {
                return try vm.shallowClone(&entry.value, env_env.allocator);
            }
        }
        // Then in extmap
        for (val.record.extmap.items) |entry| {
            if (vm.equals(entry.key, key)) {
                return try vm.shallowClone(&entry.value, env_env.allocator);
            }
        }
    } else {
        for (val.map.entries.items) |entry| {
            if (vm.equals(entry.key, key)) {
                return try vm.shallowClone(&entry.value, env_env.allocator);
            }
        }
    }
    // Return default value if provided, otherwise nil
    if (args.items.len >= 3) {
        return try vm.shallowClone(&args.items[2], env_env.allocator);
    }
    return vm.nilValue();
}

pub fn core_assoc(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 3) return error.ArityError;
    const first = args.items[0];

    // Vector assoc: (assoc vec index val & more-kvs)
    if (std.meta.activeTag(first) == .vector) {
        return assocVector(&first, args, env_env);
    }

    // Record assoc: (assoc record key val & more-kvs)
    if (std.meta.activeTag(first) == .record) {
        return assocRecord(&first, args, env_env);
    }

    // Map assoc: (assoc map key val & more-kvs)
    // If map is nil, start with an empty map (Clojure behavior)
    if (std.meta.activeTag(first) == .nil) {
        const empty_map = try vm.mapValue(env_env.allocator, .empty);
        return assocMap(&empty_map, args, env_env);
    }
    if (std.meta.activeTag(first) != .map) return error.TypeError;
    return assocMap(&first, args, env_env);
}

fn assocVector(orig: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var new_vec: vec.Vector = .empty;
    errdefer {
        for (new_vec.items) |*item| {
            vm.valueDeinit(item, allocator);
        }
        allocator.free(new_vec.items);
    }

    // Clone the original vector
    for (orig.vector.items.items) |item| {
        try new_vec.append(allocator, try vm.shallowClone(&item, allocator));
    }

    // Process key-value pairs: key is an integer index
    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];

        // Key must be an integer index
        if (std.meta.activeTag(key) != .integer) return error.TypeError;
        const idx: usize = @intCast(key.integer);
        if (key.integer < 0) return error.TypeError;
        if (idx > new_vec.items.len) return error.TypeError;

        // Grow vector if index == count (append)
        if (idx == new_vec.items.len) {
            try new_vec.append(allocator, try vm.shallowClone(&value, allocator));
        } else {
            // Replace existing element
            vm.valueDeinit(&new_vec.items[idx], allocator);
            new_vec.items[idx] = try vm.shallowClone(&value, allocator);
        }
    }

    return try vm.vectorValue(allocator, new_vec);
}

fn assocMap(map_val: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_map.items);
    }

    for (map_val.map.entries.items) |entry| {
        try new_map.append(allocator, .{
            .key = try vm.shallowClone(&entry.key, allocator),
            .value = try vm.shallowClone(&entry.value, allocator),
        });
    }

    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];
        var found = false;
        var j: usize = 0;
        while (j < new_map.items.len) : (j += 1) {
            if (vm.equals(new_map.items[j].key, key)) {
                vm.valueDeinit(&new_map.items[j].value, allocator);
                new_map.items[j].value = try vm.shallowClone(&value, allocator);
                found = true;
                break;
            }
        }
        if (!found) {
            try new_map.append(allocator, .{
                .key = try vm.shallowClone(&key, allocator),
                .value = try vm.shallowClone(&value, allocator),
            });
        }
    }

    return try vm.mapValue(allocator, new_map);
}

pub fn core_keys(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const val = args.items[0];
    if (std.meta.activeTag(val) != .map and std.meta.activeTag(val) != .record) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    if (std.meta.activeTag(val) == .record) {
        for (val.record.fields.items) |entry| {
            try result.append(env_env.allocator, try vm.shallowClone(&entry.key, env_env.allocator));
        }
        for (val.record.extmap.items) |entry| {
            try result.append(env_env.allocator, try vm.shallowClone(&entry.key, env_env.allocator));
        }
    } else {
        for (val.map.entries.items) |entry| {
            try result.append(env_env.allocator, try vm.shallowClone(&entry.key, env_env.allocator));
        }
    }
    return try vm.listValue(env_env.allocator, result);
}

pub fn core_vals(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const val = args.items[0];
    if (std.meta.activeTag(val) != .map and std.meta.activeTag(val) != .record) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    if (std.meta.activeTag(val) == .record) {
        for (val.record.fields.items) |entry| {
            try result.append(env_env.allocator, try vm.shallowClone(&entry.value, env_env.allocator));
        }
        for (val.record.extmap.items) |entry| {
            try result.append(env_env.allocator, try vm.shallowClone(&entry.value, env_env.allocator));
        }
    } else {
        for (val.map.entries.items) |entry| {
            try result.append(env_env.allocator, try vm.shallowClone(&entry.value, env_env.allocator));
        }
    }
    return try vm.listValue(env_env.allocator, result);
}

pub fn core_dissoc(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const val = args.items[0];
    if (std.meta.activeTag(val) != .map and std.meta.activeTag(val) != .record) return error.TypeError;

    if (std.meta.activeTag(val) == .record) {
        return dissocRecord(&val, args, env_env);
    }

    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, env_env.allocator);
            vm.valueDeinit(&entry.value, env_env.allocator);
        }
        env_env.allocator.free(new_map.items);
    }

    for (val.map.entries.items) |entry| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (vm.equals(entry.key, args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_map.append(env_env.allocator, .{
                .key = try vm.shallowClone(&entry.key, env_env.allocator),
                .value = try vm.shallowClone(&entry.value, env_env.allocator),
            });
        }
    }
    return try vm.mapValue(env_env.allocator, new_map);
}

pub fn core_hash_map(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len % 2 != 0) return error.ArityError;

    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, env_env.allocator);
            vm.valueDeinit(&entry.value, env_env.allocator);
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
            if (vm.equals(new_map.items[j].key, key)) {
                vm.valueDeinit(&new_map.items[j].value, env_env.allocator);
                new_map.items[j].value = try vm.shallowClone(&value, env_env.allocator);
                found = true;
                break;
            }
        }
        if (!found) {
            try new_map.append(env_env.allocator, .{
                .key = try vm.shallowClone(&key, env_env.allocator),
                .value = try vm.shallowClone(&value, env_env.allocator),
            });
        }
    }
    return try vm.mapValue(env_env.allocator, new_map);
}

pub fn core_merge(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return try vm.mapValue(env_env.allocator, .empty);

    const allocator = env_env.allocator;
    // If first arg is a record, start with record's fields as base
    var base_map: vm.Map = .empty;
    errdefer {
        for (base_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(base_map.items);
    }

    // Collect all key-value pairs from all args into base_map
    for (args.items) |arg| {
        switch (std.meta.activeTag(arg)) {
            .map => {
                for (arg.map.entries.items) |entry| {
                    var found = false;
                    var j: usize = 0;
                    while (j < base_map.items.len) : (j += 1) {
                        if (vm.equals(base_map.items[j].key, entry.key)) {
                            vm.valueDeinit(&base_map.items[j].value, allocator);
                            base_map.items[j].value = try vm.shallowClone(&entry.value, allocator);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try base_map.append(allocator, .{
                            .key = try vm.shallowClone(&entry.key, allocator),
                            .value = try vm.shallowClone(&entry.value, allocator),
                        });
                    }
                }
            },
            .record => {
                for (arg.record.fields.items) |entry| {
                    var found = false;
                    var j: usize = 0;
                    while (j < base_map.items.len) : (j += 1) {
                        if (vm.equals(base_map.items[j].key, entry.key)) {
                            vm.valueDeinit(&base_map.items[j].value, allocator);
                            base_map.items[j].value = try vm.shallowClone(&entry.value, allocator);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try base_map.append(allocator, .{
                            .key = try vm.shallowClone(&entry.key, allocator),
                            .value = try vm.shallowClone(&entry.value, allocator),
                        });
                    }
                }
                for (arg.record.extmap.items) |entry| {
                    var found = false;
                    var j: usize = 0;
                    while (j < base_map.items.len) : (j += 1) {
                        if (vm.equals(base_map.items[j].key, entry.key)) {
                            vm.valueDeinit(&base_map.items[j].value, allocator);
                            base_map.items[j].value = try vm.shallowClone(&entry.value, allocator);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try base_map.append(allocator, .{
                            .key = try vm.shallowClone(&entry.key, allocator),
                            .value = try vm.shallowClone(&entry.value, allocator),
                        });
                    }
                }
            },
            else => continue,
        }
    }

    // If first arg was a record, try to reconstruct a record
    if (std.meta.activeTag(args.items[0]) == .record) {
        return mergeToRecord(&args.items[0], base_map, allocator);
    }
    // Transfer ownership
    const result = base_map;
    base_map = .empty;
    return try vm.mapValue(allocator, result);
}

/// Check if a key is a defined field of a record (exists in fields map).
pub fn isRecordDefinedField(record: *const Value, key: Value) bool {
    for (record.record.fields.items) |entry| {
        if (vm.equals(entry.key, key)) return true;
    }
    return false;
}

/// Convert a record to a plain map (for dissoc of a defined field).
fn recordToMap(record: *const Value, allocator: Allocator) anyerror!Value {
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_map.items);
    }
    for (record.record.fields.items) |entry| {
        try new_map.append(allocator, .{
            .key = try vm.shallowClone(&entry.key, allocator),
            .value = try vm.shallowClone(&entry.value, allocator),
        });
    }
    for (record.record.extmap.items) |entry| {
        try new_map.append(allocator, .{
            .key = try vm.shallowClone(&entry.key, allocator),
            .value = try vm.shallowClone(&entry.value, allocator),
        });
    }
    return try vm.mapValue(allocator, new_map);
}

/// Assoc on a record. Returns a new record (assoc never demotes a record).
fn assocRecord(record: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var current = try vm.shallowClone(record, allocator);
    defer vm.valueDeinit(&current, allocator);

    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];
        const rd = current.record;

        if (isRecordDefinedField(&current, key)) {
            // Update field value - create new record with updated field
            var new_fields: vm.Map = .empty;
            errdefer {
                for (new_fields.items) |*entry| {
                    vm.valueDeinit(&entry.key, allocator);
                    vm.valueDeinit(&entry.value, allocator);
                }
                allocator.free(new_fields.items);
            }
            for (rd.fields.items) |entry| {
                if (vm.equals(entry.key, key)) {
                    try new_fields.append(allocator, .{
                        .key = try vm.shallowClone(&entry.key, allocator),
                        .value = try vm.shallowClone(&value, allocator),
                    });
                } else {
                    try new_fields.append(allocator, .{
                        .key = try vm.shallowClone(&entry.key, allocator),
                        .value = try vm.shallowClone(&entry.value, allocator),
                    });
                }
            }
            const cloned_extmap = try vm.cloneMap(allocator, rd.extmap);
            const cloned_meta = if (rd.meta) |m|
                try vm.cloneMap(allocator, m)
            else
                null;
            errdefer {
                if (cloned_meta) |cm| {
                    for (cm.items) |*entry| {
                        vm.valueDeinit(&entry.key, allocator);
                        vm.valueDeinit(&entry.value, allocator);
                    }
                    allocator.free(cm.items);
                }
                for (cloned_extmap.items) |*entry| {
                    vm.valueDeinit(&entry.key, allocator);
                    vm.valueDeinit(&entry.value, allocator);
                }
                allocator.free(cloned_extmap.items);
            }
            const new_type_name = try allocator.dupe(u8, rd.type_name);
            errdefer allocator.free(new_type_name);

            vm.valueDeinit(&current, allocator);
            current = try vm.recordValue(allocator, new_type_name, new_fields, cloned_extmap, cloned_meta);
            new_fields = .empty;
        } else {
            // Add/update in extmap - create new record with updated extmap
            var new_extmap: vm.Map = .empty;
            errdefer {
                for (new_extmap.items) |*entry| {
                    vm.valueDeinit(&entry.key, allocator);
                    vm.valueDeinit(&entry.value, allocator);
                }
                allocator.free(new_extmap.items);
            }
            var found_in_extmap = false;
            for (rd.extmap.items) |entry| {
                if (vm.equals(entry.key, key)) {
                    try new_extmap.append(allocator, .{
                        .key = try vm.shallowClone(&entry.key, allocator),
                        .value = try vm.shallowClone(&value, allocator),
                    });
                    found_in_extmap = true;
                } else {
                    try new_extmap.append(allocator, .{
                        .key = try vm.shallowClone(&entry.key, allocator),
                        .value = try vm.shallowClone(&entry.value, allocator),
                    });
                }
            }
            if (!found_in_extmap) {
                try new_extmap.append(allocator, .{
                    .key = try vm.shallowClone(&key, allocator),
                    .value = try vm.shallowClone(&value, allocator),
                });
            }
            const cloned_fields = try vm.cloneMap(allocator, rd.fields);
            const cloned_meta = if (rd.meta) |m|
                try vm.cloneMap(allocator, m)
            else
                null;
            errdefer {
                if (cloned_meta) |cm| {
                    for (cm.items) |*entry| {
                        vm.valueDeinit(&entry.key, allocator);
                        vm.valueDeinit(&entry.value, allocator);
                    }
                    allocator.free(cm.items);
                }
                for (cloned_fields.items) |*entry| {
                    vm.valueDeinit(&entry.key, allocator);
                    vm.valueDeinit(&entry.value, allocator);
                }
                allocator.free(cloned_fields.items);
            }
            const new_type_name = try allocator.dupe(u8, rd.type_name);
            errdefer allocator.free(new_type_name);

            vm.valueDeinit(&current, allocator);
            current = try vm.recordValue(allocator, new_type_name, cloned_fields, new_extmap, cloned_meta);
            new_extmap = .empty;
        }
    }

    const result = current;
    current = vm.nilValue();
    return result;
}

/// Dissoc on a record. If a defined field is removed, demote to plain map.
fn dissocRecord(record: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;

    // Check if any key to dissoc is a defined field
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (isRecordDefinedField(record, args.items[i])) {
            // Demote to plain map, then dissoc from map
            var plain_map = try recordToMap(record, allocator);
            defer vm.valueDeinit(&plain_map, allocator);
            // Now dissoc from the plain map
            return core_dissocMap(&plain_map, args, env);
        }
    }

    // All keys are in extmap - create new record with updated extmap
    var new_extmap: vm.Map = .empty;
    errdefer {
        for (new_extmap.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_extmap.items);
    }
    for (record.record.extmap.items) |entry| {
        var should_keep = true;
        var j: usize = 1;
        while (j < args.items.len) : (j += 1) {
            if (vm.equals(entry.key, args.items[j])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_extmap.append(allocator, .{
                .key = try vm.shallowClone(&entry.key, allocator),
                .value = try vm.shallowClone(&entry.value, allocator),
            });
        }
    }

    const cloned_fields = try vm.cloneMap(allocator, record.record.fields);
    const cloned_meta = if (record.record.meta) |m|
        try vm.cloneMap(allocator, m)
    else
        null;
    errdefer {
        if (cloned_meta) |cm| {
            for (cm.items) |*entry| {
                vm.valueDeinit(&entry.key, allocator);
                vm.valueDeinit(&entry.value, allocator);
            }
            allocator.free(cm.items);
        }
        for (cloned_fields.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(cloned_fields.items);
    }
    const new_type_name = try allocator.dupe(u8, record.record.type_name);
    errdefer allocator.free(new_type_name);

    return try vm.recordValue(allocator, new_type_name, cloned_fields, new_extmap, cloned_meta);
}

/// Dissoc on a plain map (used internally by dissocRecord after demotion).
fn core_dissocMap(map_val: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    const allocator = env.allocator;
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_map.items);
    }

    for (map_val.map.entries.items) |entry| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (vm.equals(entry.key, args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_map.append(allocator, .{
                .key = try vm.shallowClone(&entry.key, allocator),
                .value = try vm.shallowClone(&entry.value, allocator),
            });
        }
    }
    return try vm.mapValue(allocator, new_map);
}

/// Merge result back to a record if the first arg was a record.
/// If all keys in the merged map are defined fields, return a record.
/// Otherwise return a record with extmap for extra keys.
fn mergeToRecord(original_record: *const Value, merged_map: vm.Map, allocator: Allocator) anyerror!Value {
    const rd = original_record.record;

    // Build new fields map from merged_map entries that match defined fields
    var new_fields: vm.Map = .empty;
    errdefer {
        for (new_fields.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_fields.items);
    }
    var new_extmap: vm.Map = .empty;
    errdefer {
        for (new_extmap.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_extmap.items);
    }

    // First, get all defined field values from merged_map
    for (rd.fields.items) |entry| {
        // Look up in merged_map
        for (merged_map.items) |m_entry| {
            if (vm.equals(m_entry.key, entry.key)) {
                try new_fields.append(allocator, .{
                    .key = try vm.shallowClone(&entry.key, allocator),
                    .value = try vm.shallowClone(&m_entry.value, allocator),
                });
                break;
            }
        }
    }

    // Then, collect any extra keys from merged_map into extmap
    for (merged_map.items) |m_entry| {
        var is_defined = false;
        for (rd.fields.items) |entry| {
            if (vm.equals(entry.key, m_entry.key)) {
                is_defined = true;
                break;
            }
        }
        if (!is_defined) {
            try new_extmap.append(allocator, .{
                .key = try vm.shallowClone(&m_entry.key, allocator),
                .value = try vm.shallowClone(&m_entry.value, allocator),
            });
        }
    }

    const cloned_meta = if (rd.meta) |m|
        try vm.cloneMap(allocator, m)
    else
        null;
    errdefer {
        if (cloned_meta) |cm| {
            for (cm.items) |*entry| {
                vm.valueDeinit(&entry.key, allocator);
                vm.valueDeinit(&entry.value, allocator);
            }
            allocator.free(cm.items);
        }
    }
    const new_type_name = try allocator.dupe(u8, rd.type_name);
    errdefer allocator.free(new_type_name);

    return try vm.recordValue(allocator, new_type_name, new_fields, new_extmap, cloned_meta);
}

pub fn registerMapFunctions(env: *Env) anyerror!void {
    try env.put("get", vm.builtinFnValue(core_get));
    try env.put("assoc", vm.builtinFnValue(core_assoc));
    try env.put("keys", vm.builtinFnValue(core_keys));
    try env.put("vals", vm.builtinFnValue(core_vals));
    try env.put("dissoc", vm.builtinFnValue(core_dissoc));
    try env.put("merge", vm.builtinFnValue(core_merge));
    try env.put("hash-map", vm.builtinFnValue(core_hash_map));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

fn makeMap(kvs: []const Value) Value {
    const a = std.heap.page_allocator;
    var m: vm.Map = .empty;
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        _ = m.append(a, .{ .key = kvs[i], .value = kvs[i + 1] }) catch unreachable;
    }
    return vm.mapValue(a, m) catch unreachable;
}

test "maps::get: finds key" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ vm.intValue(1), vm.intValue(10), vm.intValue(2), vm.intValue(20) });
    defer vm.valueDeinit(&m, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m, vm.intValue(1) });
    var result = core_get(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 10);
}

test "maps::get: missing key returns nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ vm.intValue(1), vm.intValue(10) });
    defer vm.valueDeinit(&m, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m, vm.intValue(99) });
    var result = core_get(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "maps::keys: returns all keys" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ vm.intValue(1), vm.intValue(10), vm.intValue(2), vm.intValue(20) });
    defer vm.valueDeinit(&m, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m });
    var result = core_keys(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items.len == 2);
}

test "maps::vals: returns all values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m = makeMap(&[_]Value{ vm.intValue(1), vm.intValue(10), vm.intValue(2), vm.intValue(20) });
    defer vm.valueDeinit(&m, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m });
    var result = core_vals(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .list);
    try std.testing.expect(result.list.items.items.len == 2);
}

test "maps::merge: merges two maps" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m1 = makeMap(&[_]Value{ vm.intValue(1), vm.intValue(10) });
    defer vm.valueDeinit(&m1, std.heap.page_allocator);
    var m2 = makeMap(&[_]Value{ vm.intValue(2), vm.intValue(20) });
    defer vm.valueDeinit(&m2, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ m1, m2 });
    var result = core_merge(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .map);
    try std.testing.expect(result.map.entries.items.len == 2);
}

test "maps::merge: no args returns empty map" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_merge(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .map);
    try std.testing.expect(result.map.entries.items.len == 0);
}

