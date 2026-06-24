// Namespace management: ns special form, namespace loading
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const Env = vm.Env;
const parser = @import("parser.zig");
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

/// Walk up the env parent chain to find the namespace manager.
pub fn findNsManager(env: *const Env) ?*vm.NamespaceManager {
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
    if (std.meta.activeTag(ns_name_sym) != .symbol) return error.TypeError;
    const ns_name = ns_name_sym.sym_val;

    // Find the namespace manager
    const ns_mgr = findNsManager(env) orelse return vm.nilValue();

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
        if (std.meta.activeTag(clause) != .list or clause.list_val.items.len == 0) continue;

        const clause_keyword = clause.list_val.items[0];
        if (std.meta.activeTag(clause_keyword) != .keyword) continue;

        // :refer-clojure is accepted syntactically but not fully enforced.
        // The parent chain already gives access to all clojure.core functions.
        if (std.mem.eql(u8, clause_keyword.kw_val, "refer-clojure")) continue;

        if (std.mem.eql(u8, clause_keyword.kw_val, "require")) {
            // Process :require clause
            var j: usize = 1;
            while (j < clause.list_val.items.len) : (j += 1) {
                const req_item = clause.list_val.items[j];
                if (std.meta.activeTag(req_item) == .vector) {
                    try processRequireItem(allocator, ns_mgr, ns_env, ns_name, req_item.vec_val.items, false, env);
                } else if (std.meta.activeTag(req_item) == .list) {
                    // Prefix list: (clojure [string :as str] zip)
                    try processPrefixList(allocator, ns_mgr, ns_env, ns_name, req_item.list_val.items, false, env);
                }
            }
        } else if (std.mem.eql(u8, clause_keyword.kw_val, "use")) {
            // :use is like :require but with :refer :all by default
            var j: usize = 1;
            while (j < clause.list_val.items.len) : (j += 1) {
                const use_item = clause.list_val.items[j];
                if (std.meta.activeTag(use_item) == .vector) {
                    try processRequireItem(allocator, ns_mgr, ns_env, ns_name, use_item.vec_val.items, true, env);
                } else if (std.meta.activeTag(use_item) == .list) {
                    try processPrefixList(allocator, ns_mgr, ns_env, ns_name, use_item.list_val.items, true, env);
                }
            }
        }
    }

    // Set current namespace
    try ns_mgr.setCurrentNamespace(ns_name);

    return vm.nilValue();
}

/// Process a single require/use vector item: [ns.name :as alias :refer [...] ...]
fn processRequireItem(
    allocator: Allocator,
    ns_mgr: *vm.NamespaceManager,
    target_ns: *Env,
    target_ns_name: []const u8,
    req_items: []const Value,
    refer_all_default: bool,
    root_env: *Env,
) anyerror!void {
    if (req_items.len < 1) return;
    const req_ns_sym = req_items[0];
    if (std.meta.activeTag(req_ns_sym) != .symbol) return;
    const req_ns_name = req_ns_sym.sym_val;

    // Parse options from the vector
    var alias: ?[]const u8 = null;
    var refer_all: bool = false;
    var refer_syms: ?[]const Value = null;
    var exclude_syms: ?[]const Value = null;
    var rename_map: ?vm.Map = null;

    var k: usize = 1;
    while (k < req_items.len) : (k += 1) {
        if (std.meta.activeTag(req_items[k]) != .keyword) continue;
        if (k + 1 >= req_items.len) break;
        k += 1;
        if (std.mem.eql(u8, req_items[k - 1].kw_val, "as")) {
            if (std.meta.activeTag(req_items[k]) == .symbol) alias = req_items[k].sym_val;
        } else if (std.mem.eql(u8, req_items[k - 1].kw_val, "refer")) {
            if (std.meta.activeTag(req_items[k]) == .keyword and std.mem.eql(u8, req_items[k].kw_val, "all")) {
                refer_all = true;
            } else if (std.meta.activeTag(req_items[k]) == .list) {
                refer_syms = req_items[k].list_val.items;
            } else if (std.meta.activeTag(req_items[k]) == .vector) {
                refer_syms = req_items[k].vec_val.items;
            }
        } else if (std.mem.eql(u8, req_items[k - 1].kw_val, "exclude")) {
            if (std.meta.activeTag(req_items[k]) == .list) {
                exclude_syms = req_items[k].list_val.items;
            } else if (std.meta.activeTag(req_items[k]) == .vector) {
                exclude_syms = req_items[k].vec_val.items;
            }
        } else if (std.mem.eql(u8, req_items[k - 1].kw_val, "rename")) {
            if (std.meta.activeTag(req_items[k]) == .map) rename_map = req_items[k].map_val;
        }
    }

    // :use defaults to :refer :all
    if (refer_all_default and !refer_all and refer_syms == null) {
        refer_all = true;
    }

    const effective_alias = alias orelse blk: {
        var last_dot: usize = 0;
        var d: usize = 0;
        while (d < req_ns_name.len) : (d += 1) {
            if (req_ns_name[d] == '.') last_dot = d + 1;
        }
        break :blk if (last_dot > 0 and last_dot < req_ns_name.len) req_ns_name[last_dot..] else req_ns_name;
    };

    try ns_mgr.addAlias(target_ns_name, effective_alias, req_ns_name);
    try loadNamespaceFile(allocator, ns_mgr, req_ns_name, root_env);

    const source_env = ns_mgr.getNamespace(req_ns_name) orelse return;
    try referVars(allocator, target_ns, source_env, refer_all, refer_syms, exclude_syms, rename_map);
}

/// Process a prefix list item: (prefix [suffix :as a] suffix2 ...)
fn processPrefixList(
    allocator: Allocator,
    ns_mgr: *vm.NamespaceManager,
    target_ns: *Env,
    target_ns_name: []const u8,
    list_items: []const Value,
    refer_all_default: bool,
    root_env: *Env,
) anyerror!void {
    if (list_items.len < 1) return;
    const prefix_sym = list_items[0];
    if (std.meta.activeTag(prefix_sym) != .symbol) return;
    const prefix = prefix_sym.sym_val;

    var j: usize = 1;
    while (j < list_items.len) : (j += 1) {
        const suffix_item = list_items[j];

        // Simple suffix: (clojure zip) → clojure.zip
        if (std.meta.activeTag(suffix_item) == .symbol) {
            const full_ns = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, suffix_item.sym_val });
            defer allocator.free(full_ns);

            var last_dot: usize = 0;
            var d: usize = 0;
            while (d < full_ns.len) : (d += 1) {
                if (full_ns[d] == '.') last_dot = d + 1;
            }
            const alias = if (last_dot > 0 and last_dot < full_ns.len) full_ns[last_dot..] else full_ns;
            try ns_mgr.addAlias(target_ns_name, alias, full_ns);
            try loadNamespaceFile(allocator, ns_mgr, full_ns, root_env);
            continue;
        }

        // Vector with options: (clojure [string :as str])
        if (std.meta.activeTag(suffix_item) == .vector and suffix_item.vec_val.items.len >= 1) {
            const suffix_sym = suffix_item.vec_val.items[0];
            if (std.meta.activeTag(suffix_sym) == .symbol) {
                const full_ns = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, suffix_sym.sym_val });
                defer allocator.free(full_ns);

                // Parse options from the vector
                var alias: ?[]const u8 = null;
                var refer_all: bool = false;
                var refer_syms: ?[]const Value = null;
                var exclude_syms: ?[]const Value = null;
                var rename_map: ?vm.Map = null;

                var k: usize = 1;
                while (k < suffix_item.vec_val.items.len) : (k += 1) {
                    if (std.meta.activeTag(suffix_item.vec_val.items[k]) != .keyword) continue;
                    if (k + 1 >= suffix_item.vec_val.items.len) break;
                    k += 1;
                    if (std.mem.eql(u8, suffix_item.vec_val.items[k - 1].kw_val, "as")) {
                        if (std.meta.activeTag(suffix_item.vec_val.items[k]) == .symbol) alias = suffix_item.vec_val.items[k].sym_val;
                    } else if (std.mem.eql(u8, suffix_item.vec_val.items[k - 1].kw_val, "refer")) {
                        if (std.meta.activeTag(suffix_item.vec_val.items[k]) == .keyword and std.mem.eql(u8, suffix_item.vec_val.items[k].kw_val, "all")) {
                            refer_all = true;
                        } else if (std.meta.activeTag(suffix_item.vec_val.items[k]) == .list) {
                            refer_syms = suffix_item.vec_val.items[k].list_val.items;
                        } else if (std.meta.activeTag(suffix_item.vec_val.items[k]) == .vector) {
                            refer_syms = suffix_item.vec_val.items[k].vec_val.items;
                        }
                    } else if (std.mem.eql(u8, suffix_item.vec_val.items[k - 1].kw_val, "exclude")) {
                        if (std.meta.activeTag(suffix_item.vec_val.items[k]) == .list) {
                            exclude_syms = suffix_item.vec_val.items[k].list_val.items;
                        } else if (std.meta.activeTag(suffix_item.vec_val.items[k]) == .vector) {
                            exclude_syms = suffix_item.vec_val.items[k].vec_val.items;
                        }
                    } else if (std.mem.eql(u8, suffix_item.vec_val.items[k - 1].kw_val, "rename")) {
                        if (std.meta.activeTag(suffix_item.vec_val.items[k]) == .map) rename_map = suffix_item.vec_val.items[k].map_val;
                    }
                }

                if (refer_all_default and !refer_all and refer_syms == null) {
                    refer_all = true;
                }

                const effective_alias = alias orelse blk: {
                    var last_dot: usize = 0;
                    var d2: usize = 0;
                    while (d2 < suffix_sym.sym_val.len) : (d2 += 1) {
                        if (suffix_sym.sym_val[d2] == '.') last_dot = d2 + 1;
                    }
                    break :blk if (last_dot > 0 and last_dot < suffix_sym.sym_val.len) suffix_sym.sym_val[last_dot..] else suffix_sym.sym_val;
                };

                try ns_mgr.addAlias(target_ns_name, effective_alias, full_ns);
                try loadNamespaceFile(allocator, ns_mgr, full_ns, root_env);

                const source_env = ns_mgr.getNamespace(full_ns) orelse continue;
                try referVars(allocator, target_ns, source_env, refer_all, refer_syms, exclude_syms, rename_map);
            }
        }
    }
}

/// Check if a name is in the referred-names list (linear scan, simple and reliable).
pub fn isReferredName(referred: []const []const u8, name: []const u8) bool {
    for (referred) |r| {
        if (std.mem.eql(u8, r, name)) return true;
    }
    return false;
}

/// Copy referenced vars from source namespace into the target namespace.
/// Matches original Clojure semantics: only copies OWNED vars (ns-interns),
/// not vars that were themselves referred (ns-refers). This prevents
/// transitive refers — if A refers B and B refers C, A does NOT get C's vars.
pub fn referVars(
    allocator: Allocator,
    target_ns: *Env,
    source_ns: *const Env,
    refer_all: bool,
    refer_syms: ?[]const Value,
    exclude_syms: ?[]const Value,
    rename_map: ?vm.Map,
) anyerror!void {
    var it = source_ns.entries.entryIterator();
    while (it.next()) |entry| {
        const sym_name = if (std.meta.activeTag(entry.key) == .symbol) entry.key.sym_val else continue;
        const sym_val = entry.val;

        // Skip vars that were themselves referred into source_ns (not owned).
        // Original Clojure only copies owned vars (ns-interns), not referred vars.
        if (isReferredName(source_ns.referred_names.items, sym_name)) continue;

        // Check :exclude
        if (exclude_syms) |excl| {
            var excluded = false;
            for (excl) |ex| {
                if (std.meta.activeTag(ex) == .symbol and std.mem.eql(u8, ex.sym_val, sym_name)) {
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
                    if (std.meta.activeTag(r) == .symbol and std.mem.eql(u8, r.sym_val, sym_name)) {
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
                    if (std.meta.activeTag(me.key) == .symbol and std.mem.eql(u8, me.key.sym_val, sym_name)) {
                        if (std.meta.activeTag(me.value) == .symbol) {
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
        // NOTE: Do NOT deinit sym_val here. The iterator returns a shallow
        // copy of the Value from the HAMT. The HAMT owns the underlying
        // strings/objects, so deinit would corrupt the HAMT.

        // Mark as referred so transitive refers won't copy it further.
        // Uses target_ns.allocator so the string lifetime matches the env.
        const key_copy = try target_ns.allocator.dupe(u8, local_name);
        try target_ns.referred_names.append(target_ns.allocator, key_copy);
    }
}

// Load a namespace file from the classpath and evaluate it.
pub fn loadNamespaceFile(allocator: Allocator, ns_mgr: *vm.NamespaceManager, ns_name: []const u8, root_env: *Env) anyerror!void {
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
        const result_ptr = try eval.evalRec(allocator, &form, eval_env, 0);
        result_ptr.*.deinit(allocator);
    }
}

// Get the current namespace's env for file loading.
// Returns an env without ns_manager set, so defn binds in the namespace's env.
pub fn getCurrentNsEnvForLoad(_root_env: *Env, ns_mgr: *vm.NamespaceManager) ?*Env {
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
    if (std.meta.activeTag(ns_name_sym) != .symbol) return error.TypeError;
    const ns_name = ns_name_sym.sym_val;

    // Find the namespace manager
    const ns_mgr = findNsManager(env) orelse return vm.nilValue();

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

    return vm.nilValue();
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
