// Namespace built-in functions: find-ns, create-ns, all-ns, the-ns,
// ns-resolve, resolve, refer, alias, ns-aliases, ns-unalias, require, loaded-libs
// Plus Phase 4: ns-publics, ns-interns, ns-refers, ns-map, ns-unmap, intern
// Plus Phase 5: load-string, remove-ns
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const eval_ns = @import("../../eval_ns.zig");
const gc_mod = @import("../../gc.zig");
const eval_mod = @import("../../eval.zig");
const parser = @import("../../parser.zig");
const phm = @import("../../persistent_hash_map.zig");

const Allocator = std.mem.Allocator;

/// Build a namespace map {:name sym, :interns map, :refers map, :aliases map}
fn buildNsMap(allocator: Allocator, ns_name: []const u8, ns_env: *Env, ns_mgr: *vm.NamespaceManager) anyerror!Value {
    var result_map: vm.Map = .empty;
    errdefer {
        for (result_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(result_map.items);
    }

    // :name → symbol
    try result_map.append(allocator, .{
        .key = try vm.keywordValue(allocator, "name"),
        .value = try vm.symValue(allocator, ns_name),
    });

    // :interns → map of owned symbols (not referred)
    var interns_map: vm.Map = .empty;
    errdefer {
        for (interns_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(interns_map.items);
    }
    var it = ns_env.entries.entryIterator();
    while (it.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        // Skip referred names — interns are only owned vars
        if (eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        try interns_map.append(allocator, .{
            .key = try vm.symValue(allocator, sym_name),
            .value = try vm.clone(&entry.val, allocator),
        });
    }
    try result_map.append(allocator, .{
        .key = try vm.keywordValue(allocator, "interns"),
        .value = try vm.mapValue(allocator, interns_map),
    });

    // :refers → map of referred symbols
    var refers_map: vm.Map = .empty;
    errdefer {
        for (refers_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(refers_map.items);
    }
    var it2 = ns_env.entries.entryIterator();
    while (it2.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        // Only include referred names
        if (!eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        try refers_map.append(allocator, .{
            .key = try vm.symValue(allocator, sym_name),
            .value = try vm.clone(&entry.val, allocator),
        });
    }
    try result_map.append(allocator, .{
        .key = try vm.keywordValue(allocator, "refers"),
        .value = try vm.mapValue(allocator, refers_map),
    });

    // :aliases → map of alias symbol → target namespace symbol
    var aliases_map: vm.Map = .empty;
    errdefer {
        for (aliases_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(aliases_map.items);
    }
    var it3 = ns_mgr.aliases.entryIterator();
    while (it3.next()) |entry| {
        const composite_key = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        // Parse "ns_name/alias_name" composite key
        if (std.mem.indexOfScalar(u8, composite_key, '/')) |slash_idx| {
            const key_ns_name = composite_key[0..slash_idx];
            const alias_name = composite_key[slash_idx + 1 ..];
            if (std.mem.eql(u8, key_ns_name, ns_name)) {
                // This alias belongs to our namespace
                const target_ns = if (std.meta.activeTag(entry.val) == .string) entry.val.string else continue;
                try aliases_map.append(allocator, .{
                    .key = try vm.symValue(allocator, alias_name),
                    .value = try vm.symValue(allocator, target_ns),
                });
            }
        }
    }
    try result_map.append(allocator, .{
        .key = try vm.keywordValue(allocator, "aliases"),
        .value = try vm.mapValue(allocator, aliases_map),
    });

    return try vm.mapValue(allocator, result_map);
}

/// Build a Namespace record {:name sym, :interns map, :refers map, :aliases map}
/// Returns a record with type_name "clojure.core.Namespace" so Object/toString dispatches correctly.
fn buildNsRecord(allocator: Allocator, ns_name: []const u8, ns_env: *Env, ns_mgr: *vm.NamespaceManager) anyerror!Value {
    // Build fields map
    var fields: vm.Map = .empty;
    errdefer {
        for (fields.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(fields.items);
    }

    // :name → symbol
    try fields.append(allocator, .{
        .key = try vm.keywordValue(allocator, "name"),
        .value = try vm.symValue(allocator, ns_name),
    });

    // :interns → map of owned symbols (not referred)
    var interns_map: vm.Map = .empty;
    errdefer {
        for (interns_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(interns_map.items);
    }
    var it = ns_env.entries.entryIterator();
    while (it.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        if (eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        try interns_map.append(allocator, .{
            .key = try vm.symValue(allocator, sym_name),
            .value = try vm.clone(&entry.val, allocator),
        });
    }
    try fields.append(allocator, .{
        .key = try vm.keywordValue(allocator, "interns"),
        .value = try vm.mapValue(allocator, interns_map),
    });

    // :refers → map of referred symbols
    var refers_map: vm.Map = .empty;
    errdefer {
        for (refers_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(refers_map.items);
    }
    var it2 = ns_env.entries.entryIterator();
    while (it2.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        if (!eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        try refers_map.append(allocator, .{
            .key = try vm.symValue(allocator, sym_name),
            .value = try vm.clone(&entry.val, allocator),
        });
    }
    try fields.append(allocator, .{
        .key = try vm.keywordValue(allocator, "refers"),
        .value = try vm.mapValue(allocator, refers_map),
    });

    // :aliases → map of alias symbol → target namespace symbol
    var aliases_map: vm.Map = .empty;
    errdefer {
        for (aliases_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(aliases_map.items);
    }
    var it3 = ns_mgr.aliases.entryIterator();
    while (it3.next()) |entry| {
        const composite_key = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        if (std.mem.indexOfScalar(u8, composite_key, '/')) |slash_idx| {
            const key_ns_name = composite_key[0..slash_idx];
            const alias_name = composite_key[slash_idx + 1 ..];
            if (std.mem.eql(u8, key_ns_name, ns_name)) {
                const target_ns = if (std.meta.activeTag(entry.val) == .string) entry.val.string else continue;
                try aliases_map.append(allocator, .{
                    .key = try vm.symValue(allocator, alias_name),
                    .value = try vm.symValue(allocator, target_ns),
                });
            }
        }
    }
    try fields.append(allocator, .{
        .key = try vm.keywordValue(allocator, "aliases"),
        .value = try vm.mapValue(allocator, aliases_map),
    });

    // Create record with type "clojure.core.Namespace"
    return try vm.recordValue(allocator, "clojure.core.Namespace", fields, .empty, null);
}

/// Extract namespace name from a namespace argument (symbol, ns-map, or ns-record).
fn extractNsNameFromArg(arg: Value) ?[]const u8 {
    return switch (std.meta.activeTag(arg)) {
        .symbol => arg.symbol,
        .map => blk: {
            for (arg.map.entries.items) |entry| {
                if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, "name")) {
                    if (std.meta.activeTag(entry.value) == .symbol) break :blk entry.value.symbol;
                    break :blk "";
                }
            }
            break :blk "";
        },
        .record => blk: {
            for (arg.record.fields.items) |entry| {
                if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, "name")) {
                    if (std.meta.activeTag(entry.value) == .symbol) break :blk entry.value.symbol;
                    break :blk "";
                }
            }
            break :blk "";
        },
        else => null,
    };
}

/// find-ns: (find-ns sym-or-ns) → namespace-object or nil
/// Returns the namespace named by the symbol, or nil if it doesn't exist.
pub fn core_find_ns(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const arg = args.items[0];
    const ns_name: ?[]const u8 = extractNsNameFromArg(arg);
    const name_str = ns_name orelse return vm.nilValue();
    if (name_str.len == 0) return vm.nilValue();

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return vm.nilValue();
    const ns_env = ns_mgr.getNamespace(name_str) orelse return vm.nilValue();

    return try buildNsRecord(allocator, name_str, ns_env, ns_mgr);
}

/// create-ns: (create-ns sym) → namespace-object
/// Creates a new namespace named by sym if one doesn't exist.
/// Returns the namespace object (new or existing).
pub fn core_create_ns(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .symbol) return error.TypeError;
    const ns_name = arg.symbol;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;

    // Create or get existing namespace
    const ns_env = try ns_mgr.createNamespace(ns_name);
    // Register as permanent root — namespaces must never be swept by GC.
    if (gc_mod.current_gc) |gc| {
        gc.addPermanentRoot(@as(*anyopaque, @ptrCast(ns_env)));
    }

    // Set parent to clojure.core if not already set (matching ns form behavior)
    if (ns_env.parent == null and !std.mem.eql(u8, ns_name, "clojure.core")) {
        const clojure_core = ns_mgr.getNamespace("clojure.core");
        if (clojure_core) |core_env| {
            ns_env.parent = core_env;
        }
    }

    return try buildNsRecord(allocator, ns_name, ns_env, ns_mgr);
}

/// all-ns: (all-ns) → sequence-of-namespace-objects
/// Returns a sequence of all namespace maps.
pub fn core_all_ns(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = args;
    const allocator = env_env.allocator;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return try vm.listValue(env_env.allocator, list.empty());

    var result_list: list.List = .empty;
    errdefer result_list.deinit(allocator);

    var it = ns_mgr.namespaces.entryIterator();
    while (it.next()) |entry| {
        const ns_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        const ns_env = entry.val;
        if (std.meta.activeTag(ns_env) != .wrapped) continue;
        const env_ptr: *Env = vm.unwrapPtr(*Env, ns_env);
        const ns_record = try buildNsRecord(allocator, ns_name, env_ptr, ns_mgr);
        try result_list.append(allocator, ns_record);
    }

    return try vm.listValue(allocator, result_list);
}

/// the-ns: (the-ns x) → namespace-object or error
/// Like find-ns but returns an error if not found.
pub fn core_the_ns(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const arg = args.items[0];
    const ns_name: ?[]const u8 = extractNsNameFromArg(arg);
    const name_str = ns_name orelse return error.TypeError;
    if (name_str.len == 0) return error.UndefinedNamespace;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.UndefinedNamespace;
    const ns_env = ns_mgr.getNamespace(name_str) orelse return error.UndefinedNamespace;

    return try buildNsRecord(allocator, name_str, ns_env, ns_mgr);
}

/// Extract namespace name from a namespace argument (symbol or ns-map).
/// Returns null if the argument is not a valid namespace reference.
fn extractNsName(arg: Value) ?[]const u8 {
    return switch (std.meta.activeTag(arg)) {
        .symbol => arg.symbol,
        .map => blk: {
            for (arg.map.entries.items) |entry| {
                if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, "name")) {
                    if (std.meta.activeTag(entry.value) == .symbol) break :blk entry.value.symbol;
                }
            }
            break :blk null;
        },
        .record => blk: {
            for (arg.record.fields.items) |entry| {
                if (std.meta.activeTag(entry.key) == .keyword and std.mem.eql(u8, entry.key.keyword, "name")) {
                    if (std.meta.activeTag(entry.value) == .symbol) break :blk entry.value.symbol;
                }
            }
            break :blk null;
        },
        else => null,
    };
}

/// Build a map of aliases for a specific namespace.
fn buildAliasesMap(allocator: Allocator, ns_name: []const u8, ns_mgr: *vm.NamespaceManager) anyerror!Value {
    var aliases_map: vm.Map = .empty;
    errdefer {
        for (aliases_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(aliases_map.items);
    }
    var it = ns_mgr.aliases.entryIterator();
    while (it.next()) |entry| {
        const composite_key = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        if (std.mem.indexOfScalar(u8, composite_key, '/')) |slash_idx| {
            const key_ns_name = composite_key[0..slash_idx];
            const alias_name = composite_key[slash_idx + 1 ..];
            if (std.mem.eql(u8, key_ns_name, ns_name)) {
                const target_ns = if (std.meta.activeTag(entry.val) == .string) entry.val.string else continue;
                try aliases_map.append(allocator, .{
                    .key = try vm.symValue(allocator, alias_name),
                    .value = try vm.symValue(allocator, target_ns),
                });
            }
        }
    }
    return try vm.mapValue(allocator, aliases_map);
}

/// ns-resolve: (ns-resolve ns sym) → value or nil
/// Resolves a symbol in the given namespace.
/// Handles unqualified, alias/name, and ns/name qualified symbols.
pub fn core_ns_resolve(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;

    const ns_arg = args.items[0];
    const sym_arg = args.items[1];
    // Optional 2nd arg (env) is ignored

    // Extract namespace name
    const ns_name = extractNsName(ns_arg) orelse return vm.nilValue();

    // Get the namespace manager
    const ns_mgr = eval_ns.findNsManager(env_env) orelse return vm.nilValue();
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return vm.nilValue();

    // Get the symbol name to resolve
    const sym_str = if (std.meta.activeTag(sym_arg) == .symbol) sym_arg.symbol else return vm.nilValue();

    // Check for qualified symbol (contains '/')
    if (std.mem.indexOfScalar(u8, sym_str, '/')) |slash_idx| {
        const prefix = sym_str[0..slash_idx];
        const name = sym_str[slash_idx + 1 ..];

        // Try resolving prefix as an alias in the namespace, or use it as a direct ns name
        const target_ns_name = ns_mgr.resolveAlias(ns_name, prefix) orelse prefix;
        const target_env = ns_mgr.getNamespace(target_ns_name) orelse return vm.nilValue();
        const val = target_env.get(name);
        if (val) |v| return try vm.clone(&v, allocator);
        return vm.nilValue();
    }

    // Unqualified symbol: look up in namespace's env chain
    const val = ns_env.get(sym_str);
    if (val) |v| return try vm.clone(&v, allocator);
    return vm.nilValue();
}

/// refer: (refer ns-sym & filters)
/// Refers vars from ns-sym into the current namespace.
/// Filters: :exclude [syms], :only [syms], :rename {from to}, :refer :all
pub fn core_refer(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len < 1) return error.ArityError;

    const ns_arg = args.items[0];
    const source_ns_name = extractNsName(ns_arg) orelse return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const current_ns = ns_mgr.getCurrentNamespace();
    const target_env = ns_mgr.getNamespace(current_ns) orelse return error.TypeError;
    const source_env = ns_mgr.getNamespace(source_ns_name) orelse return error.TypeError;

    // Parse filter arguments
    var refer_all: bool = false;
    var refer_syms: ?[]const Value = null;
    var exclude_syms: ?[]const Value = null;
    var rename_map: ?vm.Map = null;

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const kw = args.items[i];
        if (std.meta.activeTag(kw) != .keyword) continue;
        if (i + 1 >= args.items.len) continue;
        i += 1;
        const val = args.items[i];

        if (std.mem.eql(u8, kw.keyword, "exclude")) {
            exclude_syms = switch (std.meta.activeTag(val)) {
                .list => val.list.items.items,
                .vector => val.vector.items.items,
                else => continue,
            };
        } else if (std.mem.eql(u8, kw.keyword, "only")) {
            refer_syms = switch (std.meta.activeTag(val)) {
                .list => val.list.items.items,
                .vector => val.vector.items.items,
                else => continue,
            };
        } else if (std.mem.eql(u8, kw.keyword, "refer")) {
            if (std.meta.activeTag(val) == .keyword and std.mem.eql(u8, val.keyword, "all")) {
                refer_all = true;
            } else {
                refer_syms = switch (std.meta.activeTag(val)) {
                    .list => val.list.items.items,
                    .vector => val.vector.items.items,
                    else => continue,
                };
            }
        } else if (std.mem.eql(u8, kw.keyword, "rename")) {
            if (std.meta.activeTag(val) == .map) {
                rename_map = val.map.entries;
            }
        }
    }

    try eval_ns.referVars(allocator, target_env, source_env, refer_all, refer_syms, exclude_syms, rename_map);
    return vm.nilValue();
}

/// alias: (alias alias-sym namespace-sym)
/// Adds an alias in the current namespace.
pub fn core_alias(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;

    const alias_sym = args.items[0];
    const ns_sym = args.items[1];
    if (std.meta.activeTag(alias_sym) != .symbol or std.meta.activeTag(ns_sym) != .symbol) return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const current_ns = ns_mgr.getCurrentNamespace();

    try ns_mgr.addAlias(current_ns, alias_sym.symbol, ns_sym.symbol);
    return vm.nilValue();
}

/// ns-aliases: (ns-aliases ns) → map-of-aliases
/// Returns a map of aliases for the namespace.
pub fn core_ns_aliases(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const ns_arg = args.items[0];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    _ = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    return try buildAliasesMap(allocator, ns_name, ns_mgr);
}

/// ns-unalias: (ns-unalias ns sym) → nil
/// Removes an alias from a namespace.
pub fn core_ns_unalias(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;

    const ns_arg = args.items[0];
    const alias_arg = args.items[1];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;
    if (std.meta.activeTag(alias_arg) != .symbol) return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    _ = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    try ns_mgr.removeAlias(ns_name, alias_arg.symbol);
    return vm.nilValue();
}

/// require: (require '& args)
/// Loads namespaces programmatically.
pub fn core_require(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len < 1) return error.ArityError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const current_ns = ns_mgr.getCurrentNamespace();
    const current_env = ns_mgr.getNamespace(current_ns) orelse return error.TypeError;

    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];

        // Handle simple symbol: (require 'my.lib)
        if (std.meta.activeTag(arg) == .symbol) {
            const ns_name = arg.symbol;
            try eval_ns.loadNamespaceFile(allocator, ns_mgr, ns_name, env_env);
            try ns_mgr.addLoadedLib(ns_name);
            continue;
        }

        // Handle simple string: (require "my.lib")
        if (std.meta.activeTag(arg) == .string) {
            const ns_name = arg.string;
            try eval_ns.loadNamespaceFile(allocator, ns_mgr, ns_name, env_env);
            try ns_mgr.addLoadedLib(ns_name);
            continue;
        }

        // Handle vector libspec: (require '[my.lib :as ml :refer [foo]])
        if (std.meta.activeTag(arg) == .vector) {
            const items = arg.vector.items.items;
            if (items.len < 1) continue;
            const ns_sym = items[0];
            if (std.meta.activeTag(ns_sym) != .symbol) continue;
            const ns_name = ns_sym.symbol;

            // Parse options from the vector
            var alias: ?[]const u8 = null;
            var refer_all: bool = false;
            var refer_syms: ?[]const Value = null;
            var exclude_syms: ?[]const Value = null;
            var rename_map: ?vm.Map = null;

            var k: usize = 1;
            while (k < items.len) : (k += 1) {
                if (std.meta.activeTag(items[k]) == .keyword) {
                    if (k + 1 >= items.len) break;
                    k += 1;
                    if (std.mem.eql(u8, items[k - 1].keyword, "as")) {
                        if (std.meta.activeTag(items[k]) == .symbol) alias = items[k].symbol;
                    } else if (std.mem.eql(u8, items[k - 1].keyword, "refer")) {
                        if (std.meta.activeTag(items[k]) == .keyword and std.mem.eql(u8, items[k].keyword, "all")) {
                            refer_all = true;
                        } else {
                            refer_syms = switch (std.meta.activeTag(items[k])) {
                                .list => items[k].list.items.items,
                                .vector => items[k].vector.items.items,
                                else => continue,
                            };
                        }
                    } else if (std.mem.eql(u8, items[k - 1].keyword, "exclude")) {
                        exclude_syms = switch (std.meta.activeTag(items[k])) {
                            .list => items[k].list.items.items,
                            .vector => items[k].vector.items.items,
                            else => continue,
                        };
                    } else if (std.mem.eql(u8, items[k - 1].keyword, "rename")) {
                        if (std.meta.activeTag(items[k]) == .map) rename_map = items[k].map.entries;
                    }
                }
            }

            // Load the namespace
            try eval_ns.loadNamespaceFile(allocator, ns_mgr, ns_name, env_env);
            try ns_mgr.addLoadedLib(ns_name);

            // Register alias
            const effective_alias = alias orelse blk: {
                var last_dot: usize = 0;
                var d: usize = 0;
                while (d < ns_name.len) : (d += 1) {
                    if (ns_name[d] == '.') last_dot = d + 1;
                }
                break :blk if (last_dot > 0 and last_dot < ns_name.len) ns_name[last_dot..] else ns_name;
            };
            try ns_mgr.addAlias(current_ns, effective_alias, ns_name);

            // Refer vars if requested
            const target_env = ns_mgr.getNamespace(ns_name) orelse continue;
            try eval_ns.referVars(allocator, current_env, target_env, refer_all, refer_syms, exclude_syms, rename_map);
            continue;
        }

        // Handle prefix list: (require '(clojure [string :as str] zip))
        if (std.meta.activeTag(arg) == .list) {
            const list_items = arg.list.items.items;
            if (list_items.len < 1) continue;
            const prefix_sym = list_items[0];
            if (std.meta.activeTag(prefix_sym) != .symbol) continue;
            const prefix = prefix_sym.symbol;

            var j: usize = 1;
            while (j < list_items.len) : (j += 1) {
                const suffix_item = list_items[j];

                // Simple suffix: (clojure zip) → clojure.zip
                if (std.meta.activeTag(suffix_item) == .symbol) {
                    const full_ns = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, suffix_item.symbol });
                    try eval_ns.loadNamespaceFile(allocator, ns_mgr, full_ns, env_env);
                    try ns_mgr.addLoadedLib(full_ns);
                    allocator.free(full_ns);
                    continue;
                }

                // Vector with options: (clojure [string :as str])
                if (std.meta.activeTag(suffix_item) == .vector) {
                    const vec_items = suffix_item.vector.items.items;
                    if (vec_items.len < 1) continue;
                    const suffix_sym = vec_items[0];
                    if (std.meta.activeTag(suffix_sym) != .symbol) continue;
                    const full_ns = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, suffix_sym.symbol });

                    // Parse options from the vector
                    var alias: ?[]const u8 = null;
                    var refer_all: bool = false;
                    var refer_syms: ?[]const Value = null;
                    var exclude_syms: ?[]const Value = null;
                    var rename_map: ?vm.Map = null;

                    var k: usize = 1;
                    while (k < vec_items.len) : (k += 1) {
                        if (std.meta.activeTag(vec_items[k]) == .keyword) {
                            if (k + 1 >= vec_items.len) break;
                            k += 1;
                            if (std.mem.eql(u8, vec_items[k - 1].keyword, "as")) {
                                if (std.meta.activeTag(vec_items[k]) == .symbol) alias = vec_items[k].symbol;
                            } else if (std.mem.eql(u8, vec_items[k - 1].keyword, "refer")) {
                                if (std.meta.activeTag(vec_items[k]) == .keyword and std.mem.eql(u8, vec_items[k].keyword, "all")) {
                                    refer_all = true;
                                } else {
                                    refer_syms = switch (std.meta.activeTag(vec_items[k])) {
                                        .list => vec_items[k].list.items.items,
                                        .vector => vec_items[k].vector.items.items,
                                        else => continue,
                                    };
                                }
                            } else if (std.mem.eql(u8, vec_items[k - 1].keyword, "exclude")) {
                                exclude_syms = switch (std.meta.activeTag(vec_items[k])) {
                                    .list => vec_items[k].list.items.items,
                                    .vector => vec_items[k].vector.items.items,
                                    else => continue,
                                };
                            } else if (std.mem.eql(u8, vec_items[k - 1].keyword, "rename")) {
                                if (std.meta.activeTag(vec_items[k]) == .map) rename_map = vec_items[k].map.entries;
                            }
                        }
                    }

                    try eval_ns.loadNamespaceFile(allocator, ns_mgr, full_ns, env_env);
                    try ns_mgr.addLoadedLib(full_ns);

                    const effective_alias = alias orelse blk: {
                        var last_dot: usize = 0;
                        var d: usize = 0;
                        while (d < suffix_sym.symbol.len) : (d += 1) {
                            if (suffix_sym.symbol[d] == '.') last_dot = d + 1;
                        }
                        break :blk if (last_dot > 0 and last_dot < suffix_sym.symbol.len) suffix_sym.symbol[last_dot..] else suffix_sym.symbol;
                    };
                    try ns_mgr.addAlias(current_ns, effective_alias, full_ns);

                    const target_env = ns_mgr.getNamespace(full_ns) orelse {
                        allocator.free(full_ns);
                        continue;
                    };
                    try eval_ns.referVars(allocator, current_env, target_env, refer_all, refer_syms, exclude_syms, rename_map);
                    allocator.free(full_ns);
                }
            }
        }
    }

    return vm.nilValue();
}

/// loaded-libs: (loaded-libs) → sorted-set-of-symbols
/// Returns the set of loaded library namespaces.
pub fn core_loaded_libs(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = args;
    const allocator = env_env.allocator;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return try vm.setValue(allocator, .empty);

    var items: vm.Set = .empty;
    errdefer {
        for (items.items) |*v| vm.valueDeinit(v, allocator);
        allocator.free(items.items);
    }

    const libs = ns_mgr.getLoadedLibs();
    for (libs) |lib| {
        try items.append(allocator, try vm.symValue(allocator, lib));
    }

    return try vm.setValue(allocator, items);
}

/// resolve: (resolve sym) → value or nil
/// Resolves a symbol in the current namespace.
pub fn core_resolve(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return vm.nilValue();
    const current_ns = ns_mgr.getCurrentNamespace();
    const ns_env = ns_mgr.getNamespace(current_ns) orelse return vm.nilValue();

    const sym_arg = args.items[0];
    const sym_str = if (std.meta.activeTag(sym_arg) == .symbol) sym_arg.symbol else return vm.nilValue();
    const allocator = env_env.allocator;

    // Check for qualified symbol (contains '/')
    if (std.mem.indexOfScalar(u8, sym_str, '/')) |slash_idx| {
        const prefix = sym_str[0..slash_idx];
        const name = sym_str[slash_idx + 1 ..];
        const target_ns_name = ns_mgr.resolveAlias(current_ns, prefix) orelse prefix;
        const target_env = ns_mgr.getNamespace(target_ns_name) orelse return vm.nilValue();
        const val = target_env.get(name);
        if (val) |v| return try vm.clone(&v, allocator);
        return vm.nilValue();
    }

    // Unqualified symbol: look up in current namespace's env chain
    const val = ns_env.get(sym_str);
    if (val) |v| return try vm.clone(&v, allocator);
    return vm.nilValue();
}

/// Build a map of owned (interned) vars for a namespace.
fn buildInternsMap(allocator: Allocator, ns_env: *const Env) anyerror!Value {
    var interns_map: vm.Map = .empty;
    errdefer {
        for (interns_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(interns_map.items);
    }
    var it = ns_env.entries.entryIterator();
    while (it.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        // Skip referred names — interns are only owned vars
        if (eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        // Skip symbols not owned by this namespace (e.g. copied from zig.core)
        if (!ns_env.isOwned(sym_name)) continue;
        // Use shallowClone to avoid deep-cloning function bodies.
        // Functions are immutable and live in permanent namespace roots.
        const val = try vm.shallowClone(&entry.val, allocator);
        try interns_map.append(allocator, .{
            .key = try vm.symValue(allocator, sym_name),
            .value = val,
        });
    }
    return try vm.mapValue(allocator, interns_map);
}

/// Build a map of referred vars for a namespace.
fn buildRefersMap(allocator: Allocator, ns_env: *const Env) anyerror!Value {
    var refers_map: vm.Map = .empty;
    errdefer {
        for (refers_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(refers_map.items);
    }
    var it = ns_env.entries.entryIterator();
    while (it.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        // Only include referred names
        if (!eval_ns.isReferredName(ns_env.referred_names.items, sym_name)) continue;
        try refers_map.append(allocator, .{
            .key = try vm.symValue(allocator, sym_name),
            .value = try vm.clone(&entry.val, allocator),
        });
    }
    return try vm.mapValue(allocator, refers_map);
}

/// ns-publics: (ns-publics ns) → map-of-symbol-to-value
/// Returns the vars OWNED by the namespace (not referred).
pub fn core_ns_publics(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const ns_arg = args.items[0];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    return try buildInternsMap(allocator, ns_env);
}

/// ns-interns: (ns-interns ns) → map-of-symbol-to-value
/// Same as ns-publics in our model (no private vars yet).
pub fn core_ns_interns(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const ns_arg = args.items[0];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    return try buildInternsMap(allocator, ns_env);
}

/// ns-refers: (ns-refers ns) → map-of-symbol-to-value
/// Returns the vars referred (imported) into the namespace.
pub fn core_ns_refers(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const ns_arg = args.items[0];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    return try buildRefersMap(allocator, ns_env);
}

/// ns-map: (ns-map ns) → map-of-all-mappings
/// Returns ALL mappings (publics + refers + aliases).
pub fn core_ns_map(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const ns_arg = args.items[0];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    // Merge all three maps
    var result_map: vm.Map = .empty;
    errdefer {
        for (result_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(result_map.items);
    }

    // Add interns (owned vars)
    var it = ns_env.entries.entryIterator();
    while (it.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        try result_map.append(allocator, .{
            .key = try vm.symValue(allocator, sym_name),
            .value = try vm.clone(&entry.val, allocator),
        });
    }

    // Add aliases (as symbol → symbol mappings)
    var it2 = ns_mgr.aliases.entryIterator();
    while (it2.next()) |entry| {
        const composite_key = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        if (std.mem.indexOfScalar(u8, composite_key, '/')) |slash_idx| {
            const key_ns_name = composite_key[0..slash_idx];
            const alias_name = composite_key[slash_idx + 1 ..];
            if (std.mem.eql(u8, key_ns_name, ns_name)) {
                const target_ns = if (std.meta.activeTag(entry.val) == .string) entry.val.string else continue;
                try result_map.append(allocator, .{
                    .key = try vm.symValue(allocator, alias_name),
                    .value = try vm.symValue(allocator, target_ns),
                });
            }
        }
    }

    return try vm.mapValue(allocator, result_map);
}

/// ns-unmap: (ns-unmap ns sym) → nil
/// Removes a var mapping from a namespace.
pub fn core_ns_unmap(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;

    const ns_arg = args.items[0];
    const sym_arg = args.items[1];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;
    if (std.meta.activeTag(sym_arg) != .symbol) return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    // Remove from the HAMT
    const key = phm.sym(sym_arg.symbol);
    ns_env.entries = try ns_env.entries.mapWithout(ns_env.allocator, key);

    // Also remove from referred_names if present
    var i: usize = 0;
    while (i < ns_env.referred_names.items.len) : (i += 1) {
        if (std.mem.eql(u8, ns_env.referred_names.items[i], sym_arg.symbol)) {
            ns_env.allocator.free(ns_env.referred_names.items[i]);
            // Remove from the list by shifting
            const remaining = ns_env.referred_names.items.len - i - 1;
            if (remaining > 0) {
                @memcpy(ns_env.referred_names.items[i..], ns_env.referred_names.items[i + 1 ..]);
            }
            ns_env.referred_names.items = ns_env.referred_names.items[0 .. ns_env.referred_names.items.len - 1];
            break;
        }
    }

    return vm.nilValue();
}

/// intern: (intern ns sym) → var
///           (intern ns sym val) → var
/// Finds or creates a var in ns named sym, optionally setting its value.
pub fn core_intern(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;

    const ns_arg = args.items[0];
    const sym_arg = args.items[1];
    const ns_name = extractNsName(ns_arg) orelse return error.TypeError;
    if (std.meta.activeTag(sym_arg) != .symbol) return error.TypeError;

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return error.TypeError;

    // If value provided, set it
    if (args.items.len == 3) {
        const val = try vm.clone(&args.items[2], allocator);
        try ns_env.put(sym_arg.symbol, val);
    }

    // Return the symbol (we don't have Var objects)
    return try vm.symValue(allocator, sym_arg.symbol);
}

/// load-string: (load-string s) → result-of-last-form
/// Parses and evaluates a string of Clojure code.
pub fn core_load_string(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;

    const str_arg = args.items[0];
    if (std.meta.activeTag(str_arg) != .string) return error.TypeError;
    const source = str_arg.string;

    // Parse the string
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    var forms = try p.parseAll();
    defer forms.deinit(allocator);

    // Resolve current namespace's env for evaluation
    var eval_env: *Env = env_env;
    if (eval_mod.findNsManager(env_env)) |ns_mgr| {
        const current_ns = ns_mgr.getCurrentNamespace();
        if (ns_mgr.getNamespace(current_ns)) |ns_env| {
            eval_env = ns_env;
        }
    }

    // Evaluate each form, keeping track of the last result
    var last_result: Value = vm.nilValue();
    for (forms.items) |form| {
        const result_ptr = try eval_mod.eval(allocator, form, eval_env);
        vm.valueDeinit(&last_result, allocator);
        last_result = result_ptr.*;
    }

    return last_result;
}

/// remove-ns: (remove-ns sym) → nil
/// Removes a namespace. Cannot remove clojure.core or user.
pub fn core_remove_ns(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;

    const ns_arg = args.items[0];
    if (std.meta.activeTag(ns_arg) != .symbol) return error.TypeError;
    const ns_name = ns_arg.symbol;

    // Cannot remove clojure.core or user
    if (std.mem.eql(u8, ns_name, "clojure.core") or std.mem.eql(u8, ns_name, "user")) {
        return error.ProtectedNamespace;
    }

    const ns_mgr = eval_ns.findNsManager(env_env) orelse return error.TypeError;
    const allocator = ns_mgr.allocator;

    // Get the namespace env before removing it
    const ns_env = ns_mgr.getNamespace(ns_name) orelse return vm.nilValue();

    // Remove from namespaces map
    const key = phm.sym(ns_name);
    ns_mgr.namespaces = try ns_mgr.namespaces.mapWithout(allocator, key);

    // Remove all aliases for this namespace
    // Aliases have composite keys "ns_name/alias_name"
    var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix_buf.deinit(allocator);
    try prefix_buf.appendSlice(allocator, ns_name);
    try prefix_buf.append(allocator, '/');
    const prefix = prefix_buf.items;

    // Collect alias keys to remove (can't modify map while iterating)
    var keys_to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys_to_remove.deinit(allocator);

    var it = ns_mgr.aliases.entryIterator();
    while (it.next()) |entry| {
        const composite_key = if (std.meta.activeTag(entry.key) == .symbol) entry.key.symbol else continue;
        if (std.mem.startsWith(u8, composite_key, prefix)) {
            const owned = try allocator.dupe(u8, composite_key);
            try keys_to_remove.append(allocator, owned);
        }
    }

    // Remove collected alias keys
    for (keys_to_remove.items) |alias_key| {
        const alias_sym_key = phm.sym(alias_key);
        ns_mgr.aliases = try ns_mgr.aliases.mapWithout(allocator, alias_sym_key);
        allocator.free(alias_key);
    }

    // Free the namespace env (HAMT nodes are GC-tracked)
    ns_env.deinit(allocator);
    allocator.destroy(ns_env);

    return vm.nilValue();
}

// ---- Registration ----

pub fn registerNamespaceFunctions(env: *Env) anyerror!void {
    // Namespace introspection (Phase 1)
    try env.put("find-ns", vm.builtinFnValue(core_find_ns));
    try env.put("create-ns", vm.builtinFnValue(core_create_ns));
    try env.put("all-ns", vm.builtinFnValue(core_all_ns));
    try env.put("the-ns", vm.builtinFnValue(core_the_ns));

    // Namespace resolution (Phase 2)
    try env.put("ns-resolve", vm.builtinFnValue(core_ns_resolve));
    try env.put("resolve", vm.builtinFnValue(core_resolve));

    // Namespace manipulation (Phase 3)
    try env.put("refer", vm.builtinFnValue(core_refer));
    try env.put("alias", vm.builtinFnValue(core_alias));
    try env.put("ns-aliases", vm.builtinFnValue(core_ns_aliases));
    try env.put("ns-unalias", vm.builtinFnValue(core_ns_unalias));
    try env.put("require", vm.builtinFnValue(core_require));
    try env.put("loaded-libs", vm.builtinFnValue(core_loaded_libs));

    // Namespace internals (Phase 4)
    try env.put("ns-publics", vm.builtinFnValue(core_ns_publics));
    try env.put("ns-interns", vm.builtinFnValue(core_ns_interns));
    try env.put("ns-refers", vm.builtinFnValue(core_ns_refers));
    try env.put("ns-map", vm.builtinFnValue(core_ns_map));
    try env.put("ns-unmap", vm.builtinFnValue(core_ns_unmap));
    try env.put("intern", vm.builtinFnValue(core_intern));

    // Loading and evaluation (Phase 5)
    try env.put("load-string", vm.builtinFnValue(core_load_string));
    try env.put("remove-ns", vm.builtinFnValue(core_remove_ns));
}
