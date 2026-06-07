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
    // Set parent to root env so builtins are visible
    if (ns_env.parent == null) {
        // Find the root env (the one with ns_manager)
        var root_env: ?*Env = env;
        while (root_env) |e| {
            if (e.ns_manager != null) break;
            root_env = e.parent;
        }
        if (root_env) |re| {
            ns_env.parent = re;
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
            // Each item is a vector: [ns.name :as alias] or [ns.name :refer [fn1 fn2]]
            var j: usize = 1;
            while (j < clause.list_val.items.len) : (j += 1) {
                const req_item = clause.list_val.items[j];
                if (req_item.type != .vector) continue;
                const req_items = req_item.vec_val.items;
                if (req_items.len < 1) continue;

                const req_ns_sym = req_items[0];
                if (req_ns_sym.type != .symbol) continue;
                const req_ns_name = req_ns_sym.sym_val;

                // Parse :as and :refer from the require vector
                var alias: ?[]const u8 = null;
                var k: usize = 1;
                while (k < req_items.len) : (k += 1) {
                    if (req_items[k].type == .keyword) {
                        if (std.mem.eql(u8, req_items[k].kw_val, "as") and k + 1 < req_items.len) {
                            k += 1;
                            if (req_items[k].type == .symbol) {
                                alias = req_items[k].sym_val;
                            }
                        }
                        // Skip :refer for now (handled by alias resolution)
                    }
                }

                // Use alias if provided, otherwise use the last part of the namespace name as alias
                const effective_alias = alias orelse blk: {
                    // Default alias: last part of namespace name (e.g., "hello" from "hello.hello")
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
            }
        }
    }

    // Set current namespace
    try ns_mgr.setCurrentNamespace(ns_name);

    return Value.nilValue();
}

// Load a namespace file from the classpath and evaluate it.
pub fn loadNamespaceFile(allocator: Allocator, ns_mgr: *Value.NamespaceManager, ns_name: []const u8, root_env: *Env) anyerror!void {
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
