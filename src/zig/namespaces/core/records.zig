// Record support: defrecord evaluation and record type management
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = vm.Env;
const phm = @import("../../persistent_hash_map.zig");
const eval = @import("../../eval.zig");
const protocols = @import("protocols.zig");
const gc_mod = @import("../../gc.zig");

const Allocator = std.mem.Allocator;

/// Mark a list's buffer as a value_array so the GC scans the Value objects inside.
fn markListAsValueArray(l: *const list.List) void {
    if (l.items.len > 0) {
        if (gc_mod.current_gc) |gc| {
            gc.setObjectType(@as(*anyopaque, @ptrCast(l.items.ptr)), gc_mod.GCObjectType.value_array);
        }
    }
}

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
    var entries: vm.Map = .empty;
    errdefer {
        for (entries.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(entries.items);
    }

    // :name
    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "name"),
        .value = try vm.symValue(allocator, desc.name),
    });

    // :ns
    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "ns"),
        .value = try vm.stringValue(allocator, desc.namespace),
    });

    // :fields — list of keywords
    var fields_list: list.List = .empty;
    defer fields_list.deinit(allocator);
    for (desc.field_names.items) |fname| {
        try fields_list.append(allocator, try vm.keywordValue(allocator, fname));
    }
    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "fields"),
        .value = try vm.listValue(allocator, fields_list),
    });
    fields_list = .empty;

    // :field-count
    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "field-count"),
        .value = vm.intValue(@as(i64, @intCast(desc.field_names.items.len))),
    });

    return try vm.mapValue(allocator, entries);
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
    return vm.stringValue(allocator, msg);
}

/// Internal builtin: create a record from type name, fields map, extmap, and meta.
/// Args: (full_type_name_string fields_map extmap_or_nil meta_or_nil)
pub fn core_record_ctor(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;

    const allocator = env.allocator;

    // Arg 0: full type name (string)
    const type_name_val = args.items[0];
    if (std.meta.activeTag(type_name_val) != .string) {
        return makeErrorStr(allocator, "record-ctor: type name must be a string", .{});
    }
    const type_name = type_name_val.string;

    // Arg 1: fields map (keyword → value)
    const fields_map_val = args.items[1];
    if (std.meta.activeTag(fields_map_val) != .map) {
        return makeErrorStr(allocator, "record-ctor: fields must be a map", .{});
    }

    // Arg 2: extmap (map or nil)
    const extmap_val = if (args.items.len > 2) args.items[2] else vm.nilValue();

    // Arg 3: meta (map or nil)
    const meta_val = if (args.items.len > 3) args.items[3] else vm.nilValue();

    // Clone fields map entries
    var fields: vm.Map = .empty;
    errdefer {
        for (fields.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(fields.items);
    }
    for (fields_map_val.map.entries.items) |entry| {
        try fields.append(allocator, .{
            .key = try vm.shallowClone(&entry.key, allocator),
            .value = try vm.shallowClone(&entry.value, allocator),
        });
    }

    // Clone extmap entries (if not nil)
    var extmap: vm.Map = .empty;
    errdefer {
        for (extmap.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(extmap.items);
    }
    if (std.meta.activeTag(extmap_val) == .map) {
        for (extmap_val.map.entries.items) |entry| {
            try extmap.append(allocator, .{
                .key = try vm.shallowClone(&entry.key, allocator),
                .value = try vm.shallowClone(&entry.value, allocator),
            });
        }
    }

    // Clone meta (if not nil)
    var meta: ?vm.Map = null;
    if (std.meta.activeTag(meta_val) == .map) {
        var m: vm.Map = .empty;
        errdefer {
            for (m.items) |*entry| {
                vm.valueDeinit(&entry.key, allocator);
                vm.valueDeinit(&entry.value, allocator);
            }
            allocator.free(m.items);
        }
        for (meta_val.map.entries.items) |entry| {
            try m.append(allocator, .{
                .key = try vm.shallowClone(&entry.key, allocator),
                .value = try vm.shallowClone(&entry.value, allocator),
            });
        }
        meta = m;
    }

    return try vm.recordValue(allocator, type_name, fields, extmap, meta);
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
        try params_list.append(allocator, try vm.symValue(allocator, fname));
    }

    // Build body: (record-ctor "ns.Name" {:a a :b b} {} nil)
    // First build the fields map: {:a a :b b}
    var fields_entries: vm.Map = .empty;
    defer {
        for (fields_entries.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(fields_entries.items);
    }
    for (desc.field_names.items) |fname| {
        try fields_entries.append(allocator, .{
            .key = try vm.keywordValue(allocator, fname),
            .value = try vm.symValue(allocator, fname), // reference param by name
        });
    }

    // Build the call list: (record-ctor "full_name" {:a a :b b} {} nil)
    var body_list: list.List = .empty;
    defer body_list.deinit(allocator);
    try body_list.append(allocator, try vm.symValue(allocator, "record-ctor"));
    try body_list.append(allocator, try vm.stringValue(allocator, desc.full_name));
    try body_list.append(allocator, try vm.mapValue(allocator, fields_entries));
    // fields_entries ownership transferred to the mapValue
    fields_entries = .empty;

    // Empty extmap: {}
    try body_list.append(allocator, try vm.mapValue(allocator, .empty));
    // nil meta
    try body_list.append(allocator, vm.nilValue());

    // Build fn name: "->RecordName"
    const fn_name = try std.fmt.allocPrint(allocator, "->{s}", .{desc.name});
    errdefer allocator.free(fn_name);

    // Mark body list as value_array so GC scans Value objects inside
    markListAsValueArray(&body_list);

    // Create the function value
    // Use explicit struct init to avoid shallow-copying owned_symbols
    const env_copy: Env = .{
        .allocator = env.allocator,
        .entries = env.entries,
        .parent = env.parent,
        .ns_manager = env.ns_manager,
        .referred_names = .empty,
        .owned_symbols = .empty,
    };
    const result = try vm.fnValueSingleNamed(
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
    try params_list.append(allocator, try vm.symValue(allocator, "m"));

    // Build body: (record-ctor "ns.Name" {field (get m :field) ...} {extra ...} nil)
    // For the fields map, we need: {:a (get m :a) :b (get m :b)}
    var fields_entries: vm.Map = .empty;
    defer {
        for (fields_entries.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(fields_entries.items);
    }
    for (desc.field_names.items) |fname| {
        // Value: (get m :fname)
        var get_call: list.List = .empty;
        defer get_call.deinit(allocator);
        try get_call.append(allocator, try vm.symValue(allocator, "get"));
        try get_call.append(allocator, try vm.symValue(allocator, "m"));
        try get_call.append(allocator, try vm.keywordValue(allocator, fname));
        try fields_entries.append(allocator, .{
            .key = try vm.keywordValue(allocator, fname),
            .value = try vm.listValue(allocator, get_call),
        });
        get_call = .empty;
    }

    // Build the call list: (record-ctor "full_name" {:a (get m :a) ...} {} nil)
    var body_list: list.List = .empty;
    defer body_list.deinit(allocator);
    try body_list.append(allocator, try vm.symValue(allocator, "record-ctor"));
    try body_list.append(allocator, try vm.stringValue(allocator, desc.full_name));
    try body_list.append(allocator, try vm.mapValue(allocator, fields_entries));
    fields_entries = .empty;

    // Empty extmap: {}
    try body_list.append(allocator, try vm.mapValue(allocator, .empty));
    // nil meta
    try body_list.append(allocator, vm.nilValue());

    // Build fn name: "map->RecordName"
    const fn_name = try std.fmt.allocPrint(allocator, "map->{s}", .{desc.name});
    errdefer allocator.free(fn_name);

    // Mark body list as value_array so GC scans Value objects inside
    markListAsValueArray(&body_list);

    // Create the function value
    // Use explicit struct init to avoid shallow-copying owned_symbols
    const env_copy: Env = .{
        .allocator = env.allocator,
        .entries = env.entries,
        .parent = env.parent,
        .ns_manager = env.ns_manager,
        .referred_names = .empty,
        .owned_symbols = .empty,
    };
    const result = try vm.fnValueSingleNamed(
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

/// Process a protocol spec in a defrecord form.
/// Evaluates the protocol symbol, builds method functions, and calls extend.
fn processRecordProtocolSpec(
    allocator: Allocator,
    env: *Env,
    depth: usize,
    proto_sym: Value,
    l: *const list.List,
    method_indices: []const usize,
    full_type_name: []const u8,
    field_names: []const []const u8,
) anyerror!Value {

    // Evaluate the protocol symbol to get the protocol value
    const proto_ptr_r = try eval.evalRecWithEnv(allocator, &proto_sym, env, depth + 1);
    // Phase 1: proto_ptr_r.value is now Value by copy (not *Value)
        const proto_ptr = proto_ptr_r.value;
    defer vm.valueDeinit(@constCast(&proto_ptr), allocator);

    // Validate it's a protocol (has :sigs key)
    var sigs_kw = try vm.keywordValue(allocator, "sigs");
    defer vm.valueDeinit(&sigs_kw, allocator);
    if (getMapEntry(proto_ptr, sigs_kw) == null) {
        return makeErrorStr(allocator, "defrecord: {s} is not a protocol", .{proto_sym.symbol});
    }

    // Build method map: group method definitions by name, build multi-arity fns
    var mmap: vm.Map = .empty;
    errdefer {
        for (mmap.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(mmap.items);
    }

    // Collect unique method names (preserving order)
    var unique_names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (unique_names.items) |n| allocator.free(n);
        allocator.free(unique_names.items);
    }

    for (method_indices) |mi| {
        const mdef = l.items[mi];
        if (std.meta.activeTag(mdef) != .list or mdef.list.items.items.len < 2) {
            return makeErrorStr(allocator, "defrecord: method definition must be a list with at least a name and params", .{});
        }
        const mname_sym = mdef.list.items.items[0];
        if (std.meta.activeTag(mname_sym) != .symbol) {
            return makeErrorStr(allocator, "defrecord: method name must be a symbol", .{});
        }
        const mname = mname_sym.symbol;

        // Add to unique names if not already present
        var found = false;
        for (unique_names.items) |existing| {
            if (std.mem.eql(u8, existing, mname)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try unique_names.append(allocator, try allocator.dupe(u8, mname));
        }
    }

    // For each unique method name, build a multi-arity fn
    for (unique_names.items) |mname| {
        // fn form: (fn arity1 arity2 ...) where arity = ([params] body...)
        var fn_form: list.List = .empty;
        defer fn_form.deinit(allocator);
        try fn_form.append(allocator, try vm.symValue(allocator, "fn"));

        for (method_indices) |mi| {
            const mdef = l.items[mi];
            const mname_sym = mdef.list.items.items[0];
            if (std.meta.activeTag(mname_sym) != .symbol) continue;
            if (!std.mem.eql(u8, mname_sym.symbol, mname)) continue;

            // items[1:] of the method def: [params] body...
            // Build arity form: ([params] (let [field1 (get this :field1) ...] body...))
            var arity_form: list.List = .empty;
            defer arity_form.deinit(allocator);
            const def_items = mdef.list.items.items[1..];
            // params vector is def_items[0], body is def_items[1..]
            try arity_form.append(allocator, try vm.shallowClone(&def_items[0], allocator));

            // Wrap body in let that binds field names to (get this :field_name)
            if (field_names.len > 0) {
                // Build let form: (let [f1 (get this :f1) f2 (get this :f2) ...] body...)
                var let_form: list.List = .empty;
                defer let_form.deinit(allocator);
                try let_form.append(allocator, try vm.symValue(allocator, "let"));

                // Build bindings vector: [f1 (get this :f1) f2 (get this :f2) ...]
                var bindings: list.List = .empty;
                defer bindings.deinit(allocator);
                for (field_names) |fname| {
                    try bindings.append(allocator, try vm.symValue(allocator, fname));
                    // (get this :fname)
                    var get_form: list.List = .empty;
                    defer get_form.deinit(allocator);
                    try get_form.append(allocator, try vm.symValue(allocator, "get"));
                    try get_form.append(allocator, try vm.symValue(allocator, "this"));
                    try get_form.append(allocator, try vm.keywordValue(allocator, fname));
                    try bindings.append(allocator, try vm.listValue(allocator, get_form));
                    get_form = .empty;
                }
                try let_form.append(allocator, try vm.listValue(allocator, bindings));
                bindings = .empty;

                // Append body forms
                for (def_items[1..]) |item| {
                    try let_form.append(allocator, try vm.shallowClone(&item, allocator));
                }
                try arity_form.append(allocator, try vm.listValue(allocator, let_form));
                let_form = .empty;
            } else {
                // No fields, just append body as-is
                for (def_items[1..]) |item| {
                    try arity_form.append(allocator, try vm.shallowClone(&item, allocator));
                }
            }
            try fn_form.append(allocator, try vm.listValue(allocator, arity_form));
            arity_form = .empty;
        }

        // Evaluate to get a function value
        const fn_ptr_r = try eval.evalRecWithEnv(allocator, &(try vm.listValue(allocator, fn_form)), env, depth + 1);
        // Phase 1: fn_ptr_r.value is now Value by copy (not *Value)
        const fn_ptr = fn_ptr_r.value;
        fn_form = .empty;
        const persistent_fn = try vm.shallowClone(&fn_ptr, allocator);
        vm.valueDeinit(@constCast(&fn_ptr), allocator);

        try mmap.append(allocator, .{
            .key = try vm.keywordValue(allocator, mname),
            .value = persistent_fn,
        });
    }

    // Build the dispatch type keyword: :ns.RecordName
    var atype = try vm.keywordValue(allocator, full_type_name);
    defer vm.valueDeinit(&atype, allocator);

    // Build extend args: (extend atype protocol mmap)
    var extend_args: list.List = .empty;
    defer extend_args.deinit(allocator);
    try extend_args.append(allocator, atype);
    // Phase 1: proto_ptr is now Value by copy (not *Value)
    try extend_args.append(allocator, proto_ptr);
    try extend_args.append(allocator, try vm.mapValue(allocator, mmap));
    mmap = .empty;

    // Call evalExtend
    return protocols.evalExtend(allocator, extend_args, env, depth);
}

/// Look up a key in a map, returning the value or null.
fn getMapEntry(m: Value, key: Value) ?Value {
    if (std.meta.activeTag(m) != .map) return null;
    for (m.map.entries.items) |entry| {
        if (vm.equals(entry.key, key)) return entry.value;
    }
    return null;
}

/// Evaluate a (defrecord name [fields*] options* specs*) form.
/// Creates a record type descriptor and stores it in the current namespace.
/// Returns the record name symbol.
pub fn evalDefRecord(
    allocator: Allocator,
    l: list.List,
    env: *Env,
    depth: usize,
) anyerror!Value {
    // (defrecord name [fields*] options* specs*)
    if (l.items.len < 3) {
        return makeErrorStr(allocator, "defrecord: usage is (defrecord name [fields*] options* specs*)", .{});
    }

    const name_sym = l.items[1];
    if (std.meta.activeTag(name_sym) != .symbol) {
        return makeErrorStr(allocator, "defrecord: name must be a symbol", .{});
    }
    const record_name = name_sym.symbol;

    const fields_vec = l.items[2];

    // Validate fields
    if (std.meta.activeTag(fields_vec) != .vector) {
        return makeErrorStr(allocator, "defrecord: fields must be a vector, got {s}", .{@tagName(std.meta.activeTag(fields_vec))});
    }

    const reserved = [_][]const u8 { "__meta", "__extmap", "__hash", "__hasheq" };

    for (fields_vec.vector.items.items) |field| {
        if (std.meta.activeTag(field) != .symbol) {
            return makeErrorStr(allocator, "defrecord: fields must be symbols, got {s}", .{@tagName(std.meta.activeTag(field))});
        }
        for (reserved) |res| {
            if (std.mem.eql(u8, field.symbol, res)) {
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
    for (fields_vec.vector.items.items) |field| {
        const fname = try allocator.dupe(u8, field.symbol);
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
    const wrapped_desc = vm.wrapPtr(*RecordDescriptor, desc_ptr);
    const internal_name = try std.fmt.allocPrint(allocator, "__record_{s}", .{record_name});
    try eval.bindInCurrentNamespace(env, internal_name, wrapped_desc);

    // Build and bind factory functions
    // ->RecordName (positional factory)
    var pos_factory = try buildPositionalFactory(allocator, desc_ptr, env);
    const persistent_pos = try vm.shallowClone(&pos_factory, allocator);
    vm.valueDeinit(&pos_factory, allocator);
    const pos_fn_name = try std.fmt.allocPrint(allocator, "->{s}", .{record_name});
    try eval.bindInCurrentNamespace(env, pos_fn_name, persistent_pos);

    // map->RecordName (map factory)
    var map_factory = try buildMapFactory(allocator, desc_ptr, env);
    const persistent_map = try vm.shallowClone(&map_factory, allocator);
    vm.valueDeinit(&map_factory, allocator);
    const map_fn_name = try std.fmt.allocPrint(allocator, "map->{s}", .{record_name});
    try eval.bindInCurrentNamespace(env, map_fn_name, persistent_map);

    // Parse options* and specs* (protocol implementations).
    var idx: usize = 3;
    while (idx < l.items.len) {
        const item = l.items[idx];
        if (std.meta.activeTag(item) == .keyword) {
            // Skip option keyword + value pair
            if (idx + 1 < l.items.len) idx += 2 else break;
        } else if (std.meta.activeTag(item) == .symbol) {
            // Protocol name — collect method definitions
            const proto_sym = item;
            idx += 1;

            // Collect method definition indices for this protocol
            var method_indices: std.ArrayListUnmanaged(usize) = .empty;
            defer allocator.free(method_indices.items);
            while (idx < l.items.len and std.meta.activeTag(l.items[idx]) == .list) {
                try method_indices.append(allocator, idx);
                idx += 1;
            }

            // If we have method definitions, extend the protocol
            if (method_indices.items.len > 0) {
                _ = processRecordProtocolSpec(
                    allocator,
                    env,
                    depth,
                    proto_sym,
                    &l,
                    method_indices.items,
                    full_name,
                    field_names.items,
                ) catch {};
            }
        } else {
            break;
        }
    }

    // Return the record name symbol
    return try vm.symValue(allocator, record_name);
}
