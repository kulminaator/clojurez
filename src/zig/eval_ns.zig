// Namespace management: ns special form, namespace loading
const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const Env = Value.Env;
const parser = @import("parser.zig");
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

/// Walk up the env parent chain to find the namespace manager.
pub fn findNsManager(env: *const Env) ?*Value.NamespaceManager {
    var current: ?*const Env = env;
    while (current) |e| {
        if (e.ns_manager) |mgr| return mgr;
        current = e.parent;
    }
    return null;
}

// ns special form: (ns namespace-name (:require [other.ns :as alias] ...))
pub fn evalNs(allocator: Allocator, l: list.List, env: *Env, depth: usize) anyerror!Value {
    _ = depth;
    if (l.items.len < 2) return error.ArityError;

    const ns_name_sym = l.items[1];
    if (ns_name_sym.type != .symbol) return error.TypeError;
    const ns_name = ns_name_sym.sym_val;

    // Find the namespace manager
    const ns_mgr = findNsManager(env) orelse return Value.nilValue();

    // Create or get the namespace
    const ns_env = try ns_mgr.createNamespace(ns_name);
    // Set parent to clojure.core so core functions are visible.
    // Guard: don't set clojure.core's parent to itself (would create a cycle
    // in env.get() causing infinite loops on undefined symbol lookups).
    if (ns_env.parent == null and !std.mem.eql(u8, ns_name, "clojure.core")) {
        const clojure_core = ns_mgr.getNamespace("clojure.core");
        if (clojure_core) |core_env| {
            ns_env.parent = core_env;
        } else {
            // Fallback to root env
            var root_env: ?*Env = env;
            while (root_env) |e| {
                if (e.ns_manager != null) break;
                root_env = e.parent;
            }
            if (root_env) |re| {
                ns_env.parent = re;
            }
        }
    }

    // Process clauses starting from index 2
    var i: usize = 2;
    while (i < l.items.len) : (i += 1) {
        const clause = l.items[i];
        if (clause.type != .list or clause.list_val.items.len == 0) continue;

        const clause_keyword = clause.list_val.items[0];
        if (clause_keyword.type != .keyword) continue;

        if (std.mem.eql(u8, clause_keyword.kw_val, "require")) {
            // Process :require clause
            // Each item is a vector: [ns.name :as alias :refer [fn1 fn2] :exclude [fn3] :rename {fn1 fn2}]
            var j: usize = 1;
            while (j < clause.list_val.items.len) : (j += 1) {
                const req_item = clause.list_val.items[j];
                if (req_item.type != .vector) continue;
                const req_items = req_item.vec_val.items;
                if (req_items.len < 1) continue;

                const req_ns_sym = req_items[0];
                if (req_ns_sym.type != .symbol) continue;
                const req_ns_name = req_ns_sym.sym_val;

                // Parse :as, :refer, :exclude, :rename from the require vector
                var alias: ?[]const u8 = null;
                var refer_all: bool = false;
                var refer_syms: ?[]const Value = null;
                var exclude_syms: ?[]const Value = null;
                var rename_map: ?Value.Map = null;
                var k: usize = 1;
                while (k < req_items.len) : (k += 1) {
                    if (req_items[k].type == .keyword) {
                        if (std.mem.eql(u8, req_items[k].kw_val, "as") and k + 1 < req_items.len) {
                            k += 1;
                            if (req_items[k].type == .symbol) {
                                alias = req_items[k].sym_val;
                            }
                        } else if (std.mem.eql(u8, req_items[k].kw_val, "refer") and k + 1 < req_items.len) {
                            k += 1;
                            if (req_items[k].type == .keyword and std.mem.eql(u8, req_items[k].kw_val, "all")) {
                                refer_all = true;
                            } else if (req_items[k].type == .list) {
                                refer_syms = req_items[k].list_val.items;
                            } else if (req_items[k].type == .vector) {
                                refer_syms = req_items[k].vec_val.items;
                            }
                        } else if (std.mem.eql(u8, req_items[k].kw_val, "exclude") and k + 1 < req_items.len) {
                            k += 1;
                            if (req_items[k].type == .list) {
                                exclude_syms = req_items[k].list_val.items;
                            } else if (req_items[k].type == .vector) {
                                exclude_syms = req_items[k].vec_val.items;
                            }
                        } else if (std.mem.eql(u8, req_items[k].kw_val, "rename") and k + 1 < req_items.len) {
                            k += 1;
                            if (req_items[k].type == .map) {
                                rename_map = req_items[k].map_val;
                            }
                        }
                    }
                }

                // Use alias if provided, otherwise use the last part of the namespace name as alias
                const effective_alias = alias orelse blk: {
                    const ns_name_str = req_ns_name;
                    var last_dot: usize = 0;
                    var d: usize = 0;
                    while (d < ns_name_str.len) : (d += 1) {
                        if (ns_name_str[d] == '.') last_dot = d + 1;
                    }
                    break :blk if (last_dot > 0 and last_dot < ns_name_str.len) ns_name_str[last_dot..] else ns_name_str;
                };

                // Register alias
                try ns_mgr.addAlias(ns_name, effective_alias, req_ns_name);

                // Load the required namespace file from classpath
                try loadNamespaceFile(allocator, ns_mgr, req_ns_name, env);

                // Copy referenced vars from target namespace into current namespace (refer semantics)
                const target_env = ns_mgr.getNamespace(req_ns_name) orelse continue;
                try referVars(allocator, ns_env, target_env, refer_all, refer_syms, exclude_syms, rename_map);
            }
        }
    }

    // Set current namespace
    try ns_mgr.setCurrentNamespace(ns_name);

    return Value.nilValue();
}

/// Check if a name is in the referred-names list (linear scan, simple and reliable).
fn isReferredName(referred: []const []const u8, name: []const u8) bool {
    for (referred) |r| {
        if (std.mem.eql(u8, r, name)) return true;
    }
    return false;
}

/// Copy referenced vars from source namespace into the target namespace.
/// Matches original Clojure semantics: only copies OWNED vars (ns-interns),
/// not vars that were themselves referred (ns-refers). This prevents
/// transitive refers — if A refers B and B refers C, A does NOT get C's vars.
fn referVars(
    allocator: Allocator,
    target_ns: *Env,
    source_ns: *const Env,
    refer_all: bool,
    refer_syms: ?[]const Value,
    exclude_syms: ?[]const Value,
    rename_map: ?Value.Map,
) anyerror!void {
    var it = source_ns.entries.iterator();
    while (it.next()) |entry| {
        const sym_name = entry.key_ptr.*;
        const sym_val = entry.value_ptr;

        // Skip vars that were themselves referred into source_ns (not owned).
        // Original Clojure only copies owned vars (ns-interns), not referred vars.
        if (isReferredName(source_ns.referred_names.items, sym_name)) continue;

        // Check :exclude
        if (exclude_syms) |excl| {
            var excluded = false;
            for (excl) |ex| {
                if (ex.type == .symbol and std.mem.eql(u8, ex.sym_val, sym_name)) {
                    excluded = true;
                    break;
                }
            }
            if (excluded) continue;
        }

        // Check :refer list (if specified, only refer listed symbols)
        if (refer_syms) |refs| {
            if (!refer_all) {
                var found = false;
                for (refs) |r| {
                    if (r.type == .symbol and std.mem.eql(u8, r.sym_val, sym_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }
        } else if (!refer_all) {
            // No :refer and no :refer :all — skip (alias handles qualified lookup)
            continue;
        }

        // Determine the local name (check :rename map)
        const local_name = blk: {
            if (rename_map) |rmap| {
                for (rmap.items) |me| {
                    if (me.key.type == .symbol and std.mem.eql(u8, me.key.sym_val, sym_name)) {
                        if (me.value.type == .symbol) {
                            break :blk me.value.sym_val;
                        }
                        break;
                    }
                }
            }
            break :blk sym_name;
        };

        // Clone the value into the target namespace
        const cloned = try sym_val.clone(allocator);
        try target_ns.put(local_name, cloned);

        // Mark as referred so transitive refers won't copy it further.
        // Uses target_ns.allocator so the string lifetime matches the env.
        const key_copy = try target_ns.allocator.dupe(u8, local_name);
        try target_ns.referred_names.append(target_ns.allocator, key_copy);
    }
}

// Load a namespace file from the classpath and evaluate it.
pub fn loadNamespaceFile(allocator: Allocator, ns_mgr: *Value.NamespaceManager, ns_name: []const u8, root_env: *Env) anyerror!void {
    // Built-in virtual namespaces (zig.*) — no file to load
    if (std.mem.startsWith(u8, ns_name, "zig.")) return;

    // Check if already loaded
    if (ns_mgr.getNamespace(ns_name) != null) return;

    // Resolve namespace name to file path
    const file_path = try ns_mgr.resolveNamespaceToPath(allocator, ns_name) orelse {
        // File not found on classpath — create namespace without loading
        _ = try ns_mgr.createNamespace(ns_name);
        return;
    };
    defer allocator.free(file_path);

    // Read the file
    const cwd = std.Io.Dir.cwd();
    var file = try std.Io.Dir.openFile(cwd, std.Options.debug_io, file_path, .{});
    defer std.Io.File.close(file, std.Options.debug_io);

    var reader = file.reader(std.Options.debug_io, &[_]u8{});
    const content = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);

    // Parse and evaluate
    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();

    var forms = try p.parseAll();
    defer forms.deinit(allocator);

    for (forms.items) |form| {
        // Use current namespace's env for evaluation (ns form may change it)
        const eval_env = getCurrentNsEnvForLoad(root_env, ns_mgr) orelse root_env;
        var result = try eval.evalRec(allocator, allocator, form, eval_env, 0);
        result.deinit(allocator);
    }
}

// Get the current namespace's env for file loading.
// Returns an env without ns_manager set, so defn binds in the namespace's env.
pub fn getCurrentNsEnvForLoad(_root_env: *Env, ns_mgr: *Value.NamespaceManager) ?*Env {
    _ = _root_env;
    const current_ns = ns_mgr.getCurrentNamespace();
    return ns_mgr.getNamespace(current_ns);
}

// in-ns special form: (in-ns namespace-name)
// Creates or finds the namespace and sets it as the current namespace.
// Simpler than ns — no :require, :use, :import clauses.
pub fn evalInNs(allocator: Allocator, l: list.List, env: *Env, depth: usize) anyerror!Value {
    _ = allocator;
    _ = depth;
    if (l.items.len < 2) return error.ArityError;

    const ns_name_sym = l.items[1];
    if (ns_name_sym.type != .symbol) return error.TypeError;
    const ns_name = ns_name_sym.sym_val;

    // Find the namespace manager
    const ns_mgr = findNsManager(env) orelse return Value.nilValue();

    // Create or get the namespace
    const ns_env = try ns_mgr.createNamespace(ns_name);
    // Set parent to clojure.core so core functions are visible.
    // Guard: don't set clojure.core's parent to itself (would create a cycle
    // in env.get() causing infinite loops on undefined symbol lookups).
    if (ns_env.parent == null and !std.mem.eql(u8, ns_name, "clojure.core")) {
        const clojure_core = ns_mgr.getNamespace("clojure.core");
        if (clojure_core) |core_env| {
            ns_env.parent = core_env;
        } else {
            // Fallback to root env
            var root_env: ?*Env = env;
            while (root_env) |e| {
                if (e.ns_manager != null) break;
                root_env = e.parent;
            }
            if (root_env) |re| {
                ns_env.parent = re;
            }
        }
    }

    // Set current namespace
    try ns_mgr.setCurrentNamespace(ns_name);

    return Value.nilValue();
}

// ---- Tests ----

test "ns::isReferredName: empty list returns false" {
    const referred: []const []const u8 = &[_][]const u8{};
    try std.testing.expect(!isReferredName(referred, "anything"));
}

test "ns::isReferredName: finds matching name" {
    const referred = [_][]const u8{ "alpha", "beta", "gamma" };
    try std.testing.expect(isReferredName(referred[0..], "beta"));
    try std.testing.expect(isReferredName(referred[0..], "alpha"));
    try std.testing.expect(isReferredName(referred[0..], "gamma"));
}

test "ns::isReferredName: returns false for non-matching name" {
    const referred = [_][]const u8{ "alpha", "beta" };
    try std.testing.expect(!isReferredName(referred[0..], "gamma"));
    try std.testing.expect(!isReferredName(referred[0..], "alphaX"));
    try std.testing.expect(!isReferredName(referred[0..], ""));
}

test "ns::Env: referred_names init and deinit" {
    const allocator = std.testing.allocator;
    var env = Env.init(allocator);
    defer env.deinit(allocator);
    try std.testing.expect(env.referred_names.items.len == 0);

    // Append a referred name and verify
    const name = try allocator.dupe(u8, "test-fn");
    try env.referred_names.append(allocator, name);
    try std.testing.expect(env.referred_names.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, env.referred_names.items[0], "test-fn"));
}

test "ns::Env: clone preserves referred_names as empty" {
    const allocator = std.testing.allocator;
    var env = Env.init(allocator);
    defer env.deinit(allocator);

    // Add a referred name
    const name = try allocator.dupe(u8, "referred-fn");
    try env.referred_names.append(allocator, name);

    // Clone — referred_names should be empty in the clone (shallow copy of entries only)
    var cloned = try env.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(cloned.referred_names.items.len == 0);
}
