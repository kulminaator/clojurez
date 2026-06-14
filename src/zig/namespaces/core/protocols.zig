// Protocol support: dispatch helper and defprotocol evaluation support
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const Env = Value.Env;
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
    arena_alloc: Allocator,
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
    const impls_kw = try Value.keywordValue(arena_alloc, "impls");
    const impls_map = getMapEntry(protocol_map_val, impls_kw) orelse {
        const type_kw = typeKeyword(target);
        return makeErrorStr(allocator, "No implementation of method: :{s} of protocol: #{{'{s}/{s} found for type: {s}", .{ method_kw, proto_ns, proto_name, type_kw });
    };

    // Get type keyword for the dispatch target
    const type_kw_str = typeKeyword(target);
    const type_kw = try Value.keywordValue(arena_alloc, type_kw_str);

    // Look up impl for this type in the impls map
    const type_impls = getMapEntry(impls_map, type_kw) orelse {
        return makeErrorStr(allocator, "No implementation of method: :{s} of protocol: #{{'{s}/{s} found for type: {s}", .{ method_kw, proto_ns, proto_name, type_kw_str });
    };

    // Look up the method function in the type's impl map
    const method_kw_full = try Value.keywordValue(arena_alloc, method_kw);
    const impl_fn = getMapEntry(type_impls, method_kw_full) orelse {
        return makeErrorStr(allocator, "No implementation of method: :{s} of protocol: #{{'{s}/{s} found for type: {s}", .{ method_kw, proto_ns, proto_name, type_kw_str });
    };

    // Call the implementation function with all arguments
    const call_env: *Env = @constCast(proto_env);
    return eval.call(allocator, arena_alloc, impl_fn, args, call_env, depth);
}

/// Evaluate a (defprotocol ...) form.
/// Returns the protocol name symbol.
pub fn evalDefProtocol(
    allocator: Allocator,
    arena_alloc: Allocator,
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
            entry.key.deinit(arena_alloc);
            entry.value.deinit(arena_alloc);
        }
        arena_alloc.free(sigs.items);
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
            for (arglists.items) |a| arena_alloc.free(a);
            arena_alloc.free(arglists.items);
        }

        var method_doc: ?[]const u8 = null;

        var ai: usize = 1;
        while (ai < sig_list.items.len) : (ai += 1) {
            const item = sig_list.items[ai];
            if (item.type == .vector) {
                // Build arglist like "(this x y)"
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer arena_alloc.free(buf.items);
                try buf.append(arena_alloc, '(');
                var first_param = true;
                for (item.vec_val.items) |param| {
                    if (!first_param) try buf.append(arena_alloc, ' ');
                    first_param = false;
                    if (param.type == .symbol) {
                        try buf.appendSlice(arena_alloc, param.sym_val);
                    } else {
                        try buf.appendSlice(arena_alloc, "x");
                    }
                }
                try buf.append(arena_alloc, ')');
                try arglists.append(arena_alloc, try arena_alloc.dupe(u8, buf.items));
            } else if (item.type == .string) {
                method_doc = try arena_alloc.dupe(u8, item.str_val);
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
                entry.key.deinit(arena_alloc);
                entry.value.deinit(arena_alloc);
            }
            arena_alloc.free(sig_map.items);
        }

        // :name
        try sig_map.append(arena_alloc, .{
            .key = try Value.keywordValue(arena_alloc, "name"),
            .value = try Value.symValue(arena_alloc, mname),
        });

        // :arglists — list of lists of symbols
        var arglists_list: list.List = .empty;
        defer arglists_list.deinit(arena_alloc);
        for (arglists.items) |al_str| {
            var al_list: list.List = .empty;
            defer al_list.deinit(arena_alloc);
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
                        try al_list.append(arena_alloc, try Value.symValue(arena_alloc, token));
                    }
                    in_token = false;
                }
            }
            if (in_token) {
                const token = al_str[start..];
                if (token.len > 0) {
                    try al_list.append(arena_alloc, try Value.symValue(arena_alloc, token));
                }
            }
            try arglists_list.append(arena_alloc, Value.listValue(al_list));
            // Transfer ownership: clear al_list so its defer doesn't double-free
            al_list = .empty;
        }
        try sig_map.append(arena_alloc, .{
            .key = try Value.keywordValue(arena_alloc, "arglists"),
            .value = Value.listValue(arglists_list),
        });
        // Transfer ownership: clear arglists_list so its defer doesn't double-free
        arglists_list = .empty;

        // :doc
        try sig_map.append(arena_alloc, .{
            .key = try Value.keywordValue(arena_alloc, "doc"),
            .value = if (method_doc) |doc|
                try Value.stringValue(arena_alloc, doc)
            else
                Value.nilValue(),
        });

        try sigs.append(arena_alloc, .{
            .key = try Value.keywordValue(arena_alloc, mname),
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
    for (method_names.items) |mname| {
        // Build closure env with protocol reference info
        var dispatch_env: Env = .{
            .allocator = allocator,
            .entries = .empty,
            .parent = env,
            .ns_manager = null,
        };
        try dispatch_env.put("__proto_ns", try Value.stringValue(allocator, current_ns));
        try dispatch_env.put("__proto_name", try Value.stringValue(allocator, proto_name));
        try dispatch_env.put("__method_kw", try Value.stringValue(allocator, mname));

        // Body: (__protocol_dispatch__) — marker for the evaluator
        var body_list: list.List = .empty;
        defer body_list.deinit(allocator);
        try body_list.append(allocator, try Value.symValue(allocator, "__protocol_dispatch__"));

        // Params: (this & __rest) — variadic, at least one arg
        var params_list: list.List = .empty;
        defer params_list.deinit(allocator);
        try params_list.append(allocator, try Value.symValue(allocator, "this"));

        const rest_name = try allocator.dupe(u8, "__rest");

        var arities: std.ArrayListUnmanaged(Value.Arity) = .empty;
        errdefer {
            for (arities.items) |*a| {
                a.params.deinit(allocator);
                a.body.deinit(allocator);
                if (a.rest_name) |rn| allocator.free(rn);
            }
            allocator.free(arities.items);
        }

        const cloned_params = try params_list.clone(allocator);
        const cloned_body = try body_list.clone(allocator);
        try arities.append(allocator, Value.Arity{
            .params = cloned_params,
            .body = cloned_body,
            .rest_name = rest_name,
        });

        var fn_val = Value.fnValue(arities, dispatch_env, false);
        const persistent_fn = try fn_val.clone(allocator);
        fn_val.deinit(allocator);

        try env.put(mname, persistent_fn);
    }

    return try Value.symValue(allocator, proto_name);
}

/// Evaluate a (extend atype protocol mmap & more...) form.
/// Adds method implementations to a protocol for a given type.
/// Returns nil.
pub fn evalExtend(
    allocator: Allocator,
    arena_alloc: Allocator,
    l: list.List,
    env: *Env,
    depth: usize,
) anyerror!Value {
    _ = arena_alloc;
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
        var it = ns_mgr.namespaces.iterator();
        while (it.next()) |ns_entry| {
            const ns_env_ptr = ns_entry.value_ptr.*;
            if (ns_env_ptr.get(proto_name)) |found| {
                _ = found;
                proto_ns_env = ns_env_ptr;
                proto_ns_name = ns_entry.key_ptr.*;
                break;
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
    arena_alloc: Allocator,
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
    errdefer extend_args.deinit(arena_alloc);

    // Add atype as first arg (unevaluated)
    try extend_args.append(arena_alloc, try atype.clone(arena_alloc));

    while (idx < l.items.len) {
        // Evaluate the protocol
        const proto_val = try eval.evalRec(allocator, arena_alloc, l.items[idx], env, depth + 1);
        try extend_args.append(arena_alloc, proto_val);

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
        var mmap: Value.Map = .empty;
        errdefer {
            for (mmap.items) |*entry| {
                entry.key.deinit(allocator);
                entry.value.deinit(allocator);
            }
            allocator.free(mmap.items);
        }

        for (method_defs.items) |mi| {
            const mdef = l.items[mi];
            if (mdef.type != .list or mdef.list_val.items.len < 2) return error.TypeError;

            const mname_sym = mdef.list_val.items[0];
            if (mname_sym.type != .symbol) return error.TypeError;
            const mname = mname_sym.sym_val;

            // Method def: (name [params] body...)
            // Build (fn ([params] body...)) by wrapping items[1:] in a list
            const arities = mdef.list_val.items[1..];

            var fn_form: list.List = .empty;
            defer fn_form.deinit(arena_alloc);
            try fn_form.append(arena_alloc, try Value.symValue(allocator, "fn"));

            var arity_wrapper: list.List = .empty;
            defer arity_wrapper.deinit(arena_alloc);
            for (arities) |a| {
                try arity_wrapper.append(arena_alloc, try a.clone(arena_alloc));
            }
            try fn_form.append(arena_alloc, Value.listValue(arity_wrapper));

            // Evaluate to get a function value
            var fn_val = try eval.evalRec(allocator, arena_alloc, Value.listValue(fn_form), env, depth + 1);
            const persistent_fn = try fn_val.clone(allocator);
            fn_val.deinit(arena_alloc);

            try mmap.append(allocator, .{
                .key = try Value.keywordValue(allocator, mname),
                .value = persistent_fn,
            });
        }

        try extend_args.append(arena_alloc, Value.mapValue(mmap));
        mmap = .empty;
    }

    // Now call extend with the built args
    return evalExtend(allocator, arena_alloc, extend_args, env, depth);
}

// Import helpers for listFromVector
const helpers = @import("helpers.zig");
