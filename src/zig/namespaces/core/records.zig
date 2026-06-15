// Record support: defrecord evaluation and record type management
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = Value.Env;
const phm = @import("../../persistent_hash_map.zig");
const eval = @import("../../eval.zig");

const Allocator = std.mem.Allocator;

/// Record type descriptor — stored in the namespace env under the record name.
/// Contains metadata about the record type: field names, namespace, field count.
///
/// Structure:
///   {:name 'Person
///    :ns "user"
///    :fields [:name :age]
///    :field-count 2}
pub const RecordDescriptor = struct {
    // Record type name (e.g. "Person")
    name: []const u8,
    // Namespace where record was defined (e.g. "user")
    namespace: []const u8,
    // Full qualified type name for identity (e.g. "user.Person")
    full_name: []const u8,
    // Field names as keyword strings (e.g. ["name", "age"])
    field_names: std.ArrayListUnmanaged([]const u8),
    // Allocator used for internal allocations
    allocator: Allocator,
};

/// Build a record descriptor map (Clojure map) from a RecordDescriptor.
fn buildDescriptorMap(allocator: Allocator, desc: *const RecordDescriptor) anyerror!Value {
    var entries: Value.Map = .empty;
    errdefer {
        for (entries.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(entries.items);
    }

    // :name
    try entries.append(allocator, .{
        .key = try Value.keywordValue(allocator, "name"),
        .value = try Value.symValue(allocator, desc.name),
    });

    // :ns
    try entries.append(allocator, .{
        .key = try Value.keywordValue(allocator, "ns"),
        .value = try Value.stringValue(allocator, desc.namespace),
    });

    // :fields — list of keywords
    var fields_list: list.List = .empty;
    defer fields_list.deinit(allocator);
    for (desc.field_names.items) |fname| {
        try fields_list.append(allocator, try Value.keywordValue(allocator, fname));
    }
    try entries.append(allocator, .{
        .key = try Value.keywordValue(allocator, "fields"),
        .value = Value.listValue(fields_list),
    });
    fields_list = .empty;

    // :field-count
    try entries.append(allocator, .{
        .key = try Value.keywordValue(allocator, "field-count"),
        .value = Value.intValue(@as(i64, @intCast(desc.field_names.items.len))),
    });

    return Value.mapValue(entries);
}

/// Deinitialize a RecordDescriptor.
fn deinitDescriptor(allocator: Allocator, desc: *RecordDescriptor) void {
    for (desc.field_names.items) |fname| {
        allocator.free(fname);
    }
    allocator.free(desc.field_names.items);
    allocator.free(desc.name);
    allocator.free(desc.namespace);
    allocator.free(desc.full_name);
}

/// Helper to build an error string and return it as a string value.
fn makeErrorStr(allocator: Allocator, comptime fmt: []const u8, args: anytype) anyerror!Value {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return error.OutOfMemory;
    return Value.stringValue(allocator, msg);
}

/// Internal builtin: create a record from type name, fields map, extmap, and meta.
/// Args: (full_type_name_string fields_map extmap_or_nil meta_or_nil)
pub fn core_record_ctor(self: *Value, args: list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;

    const allocator = env.allocator;

    // Arg 0: full type name (string)
    const type_name_val = args.items[0];
    if (type_name_val.type != .string) {
        return makeErrorStr(allocator, "record-ctor: type name must be a string", .{});
    }
    const type_name = type_name_val.str_val;

    // Arg 1: fields map (keyword → value)
    const fields_map_val = args.items[1];
    if (fields_map_val.type != .map) {
        return makeErrorStr(allocator, "record-ctor: fields must be a map", .{});
    }

    // Arg 2: extmap (map or nil)
    const extmap_val = if (args.items.len > 2) args.items[2] else Value.nilValue();

    // Arg 3: meta (map or nil)
    const meta_val = if (args.items.len > 3) args.items[3] else Value.nilValue();

    // Clone fields map entries
    var fields: Value.Map = .empty;
    errdefer {
        for (fields.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(fields.items);
    }
    for (fields_map_val.map_val.items) |entry| {
        try fields.append(allocator, .{
            .key = try entry.key.clone(allocator),
            .value = try entry.value.clone(allocator),
        });
    }

    // Clone extmap entries (if not nil)
    var extmap: Value.Map = .empty;
    errdefer {
        for (extmap.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(extmap.items);
    }
    if (extmap_val.type == .map) {
        for (extmap_val.map_val.items) |entry| {
            try extmap.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
    }

    // Clone meta (if not nil)
    var meta: ?Value.Map = null;
    if (meta_val.type == .map) {
        var m: Value.Map = .empty;
        errdefer {
            for (m.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(m.items);
        }
        for (meta_val.map_val.items) |entry| {
            try m.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
        meta = m;
    }

    return try Value.recordValue(allocator, type_name, fields, extmap, meta);
}

/// Build a positional factory function (->RecordName).
/// Creates a fn with params matching field names and body calling record-ctor.
pub fn buildPositionalFactory(
    allocator: Allocator,
    desc: *const RecordDescriptor,
    env: *Env,
) anyerror!Value {
    // Build params list: [a b c]
    var params_list: list.List = .empty;
    defer params_list.deinit(allocator);
    for (desc.field_names.items) |fname| {
        try params_list.append(allocator, try Value.symValue(allocator, fname));
    }

    // Build body: (record-ctor "ns.Name" {:a a :b b} {} nil)
    // First build the fields map: {:a a :b b}
    var fields_entries: Value.Map = .empty;
    defer {
        for (fields_entries.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(fields_entries.items);
    }
    for (desc.field_names.items) |fname| {
        try fields_entries.append(allocator, .{
            .key = try Value.keywordValue(allocator, fname),
            .value = try Value.symValue(allocator, fname), // reference param by name
        });
    }

    // Build the call list: (record-ctor "full_name" {:a a :b b} {} nil)
    var body_list: list.List = .empty;
    defer body_list.deinit(allocator);
    try body_list.append(allocator, try Value.symValue(allocator, "record-ctor"));
    try body_list.append(allocator, try Value.stringValue(allocator, desc.full_name));
    try body_list.append(allocator, Value.mapValue(fields_entries));
    // fields_entries ownership transferred to the mapValue
    fields_entries = .empty;

    // Empty extmap: {}
    try body_list.append(allocator, Value.mapValue(.empty));
    // nil meta
    try body_list.append(allocator, Value.nilValue());

    // Build fn name: "->RecordName"
    const fn_name = try std.fmt.allocPrint(allocator, "->{s}", .{desc.name});
    errdefer allocator.free(fn_name);

    // Create the function value
    const env_copy: Env = env.*;
    const result = try Value.fnValueSingleNamed(
        allocator,
        params_list,
        body_list,
        env_copy,
        null, // no rest param
        false, // not a macro
        fn_name,
    );
    // Transfer ownership: clear lists so defer doesn't double-free
    params_list = .empty;
    body_list = .empty;
    return result;
}

/// Build a map factory function (map->RecordName).
/// Creates a fn that takes a map and extracts field values by keyword.
pub fn buildMapFactory(
    allocator: Allocator,
    desc: *const RecordDescriptor,
    env: *Env,
) anyerror!Value {
    // Build params list: [m]
    var params_list: list.List = .empty;
    defer params_list.deinit(allocator);
    try params_list.append(allocator, try Value.symValue(allocator, "m"));

    // Build body: (record-ctor "ns.Name" {field (get m :field) ...} {extra ...} nil)
    // For the fields map, we need: {:a (get m :a) :b (get m :b)}
    var fields_entries: Value.Map = .empty;
    defer {
        for (fields_entries.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(fields_entries.items);
    }
    for (desc.field_names.items) |fname| {
        // Value: (get m :fname)
        var get_call: list.List = .empty;
        defer get_call.deinit(allocator);
        try get_call.append(allocator, try Value.symValue(allocator, "get"));
        try get_call.append(allocator, try Value.symValue(allocator, "m"));
        try get_call.append(allocator, try Value.keywordValue(allocator, fname));
        try fields_entries.append(allocator, .{
            .key = try Value.keywordValue(allocator, fname),
            .value = Value.listValue(get_call),
        });
        get_call = .empty;
    }

    // Build the call list: (record-ctor "full_name" {:a (get m :a) ...} {} nil)
    var body_list: list.List = .empty;
    defer body_list.deinit(allocator);
    try body_list.append(allocator, try Value.symValue(allocator, "record-ctor"));
    try body_list.append(allocator, try Value.stringValue(allocator, desc.full_name));
    try body_list.append(allocator, Value.mapValue(fields_entries));
    fields_entries = .empty;

    // Empty extmap: {}
    try body_list.append(allocator, Value.mapValue(.empty));
    // nil meta
    try body_list.append(allocator, Value.nilValue());

    // Build fn name: "map->RecordName"
    const fn_name = try std.fmt.allocPrint(allocator, "map->{s}", .{desc.name});
    errdefer allocator.free(fn_name);

    // Create the function value
    const env_copy: Env = env.*;
    const result = try Value.fnValueSingleNamed(
        allocator,
        params_list,
        body_list,
        env_copy,
        null, // no rest param
        false, // not a macro
        fn_name,
    );
    // Transfer ownership: clear lists so defer doesn't double-free
    params_list = .empty;
    body_list = .empty;
    return result;
}

/// Evaluate a (defrecord name [fields*] options* specs*) form.
/// Creates a record type descriptor and stores it in the current namespace.
/// Returns the record name symbol.
pub fn evalDefRecord(
    allocator: Allocator,
    arena_alloc: Allocator,
    l: list.List,
    env: *Env,
    depth: usize,
) anyerror!Value {
    _ = arena_alloc;
    _ = depth;

    // (defrecord name [fields*] options* specs*)
    if (l.items.len < 3) {
        return makeErrorStr(allocator, "defrecord: usage is (defrecord name [fields*] options* specs*)", .{});
    }

    const name_sym = l.items[1];
    if (name_sym.type != .symbol) {
        return makeErrorStr(allocator, "defrecord: name must be a symbol", .{});
    }
    const record_name = name_sym.sym_val;

    const fields_vec = l.items[2];

    // Validate fields
    if (fields_vec.type != .vector) {
        return makeErrorStr(allocator, "defrecord: fields must be a vector, got {s}", .{@tagName(fields_vec.type)});
    }

    const reserved = [_][]const u8 { "__meta", "__extmap", "__hash", "__hasheq" };

    for (fields_vec.vec_val.items) |field| {
        if (field.type != .symbol) {
            return makeErrorStr(allocator, "defrecord: fields must be symbols, got {s}", .{@tagName(field.type)});
        }
        for (reserved) |res| {
            if (std.mem.eql(u8, field.sym_val, res)) {
                return makeErrorStr(allocator, "defrecord: '{s}' cannot be used as a field name", .{res});
            }
        }
    }

    // Get current namespace
    const ns_mgr = eval.findNsManager(env) orelse {
        return makeErrorStr(allocator, "defrecord: no namespace manager available", .{});
    };
    const current_ns = ns_mgr.getCurrentNamespace();

    // Build full type name: "ns.RecordName"
    const full_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ current_ns, record_name });

    // Parse field names
    var field_names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer allocator.free(field_names.items);
    for (fields_vec.vec_val.items) |field| {
        const fname = try allocator.dupe(u8, field.sym_val);
        try field_names.append(allocator, fname);
    }

    // Create record type descriptor
    var desc = RecordDescriptor{
        .name = try allocator.dupe(u8, record_name),
        .namespace = try allocator.dupe(u8, current_ns),
        .full_name = full_name,
        .field_names = field_names,
        .allocator = allocator,
    };
    errdefer deinitDescriptor(allocator, &desc);

    // Build descriptor map (Clojure map)
    const descriptor_map = try buildDescriptorMap(allocator, &desc);

    // Store descriptor in current namespace under the record name
    try eval.bindInCurrentNamespace(env, record_name, descriptor_map);

    // Also store the RecordDescriptor in the namespace for factory function lookup.
    // We store it as a .wrapped value pointing to the heap-allocated descriptor.
    const desc_ptr = try allocator.create(RecordDescriptor);
    desc_ptr.* = desc;
    // Transfer ownership: desc is now owned by desc_ptr, don't deinit it
    const wrapped_desc = Value.wrapPtr(*RecordDescriptor, desc_ptr);
    const internal_name = try std.fmt.allocPrint(allocator, "__record_{s}", .{record_name});
    try eval.bindInCurrentNamespace(env, internal_name, wrapped_desc);

    // Build and bind factory functions
    // ->RecordName (positional factory)
    var pos_factory = try buildPositionalFactory(allocator, desc_ptr, env);
    const persistent_pos = try pos_factory.clone(allocator);
    pos_factory.deinit(allocator);
    const pos_fn_name = try std.fmt.allocPrint(allocator, "->{s}", .{record_name});
    try eval.bindInCurrentNamespace(env, pos_fn_name, persistent_pos);

    // map->RecordName (map factory)
    var map_factory = try buildMapFactory(allocator, desc_ptr, env);
    const persistent_map = try map_factory.clone(allocator);
    map_factory.deinit(allocator);
    const map_fn_name = try std.fmt.allocPrint(allocator, "map->{s}", .{record_name});
    try eval.bindInCurrentNamespace(env, map_fn_name, persistent_map);

    // Parse and skip options* and specs* (protocol implementation handled in Phase 9).
    var idx: usize = 3;
    while (idx < l.items.len) {
        const item = l.items[idx];
        if (item.type == .keyword) {
            // Skip option keyword + value pair
            if (idx + 1 < l.items.len) idx += 2 else break;
        } else if (item.type == .symbol) {
            // Protocol name — skip it and its method definitions
            idx += 1;
            while (idx < l.items.len and l.items[idx].type == .list) {
                idx += 1;
            }
        } else {
            break;
        }
    }

    // Return the record name symbol
    return try Value.symValue(allocator, record_name);
}
