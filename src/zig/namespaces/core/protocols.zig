// Protocol support: dispatch helper and defprotocol evaluation support
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const Env = Value.Env;
const phm = @import("../../persistent_hash_map.zig");
const eval = @import("../../eval.zig");
const eval_helpers = @import("eval_helpers.zig");

const Allocator = std.mem.Allocator;

/// Look up a key in a map value. Returns the value if found, null otherwise.
pub fn getMapEntry(map_val: Value, key: Value) ?Value {
    if (map_val.type != .map) return null;
    for (map_val.map_val.items) |entry| {
        if (entry.key.equals(key)) {
            return entry.value;
        }
    }
    return null;
}

/// Get the type keyword string for a value's runtime type.
pub fn typeKeyword(v: Value) []const u8 {
    return switch (v.type) {
        .nil => "nil",
        .bool => "bool",
        .integer => "integer",
        .float => "float",
        .bigint => "bigint",
        .ratio => "ratio",
        .decimal => "decimal",
        .string => "string",
        .regex => "regex",
        .character => "character",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .vector => "vector",
        .map => "map",
        .set => "set",
        .queue => "queue",
        .atom => "atom",
        .function => "function",
        .builtin_fn => "builtin_fn",
        .lazy_seq => "lazy_seq",
        .cons => "cons",
        .reduced => "reduced",
        .wrapped => "wrapped",
        .record => v.record_val.?.type_name,
    };
}

/// Helper to build an error string and return it as a string value.
fn makeErrorStr(allocator: Allocator, comptime fmt: []const u8, args: anytype) anyerror!Value {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return error.OutOfMemory;
    return Value.stringValue(allocator, msg);
}

/// Dispatch a protocol method call.
/// Looks up the protocol map from the namespace, finds the impl for the
/// first arg's type, and calls it with all arguments.
///
/// `proto_env` — the function's closure env containing:
///   __proto_ns  (string) — namespace where protocol is defined
///   __proto_name (string) — protocol var name
///   __method_kw  (string) — method keyword name (without colon)
pub fn dispatchProtocolMethod(
    allocator: Allocator,
    args: list.List,
    proto_env: *const Env,
    depth: usize,
) anyerror!Value {
    if (args.items.len == 0) {
        return makeErrorStr(allocator, "error: protocol method called with no arguments", .{});
    }

    // Get the dispatch target (first argument)
    const target = args.items[0];

    // Get protocol namespace and name from closure env
    const mut_env: *Env = @constCast(proto_env);
    const proto_ns_val = mut_env.get("__proto_ns") orelse
        return makeErrorStr(allocator, "error: protocol dispatch missing __proto_ns", .{});
    const proto_name_val = mut_env.get("__proto_name") orelse
        return makeErrorStr(allocator, "error: protocol dispatch missing __proto_name", .{});
    const method_kw_val = mut_env.get("__method_kw") orelse
        return makeErrorStr(allocator, "error: protocol dispatch missing __method_kw", .{});

    const proto_ns = proto_ns_val.str_val;
    const proto_name = proto_name_val.str_val;
    const method_kw = method_kw_val.str_val;

    // Look up the protocol map from the namespace (dynamic lookup)
    const ns_mgr = eval.findNsManager(proto_env) orelse
        return makeErrorStr(allocator, "error: no namespace manager for protocol dispatch", .{});
    const ns_env = ns_mgr.getNamespace(proto_ns) orelse
        return makeErrorStr(allocator, "error: namespace '{s}' not found for protocol dispatch", .{proto_ns});

    const protocol_map_val = ns_env.get(proto_name) orelse
        return makeErrorStr(allocator, "error: protocol '{s}' not found in namespace '{s}'", .{proto_name, proto_ns});

    // Get :impls from protocol map
    const impls_kw = try Value.keywordValue(allocator, "impls");
    const impls_map = getMapEntry(protocol_map_val, impls_kw) orelse {
        const type_kw = typeKeyword(target);
        return makeErrorStr(allocator, "No implementation of method: :{s} of protocol: #{{'{s}/{s} found for type: {s}", .{ method_kw, proto_ns, proto_name, type_kw });
    };

    // Get type keyword for the dispatch target
    const type_kw_str = typeKeyword(target);
    const type_kw = try Value.keywordValue(allocator, type_kw_str);

    // Look up impl for this type in the impls map
    const type_impls = getMapEntry(impls_map, type_kw) orelse {
        return makeErrorStr(allocator, "No implementation of method: :{s} of protocol: #{{'{s}/{s} found for type: {s}", .{ method_kw, proto_ns, proto_name, type_kw_str });
    };

    // Look up the method function in the type's impl map
    const method_kw_full = try Value.keywordValue(allocator, method_kw);
    const impl_fn = getMapEntry(type_impls, method_kw_full) orelse {
        return makeErrorStr(allocator, "No implementation of method: :{s} of protocol: #{{'{s}/{s} found for type: {s}", .{ method_kw, proto_ns, proto_name, type_kw_str });
    };

    // Call the implementation function with all arguments
    const call_env: *Env = @constCast(proto_env);
    return try eval.call(allocator, &impl_fn, &args, call_env, depth);
}

/// Evaluate a (defprotocol ...) form.
/// Returns the protocol name symbol.
pub fn evalDefProtocol(
    allocator: Allocator,
    l: list.List,
    env: *Env,
    _depth: usize,
) anyerror!Value {
    _ = _depth;
    // (defprotocol name docstring? options? (method [params]... docstring?)+)
    if (l.items.len < 2) return error.ArityError;

    const name_sym = l.items[1];
    if (name_sym.type != .symbol) return error.TypeError;
    const proto_name = name_sym.sym_val;

    // Parse opts+sigs
    var idx: usize = 2;
    var docstring: ?[]const u8 = null;

    // Skip optional docstring
    if (idx < l.items.len and l.items[idx].type == .string) {
        docstring = try allocator.dupe(u8, l.items[idx].str_val);
        idx += 1;
    }

    // Skip optional keyword options (pairs)
    while (idx < l.items.len) {
        const item = l.items[idx];
        if (item.type == .keyword) {
            if (idx + 1 >= l.items.len) return error.ArityError;
            idx += 2;
        } else {
            break;
        }
    }

    // Collect method names and their signatures
    var method_names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (method_names.items) |n| allocator.free(n);
        allocator.free(method_names.items);
    }

    // sigs entries: method-kw -> sig-map
    var sigs: std.ArrayListUnmanaged(Value.MapEntry) = .empty;
    errdefer {
        for (sigs.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(sigs.items);
    }

    while (idx < l.items.len) {
        const sig = l.items[idx];
        if (sig.type != .list or sig.list_val.items.len < 2) return error.TypeError;

        const sig_list = sig.list_val;
        const mname_sym = sig_list.items[0];
        if (mname_sym.type != .symbol) return error.TypeError;
        const mname = mname_sym.sym_val;

        // Check for duplicate method names
        for (method_names.items) |existing| {
            if (std.mem.eql(u8, existing, mname)) {
                return makeErrorStr(allocator, "Function {s} in protocol {s} was redefined. Specify all arities in single definition.", .{ mname, proto_name });
            }
        }
        try method_names.append(allocator, try allocator.dupe(u8, mname));

        // Parse arities (vectors) and optional docstring
        var arglists: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (arglists.items) |a| allocator.free(a);
            allocator.free(arglists.items);
        }

        var method_doc: ?[]const u8 = null;

        var ai: usize = 1;
        while (ai < sig_list.items.len) : (ai += 1) {
            const item = sig_list.items[ai];
            if (item.type == .vector) {
                // Build arglist like "(this x y)"
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer allocator.free(buf.items);
                try buf.append(allocator, '(');
                var first_param = true;
                for (item.vec_val.items) |param| {
                    if (!first_param) try buf.append(allocator, ' ');
                    first_param = false;
                    if (param.type == .symbol) {
                        try buf.appendSlice(allocator, param.sym_val);
                    } else {
                        try buf.appendSlice(allocator, "x");
                    }
                }
                try buf.append(allocator, ')');
                try arglists.append(allocator, try allocator.dupe(u8, buf.items));
            } else if (item.type == .string) {
                method_doc = try allocator.dupe(u8, item.str_val);
            }
        }

        // Validate: at least one arity with at least one param
        if (arglists.items.len == 0) {
            return makeErrorStr(allocator, "Definition of function {s} in protocol {s} must take at least one arg.", .{ mname, proto_name });
        }
        for (arglists.items) |al_str| {
            // Count params in this arity (tokens between parens)
            var param_count: usize = 0;
            var in_tok = false;
            var ci: usize = 0;
            while (ci < al_str.len) : (ci += 1) {
                const c = al_str[ci];
                const is_sep = c == '(' or c == ')' or c == ' ';
                if (!is_sep and !in_tok) {
                    in_tok = true;
                    param_count += 1;
                } else if (is_sep) {
                    in_tok = false;
                }
            }
            if (param_count == 0) {
                return makeErrorStr(allocator, "Definition of function {s} in protocol {s} must take at least one arg.", .{ mname, proto_name });
            }
        }

        // Build sig map: {:name sym, :arglists ((sym ...) (sym ...)), :doc string}
        var sig_map: Value.Map = .empty;
        defer {
            for (sig_map.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(sig_map.items);
        }

        // :name
        try sig_map.append(allocator, .{
            .key = try Value.keywordValue(allocator, "name"),
            .value = try Value.symValue(allocator, mname),
        });

        // :arglists — list of lists of symbols
        var arglists_list: list.List = .empty;
        defer arglists_list.deinit(allocator);
        for (arglists.items) |al_str| {
            var al_list: list.List = .empty;
            defer al_list.deinit(allocator);
            // Parse "(this x y)" -> extract param names
            var start: usize = 0;
            var in_token = false;
            var i: usize = 0;
            while (i < al_str.len) : (i += 1) {
                const c = al_str[i];
                const is_sep = c == '(' or c == ')' or c == ' ';
                if (!is_sep and !in_token) {
                    start = i;
                    in_token = true;
                } else if (is_sep and in_token) {
                    const token = al_str[start..i];
                    if (token.len > 0) {
                        try al_list.append(allocator, try Value.symValue(allocator, token));
                    }
                    in_token = false;
                }
            }
            if (in_token) {
                const token = al_str[start..];
                if (token.len > 0) {
                    try al_list.append(allocator, try Value.symValue(allocator, token));
                }
            }
            try arglists_list.append(allocator, Value.listValue(al_list));
            // Transfer ownership: clear al_list so its defer doesn't double-free
            al_list = .empty;
        }
        try sig_map.append(allocator, .{
            .key = try Value.keywordValue(allocator, "arglists"),
            .value = Value.listValue(arglists_list),
        });
        // Transfer ownership: clear arglists_list so its defer doesn't double-free
        arglists_list = .empty;

        // :doc
        try sig_map.append(allocator, .{
            .key = try Value.keywordValue(allocator, "doc"),
            .value = if (method_doc) |doc|
                try Value.stringValue(allocator, doc)
            else
                Value.nilValue(),
        });

        try sigs.append(allocator, .{
            .key = try Value.keywordValue(allocator, mname),
            .value = Value.mapValue(sig_map),
        });
        // Transfer ownership: clear sig_map so its defer doesn't double-free
        sig_map = .empty;

        idx += 1;
    }

    // Get current namespace
    const ns_mgr = eval.findNsManager(env) orelse return error.TypeError;
    const current_ns = ns_mgr.getCurrentNamespace();

    // Build the protocol map
    var protocol_map: Value.Map = .empty;
    errdefer {
        for (protocol_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(protocol_map.items);
    }

    // :doc
    if (docstring) |doc| {
        defer allocator.free(doc);
        try protocol_map.append(allocator, .{
            .key = try Value.keywordValue(allocator, "doc"),
            .value = try Value.stringValue(allocator, doc),
        });
    }

    // :sigs
    var sigs_map: Value.Map = .empty;
    errdefer {
        for (sigs_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(sigs_map.items);
    }
    for (sigs.items) |*entry| {
        try sigs_map.append(allocator, .{
            .key = try entry.key.clone(allocator),
            .value = try entry.value.clone(allocator),
        });
    }
    try protocol_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "sigs"),
        .value = Value.mapValue(sigs_map),
    });

    // :var
    try protocol_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "var"),
        .value = try Value.symValue(allocator, proto_name),
    });

    // :method-map
    var method_map: Value.Map = .empty;
    errdefer {
        for (method_map.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(method_map.items);
    }
    for (method_names.items) |mname| {
        try method_map.append(allocator, .{
            .key = try Value.keywordValue(allocator, mname),
            .value = try Value.keywordValue(allocator, mname),
        });
    }
    try protocol_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "method-map"),
        .value = Value.mapValue(method_map),
    });

    // :impls — empty map (populated by extend)
    try protocol_map.append(allocator, .{
        .key = try Value.keywordValue(allocator, "impls"),
        .value = Value.mapValue(.empty),
    });

    // Bind the protocol map
    const persistent_proto = Value.mapValue(protocol_map);
    try env.put(proto_name, persistent_proto);

    // Create dispatch functions for each method
    // Each method has one arity per arglist from its :sigs entry
    var method_idx: usize = 0;
    for (method_names.items) |mname| {
        // Build closure env with protocol reference info
        var dispatch_env: Env = .{
            .allocator = allocator,
            .entries = phm.PersistentHashMap.empty(),
            .parent = env,
            .ns_manager = null,
        };
        try dispatch_env.put("__proto_ns", try Value.stringValue(allocator, current_ns));
        try dispatch_env.put("__proto_name", try Value.stringValue(allocator, proto_name));
        try dispatch_env.put("__method_kw", try Value.stringValue(allocator, mname));

        // Look up this method's :arglists from the sigs
        const sig_entry = sigs.items[method_idx];
        const sig_map_val = sig_entry.value;
        const arglists_entry = getMapEntry(sig_map_val, try Value.keywordValue(allocator, "arglists"));
        var arglists_val: ?Value = null;
        if (arglists_entry) |ae| {
            arglists_val = ae;
        }

        // Body: (__protocol_dispatch__) — marker for the evaluator
        var body_list: list.List = .empty;
        defer body_list.deinit(allocator);
        try body_list.append(allocator, try Value.symValue(allocator, "__protocol_dispatch__"));

        var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
        errdefer {
            for (arities.items) |*a| {
                a.params.deinit(allocator);
                a.body.deinit(allocator);
                if (a.rest_name) |rn| allocator.free(rn);
            }
            allocator.free(arities.items);
        }

        if (arglists_val) |al_val| {
            // Create one arity per arglist from :sigs
            for (al_val.list_val.items) |al_item| {
                if (al_item.type != .list) continue;
                // Build params from the arglist (list of symbols)
                var params_list: list.List = .empty;
                defer params_list.deinit(allocator);
                for (al_item.list_val.items) |param_sym| {
                    try params_list.append(allocator, try param_sym.clone(allocator));
                }

                const cloned_params = try params_list.clone(allocator);
                const cloned_body = try body_list.clone(allocator);
                try arities.append(allocator, Value.Arity{
                    .params = cloned_params,
                    .body = cloned_body,
                    .rest_name = null,
                });
            }
        }

        // Fallback: if no arglists found, use single variadic arity
        if (arities.items.len == 0) {
            var params_list: list.List = .empty;
            defer params_list.deinit(allocator);
            try params_list.append(allocator, try Value.symValue(allocator, "this"));
            const rest_name = try allocator.dupe(u8, "__rest");
            const cloned_params = try params_list.clone(allocator);
            const cloned_body = try body_list.clone(allocator);
            try arities.append(allocator, Value.Arity{
                .params = cloned_params,
                .body = cloned_body,
                .rest_name = rest_name,
            });
        }

        var fn_val = try Value.fnValue(allocator, arities, dispatch_env, false);
        const persistent_fn = try fn_val.clone(allocator);
        fn_val.deinit(allocator);

        try env.put(mname, persistent_fn);
        method_idx += 1;
    }

    return try Value.symValue(allocator, proto_name);
}

/// Evaluate a (extend atype protocol mmap & more...) form.
/// Adds method implementations to a protocol for a given type.
/// Returns nil.
pub fn evalExtend(
    allocator: Allocator,
    l: list.List,
    env: *Env,
    depth: usize,
) anyerror!Value {
    _ = depth;
    // (extend atype protocol mmap & more...)
    // l has: atype (unevaluated), protocol (evaluated), mmap (evaluated), ...
    if (l.items.len < 3) return error.ArityError;

    // Parse: atype (index 0), then pairs of (protocol mmap) at indices 1,2, 3,4, ...
    const atype = l.items[0];
    if (atype.type != .keyword) {
        return makeErrorStr(allocator, "extend: first argument must be a type keyword, got {s}", .{@tagName(atype.type)});
    }

    var idx: usize = 1;
    while (idx + 1 < l.items.len) : (idx += 2) {
        const protocol_val = l.items[idx];
        const mmap = l.items[idx + 1];

        // Validate protocol is a protocol (has :sigs key)
        var sigs_kw = try Value.keywordValue(allocator, "sigs");
        defer sigs_kw.deinit(allocator);
        if (getMapEntry(protocol_val, sigs_kw) == null) {
            return makeErrorStr(allocator, "extend: {s} is not a protocol", .{formatValueShort(protocol_val)});
        }

        // Get protocol var name from :var
        var var_kw = try Value.keywordValue(allocator, "var");
        defer var_kw.deinit(allocator);
        const var_sym_val = getMapEntry(protocol_val, var_kw) orelse {
            return makeErrorStr(allocator, "extend: protocol missing :var metadata", .{});
        };
        if (var_sym_val.type != .symbol) {
            return makeErrorStr(allocator, "extend: protocol :var is not a symbol", .{});
        }
        const proto_name = var_sym_val.sym_val;

        // Get the namespace from the protocol's :var or find it
        // We need to find which namespace has this protocol
        const ns_mgr = eval.findNsManager(env) orelse return error.TypeError;

        // Find the namespace that contains this protocol
        var proto_ns_env: ?*Env = null;
        var proto_ns_name: []const u8 = undefined;
        var it = ns_mgr.namespaces.entryIterator();
        while (it.next()) |ns_entry| {
            // ns_entry.key is Value.symbol (namespace name), ns_entry.val is Value.wrapped (*Env)
            if (ns_entry.val.type == .wrapped) {
                const ns_env_ptr: *Env = Value.unwrapPtr(*Env, ns_entry.val);
                if (ns_env_ptr.get(proto_name)) |found| {
                    _ = found;
                    proto_ns_env = ns_env_ptr;
                    if (ns_entry.key.type == .symbol) {
                        proto_ns_name = ns_entry.key.sym_val;
                    }
                    break;
                }
            }
        }
        if (proto_ns_env == null) {
            return makeErrorStr(allocator, "extend: protocol '{s}' not found in any namespace", .{proto_name});
        }

        // Get the current protocol map from the namespace
        const current_proto = proto_ns_env.?.get(proto_name) orelse {
            return makeErrorStr(allocator, "extend: protocol '{s}' not found in namespace '{s}'", .{ proto_name, proto_ns_name });
        };

        // Build new protocol map with updated :impls
        const new_proto = try updateProtocolImpls(allocator, current_proto, atype, mmap);

        // Rebind in the namespace
        try proto_ns_env.?.put(proto_name, new_proto);
    }

    return Value.nilValue();
}

/// Update a protocol map's :impls with new implementations for a type.
/// Returns a new protocol map (original is unchanged).
fn updateProtocolImpls(
    allocator: Allocator,
    protocol_val: Value,
    atype: Value,
    mmap: Value,
) anyerror!Value {
    if (protocol_val.type != .map) return error.TypeError;

    // Get current :impls map
    var impls_kw = try Value.keywordValue(allocator, "impls");
    const current_impls = getMapEntry(protocol_val, impls_kw);
    // Don't deinit impls_kw — GC manages it, and the keyword may be referenced
    var impls: Value.Map = .empty;
    if (current_impls) |impls_val| {
        if (impls_val.type == .map) {
            // Clone existing impls
            for (impls_val.map_val.items) |entry| {
                try impls.append(allocator, .{
                    .key = try entry.key.clone(allocator),
                    .value = try entry.value.clone(allocator),
                });
            }
        }
    }
    impls_kw.deinit(allocator);

    // Get or create the type's method map
    const atype_clone = try atype.clone(allocator);
    const existing_type_methods = getMapEntry(Value.mapValue(impls), atype_clone);
    var type_methods: Value.Map = .empty;
    if (existing_type_methods) |tm| {
        if (tm.type == .map) {
            for (tm.map_val.items) |entry| {
                try type_methods.append(allocator, .{
                    .key = try entry.key.clone(allocator),
                    .value = try entry.value.clone(allocator),
                });
            }
        }
    }

    // Merge new method implementations from mmap
    if (mmap.type == .map) {
        for (mmap.map_val.items) |entry| {
            try type_methods.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
    }

    // Update impls with the type's methods
    // First remove existing entry for this type if any
    var new_impls: Value.Map = .empty;
    errdefer {
        for (new_impls.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_impls.items);
    }
    for (impls.items) |entry| {
        if (!entry.key.equals(atype_clone)) {
            try new_impls.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
    }
    // Add the updated type methods
    try new_impls.append(allocator, .{
        .key = atype_clone,
        .value = Value.mapValue(type_methods),
    });
    // impls items are now owned by new_impls or abandoned (same allocator)
    impls = .empty;

    // Build new protocol map
    var new_protocol: Value.Map = .empty;
    errdefer {
        for (new_protocol.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(new_protocol.items);
    }
    for (protocol_val.map_val.items) |entry| {
        // Skip :impls — we'll add our own
        const is_impls = entry.key.type == .keyword and std.mem.eql(u8, entry.key.kw_val, "impls");
        if (!is_impls) {
            try new_protocol.append(allocator, .{
                .key = try entry.key.clone(allocator),
                .value = try entry.value.clone(allocator),
            });
        }
    }
    try new_protocol.append(allocator, .{
        .key = try Value.keywordValue(allocator, "impls"),
        .value = Value.mapValue(new_impls),
    });
    new_impls = .empty;

    return Value.mapValue(new_protocol);
}

/// Format a value briefly for error messages.
fn formatValueShort(v: Value) []const u8 {
    return switch (v.type) {
        .nil => "nil",
        .bool => if (v.bool_val) "true" else "false",
        .string => "(string)",
        .symbol => v.sym_val,
        .keyword => v.kw_val,
        else => @tagName(v.type),
    };
}

/// Evaluate a (extend-type atype protocol (method [params] body...)+ & more...) form.
/// Builds fn values for each method and calls extend internally.
pub fn evalExtendType(
    allocator: Allocator,
    l: list.List,
    env: *Env,
    depth: usize,
) anyerror!Value {
    // (extend-type atype protocol (method [params] body...)+ & more...)
    if (l.items.len < 3) return error.ArityError;

    // atype is unevaluated (a keyword)
    const atype = l.items[1];
    if (atype.type != .keyword) {
        return makeErrorStr(allocator, "extend-type: first argument must be a type keyword", .{});
    }

    // Parse specs: pairs of (protocol methods...)
    // We need to group methods by protocol
    var idx: usize = 2;
    var extend_args: list.List = .empty;
    errdefer extend_args.deinit(allocator);

    // Add atype as first arg (unevaluated)
    try extend_args.append(allocator, try atype.clone(allocator));

    while (idx < l.items.len) {
        // Evaluate the protocol
        const proto_ptr = try eval.evalRec(allocator, l.items[idx], env, depth + 1);
        try extend_args.append(allocator, proto_ptr.*);

        // Collect method definitions until next protocol or end
        idx += 1;
        var method_defs: std.ArrayListUnmanaged(usize) = .empty;
        defer allocator.free(method_defs.items);

        while (idx < l.items.len) {
            const item = l.items[idx];
            // Check if this looks like a method def (list starting with a symbol)
            // or a protocol reference (symbol, keyword, or evaluated value)
            if (item.type == .list and item.list_val.items.len >= 1 and
                item.list_val.items[0].type == .symbol)
            {
                // Check if next item after this is also a method def or a protocol
                // A method def is a list starting with a symbol
                // A protocol is typically a symbol that resolves to a protocol
                try method_defs.append(allocator, idx);
                idx += 1;
            } else {
                break;
            }
        }

        // Build method map for this protocol
        // Group method definitions by name to support multi-arity methods
        var mmap: Value.Map = .empty;
        errdefer {
            for (mmap.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(mmap.items);
        }

        // Collect unique method names (preserving order)
        var unique_names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (unique_names.items) |n| allocator.free(n);
            allocator.free(unique_names.items);
        }

        for (method_defs.items) |mi| {
            const mdef = l.items[mi];
            if (mdef.type != .list or mdef.list_val.items.len < 2) return error.TypeError;
            const mname_sym = mdef.list_val.items[0];
            if (mname_sym.type != .symbol) return error.TypeError;
            const mname = mname_sym.sym_val;

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

        // For each unique method name, collect all arities and build a multi-arity fn
        for (unique_names.items) |mname| {
            // fn form: (fn arity1 arity2 ...) where arity = ([params] body...)
            var fn_form: list.List = .empty;
            defer fn_form.deinit(allocator);
            try fn_form.append(allocator, try Value.symValue(allocator, "fn"));

            // For each method definition of this name, build an arity form
            for (method_defs.items) |mi| {
                const mdef = l.items[mi];
                const mname_sym = mdef.list_val.items[0];
                if (mname_sym.type != .symbol) continue;
                if (!std.mem.eql(u8, mname_sym.sym_val, mname)) continue;

                // items[1:] of the method def: [params] body...
                // Build arity form: ([params] body...)
                var arity_form: list.List = .empty;
                defer arity_form.deinit(allocator);
                const def_items = mdef.list_val.items[1..];
                for (def_items) |item| {
                    try arity_form.append(allocator, try item.clone(allocator));
                }
                // Append arity form directly to fn_form (not wrapped)
                try fn_form.append(allocator, Value.listValue(arity_form));
                arity_form = .empty;
            }

            // Evaluate to get a function value
            const fn_ptr = try eval.evalRec(allocator, Value.listValue(fn_form), env, depth + 1);
            fn_form = .empty;
            const persistent_fn = try fn_ptr.*.clone(allocator);
            fn_ptr.*.deinit(allocator);

            try mmap.append(allocator, .{
                .key = try Value.keywordValue(allocator, mname),
                .value = persistent_fn,
            });
        }

        try extend_args.append(allocator, Value.mapValue(mmap));
        mmap = .empty;
    }

    // Now call extend with the built args
    return evalExtend(allocator, extend_args, env, depth);
}

// Import helpers for listFromVector
const helpers = @import("helpers.zig");

/// Evaluate a (extend-protocol protocol atype1 (method [params] body...)+ atype2 ...)
/// form.
/// Groups methods by type and delegates to evalExtend for each group.
pub fn evalExtendProtocol(
    allocator: Allocator,
    l: list.List,
    env: *Env,
    depth: usize,
) anyerror!Value {
    // (extend-protocol protocol atype1 (method [params] body...)+ atype2 ...)
    if (l.items.len < 3) return error.ArityError;

    // Evaluate the protocol (index 1)
    const proto_ptr = try eval.evalRec(allocator, l.items[1], env, depth + 1);
    defer proto_ptr.*.deinit(allocator);

    // Validate it's a protocol
    var sigs_kw = try Value.keywordValue(allocator, "sigs");
    defer sigs_kw.deinit(allocator);
    if (getMapEntry(proto_ptr.*, sigs_kw) == null) {
        return makeErrorStr(allocator, "extend-protocol: {s} is not a protocol", .{formatValueShort(proto_ptr.*)});
    }

    // Parse: alternating type-keyword and method definitions
    var idx: usize = 2;
    var result: Value = Value.nilValue();

    while (idx < l.items.len) {
        // Get the type keyword (unevaluated)
        const atype = l.items[idx];
        if (atype.type != .keyword) {
            return makeErrorStr(allocator, "extend-protocol: type must be a keyword, got {s}", .{@tagName(atype.type)});
        }
        idx += 1;

        // Collect method definitions until next type keyword or end
        const method_start = idx;
        while (idx < l.items.len) {
            const item = l.items[idx];
            if (item.type == .keyword) {
                break;
            }
            idx += 1;
        }
        const method_end = idx;

        // Build a method map by evaluating method definitions into fns
        // Group method definitions by name to support multi-arity methods
        var mmap: Value.Map = .empty;
        errdefer {
            for (mmap.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(mmap.items);
        }

        // Collect unique method names
        var unique_names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (unique_names.items) |n| allocator.free(n);
            allocator.free(unique_names.items);
        }

        var mi: usize = method_start;
        while (mi < method_end) : (mi += 1) {
            const mdef = l.items[mi];
            if (mdef.type != .list or mdef.list_val.items.len < 2) return error.TypeError;
            const mname_sym = mdef.list_val.items[0];
            if (mname_sym.type != .symbol) return error.TypeError;
            const mname = mname_sym.sym_val;

            var found = false;
            for (unique_names.items) |existing| {
                if (std.mem.eql(u8, existing, mname)) { found = true; break; }
            }
            if (!found) {
                try unique_names.append(allocator, try allocator.dupe(u8, mname));
            }
        }

        // For each unique method name, collect all arities and build a multi-arity fn
        for (unique_names.items) |mname| {
            // fn form: (fn arity1 arity2 ...) where arity = ([params] body...)
            var fn_form: list.List = .empty;
            defer fn_form.deinit(allocator);
            try fn_form.append(allocator, try Value.symValue(allocator, "fn"));

            mi = method_start;
            while (mi < method_end) : (mi += 1) {
                const mdef = l.items[mi];
                const mname_sym = mdef.list_val.items[0];
                if (mname_sym.type != .symbol) continue;
                if (!std.mem.eql(u8, mname_sym.sym_val, mname)) continue;

                // items[1:] of the method def: [params] body...
                const def_items = mdef.list_val.items[1..];
                var arity_form: list.List = .empty;
                defer arity_form.deinit(allocator);
                for (def_items) |item| {
                    try arity_form.append(allocator, try item.clone(allocator));
                }
                try fn_form.append(allocator, Value.listValue(arity_form));
                arity_form = .empty;
            }

            const fn_ptr = try eval.evalRec(allocator, Value.listValue(fn_form), env, depth + 1);
            fn_form = .empty;
            const persistent_fn = try fn_ptr.*.clone(allocator);
            fn_ptr.*.deinit(allocator);

            try mmap.append(allocator, .{
                .key = try Value.keywordValue(allocator, mname),
                .value = persistent_fn,
            });
        }

        // Build extend args: atype (unevaluated), protocol (evaluated), mmap (evaluated)
        var ext_args: list.List = .empty;
        defer ext_args.deinit(allocator);
        try ext_args.append(allocator, try atype.clone(allocator));
        try ext_args.append(allocator, try proto_ptr.*.clone(allocator));
        try ext_args.append(allocator, Value.mapValue(mmap));
        mmap = .empty;

        // Call evalExtend directly
        result.deinit(allocator);
        result = try evalExtend(allocator, ext_args, env, depth + 1);
        ext_args = .empty;
    }

    return result;
}
