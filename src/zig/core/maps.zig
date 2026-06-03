// Map built-in functions: get, assoc, keys, vals, dissoc, merge, hash-map
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const Env = Value.Env;

pub fn core_get(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;
    if (args.items.len == 1) return Value.nilValue();
    const key = args.items[1];
    for (map_val.map_val.items) |entry| {
        if (entry.key.equals(key)) {
            return try entry.value.clone(env_env.allocator);
        }
    }
    return Value.nilValue();
}

pub fn core_assoc(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 3) return error.ArityError;
    const first = args.items[0];

    // Vector assoc: (assoc vec index val & more-kvs)
    if (first.type == .vector) {
        return assocVector(first, args, env_env);
    }

    // Map assoc: (assoc map key val & more-kvs)
    if (first.type != .map) return error.TypeError;
    return assocMap(first, args, env_env);
}

fn assocVector(orig: Value, args: list.List, env: *Env) anyerror!Value {
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

fn assocMap(map_val: Value, args: list.List, env: *Env) anyerror!Value {
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

pub fn core_keys(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    for (map_val.map_val.items) |entry| {
        try result.append(env_env.allocator, try entry.key.clone(env_env.allocator));
    }
    return Value.listValue(result);
}

pub fn core_vals(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    for (map_val.map_val.items) |entry| {
        try result.append(env_env.allocator, try entry.value.clone(env_env.allocator));
    }
    return Value.listValue(result);
}

pub fn core_dissoc(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;

    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(env_env.allocator);
            entry.value.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_map.items);
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
            try new_map.append(env_env.allocator, .{
                .key = try entry.key.clone(env_env.allocator),
                .value = try entry.value.clone(env_env.allocator),
            });
        }
    }
    return Value.mapValue(new_map);
}

pub fn core_hash_map(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
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

pub fn core_merge(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return Value.mapValue(.empty);

    var result: Value.Map = .empty;
    errdefer {
        for (result.items) |*entry| {
            entry.key.deinit(env_env.allocator);
            entry.value.deinit(env_env.allocator);
        }
        env_env.allocator.free(result.items);
    }

    for (args.items) |arg| {
        if (arg.type != .map) continue;
        for (arg.map_val.items) |entry| {
            var found = false;
            var j: usize = 0;
            while (j < result.items.len) : (j += 1) {
                if (result.items[j].key.equals(entry.key)) {
                    result.items[j].value.deinit(env_env.allocator);
                    result.items[j].value = try entry.value.clone(env_env.allocator);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.append(env_env.allocator, .{
                    .key = try entry.key.clone(env_env.allocator),
                    .value = try entry.value.clone(env_env.allocator),
                });
            }
        }
    }
    return Value.mapValue(result);
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

