const std = @import("std");
const Value = @import("value.zig");
const Env = Value.Env;
const list = @import("list.zig");
const core = @import("namespaces/core/core.zig");
const io_mod = @import("namespaces/core/io.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const repl = @import("repl.zig");
const core_clj = @import("namespaces/core/core_clj.zig");
const regexp_api = @import("namespaces/regexp/api.zig");
const debug_allocator = @import("debug_allocator.zig");
const slab_allocator = @import("slab_allocator.zig");
const gc_mod = @import("gc.zig");
const gc_scan = @import("gc_scan.zig");
const sequences = @import("namespaces/core/sequences.zig");

const Allocator = std.mem.Allocator;

/// Fully realize a lazy-seq into a concrete list for printing.
fn fullyRealizeLazySeq(allocator: Allocator, val: Value) anyerror!Value {
    if (val.type != .lazy_seq) return try val.clone(allocator);

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var current: Value = val;
    var max_iter: usize = 100000;
    while (max_iter > 0) : (max_iter -= 1) {
        if (current.type != .lazy_seq) break;

        var forced = try sequences.forceLazySeqHelper(allocator, current);
        current.deinit(allocator);

        if (forced.type != .list) {
            forced.deinit(allocator);
            break;
        }

        for (forced.list_val.items) |item| {
            if (item.type == .lazy_seq) {
                const realized = try fullyRealizeLazySeq(allocator, item);
                if (realized.type == .list) {
                    for (realized.list_val.items) |ri| {
                        try result.append(allocator, try ri.clone(allocator));
                    }
                } else {
                    try result.append(allocator, realized);
                }
            } else {
                try result.append(allocator, try item.clone(allocator));
            }
        }
        forced.deinit(allocator);

        if (result.items.len > 0 and result.items[result.items.len - 1].type == .lazy_seq) {
            current = result.pop() orelse break;
        } else {
            break;
        }
    }
    if (current.type != .lazy_seq) {
        current.deinit(allocator);
    }
    return Value.listValue(result);
}

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    // Memory trace: toggle with CLJVM_MEM_TRACE=1 (stderr) or CLJVM_MEM_TRACE=file:path
    // The tracing condition is evaluated once at startup. When disabled, log_fn is null
    // so every alloc/free has zero overhead beyond the wrapped allocator call.

    // Slab allocator: sits between page_allocator and GC.
    // Reduces system calls by batching small allocations into large pages.
    var slab = slab_allocator.SlabAllocator.init(std.heap.page_allocator);
    defer slab.deinit();

    // GC allocator: wraps slab allocator, provides mark-and-sweep garbage collection.
    // All persistent Clojure values are allocated through the GC.
    var gc_instance = gc_mod.GC.init(slab.allocator());
    defer gc_instance.deinit();
    // GC is the sole allocator — no arena in use.
    gc_instance.setSweepEnabled(true);
    gc_instance.setAutoGC(gc_scan.valueScanFn);
    gc_mod.current_gc = &gc_instance;

    // Optional debug tracing on top of GC (zero overhead when disabled).
    var debug_alloc: debug_allocator.DebugAllocator = undefined;
    if (debug_allocator.getMemTraceConfig(init.environ)) |trace_cfg| {
        defer std.heap.page_allocator.free(trace_cfg);
        debug_alloc = debug_allocator.DebugAllocator.init(gc_instance.allocator(), trace_cfg);
    } else {
        debug_alloc = debug_allocator.DebugAllocator.init(gc_instance.allocator(), null);
    }
    defer debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    // Read environment variables once at startup into a map.
    // Valid for the lifetime of the process — no cleanup needed.
    io_mod.env_vars = std.process.Environ.createMap(init.environ, allocator) catch std.process.Environ.Map.init(allocator);

    // Create namespace manager
    var ns_mgr = try Value.NamespaceManager.init(allocator);
    // No defer deinit — GC handles cleanup at program exit.
    // Calling deinit after GC sweep would access freed memory.

    // Create global environment
    var env: Env = Env.init(allocator);
    // No defer deinit — GC handles cleanup at program exit.
    env.ns_manager = ns_mgr;

    // Create clojure.core namespace — this is the public API namespace.
    // All Clojure-facing functions live here.
    const clojure_core_env = try ns_mgr.createNamespace("clojure.core");
    clojure_core_env.parent = null;
    clojure_core_env.ns_manager = ns_mgr; // needed for findNsManager resolution

    // Create zig.core virtual namespace — internal implementation detail.
    // Raw Zig builtins live here. Clojure wrappers in clojure.core call zig.core/... internally.
    const zc_env = try ns_mgr.createNamespace("zig.core");
    zc_env.parent = null; // isolated — doesn't inherit from any namespace

    // Register Zig built-in functions directly in zig.core namespace.
    // No global builtins in root env — everything is namespaced.
    try core.registerCoreFunctions(zc_env);

    // Copy builtins to clojure.core as well, so they are directly accessible.
    // The Clojure wrappers in core.clj will shadow these with docstrings.
    try copyBuiltinsToNamespace(zc_env, clojure_core_env);

    // Load embedded Clojure core library into clojure.core namespace.
    // The defn wrappers shadow the raw builtins with docstrings.
    try loadCoreLibrary(allocator, clojure_core_env);

    // Check for --parse-debug early (before loading regexp library)
    // so it can diagnose regexp.clj syntax errors without crashing.
    {
        var early_it = try std.process.Args.Iterator.initAllocator(init.args, allocator);
        defer early_it.deinit();
        _ = early_it.next(); // skip program name
        while (true) {
            const arg = early_it.next() orelse break;
            if (std.mem.eql(u8, arg, "--parse-debug")) {
                const filename = early_it.next() orelse {
                    try writeStderr("Error: missing filename after --parse-debug\n");
                    std.process.exit(1);
                };
                try runParseDebug(allocator, filename);
                std.process.exit(0);
            }
        }
    }

    // Create zig.regexp virtual namespace — regexp engine in pure Zig.
    // Parent set to clojure.core so regexp code can use core functions.
    const zr_env = try ns_mgr.createNamespace("zig.regexp");
    zr_env.parent = clojure_core_env;

    // Register regexp built-in functions into zig.regexp namespace.
    try regexp_api.registerRegexpFunctions(zr_env);

    // Set "user" namespace's parent to clojure.core so all functions are visible.
    // This mirrors real Clojure where user namespace refers to clojure.core by default.
    if (ns_mgr.getNamespace("user")) |user_env| {
        user_env.parent = clojure_core_env;
    }

    // Switch back to user namespace after loading core.
    // core.clj starts with (ns clojure.core), so we need to restore user context.
    try ns_mgr.setCurrentNamespace("user");

    // Register GC roots: clojure.core env contains all persistent values (builtins + core.clj defs).
    // Also register namespace envs as roots.
    registerGcRoots(&gc_instance, clojure_core_env, ns_mgr);

    // Count arguments
    const arg_count = countArgs(init.args, allocator);

    // Get user namespace env for REPL and expression evaluation.
    // user namespace has clojure.core as parent, so all functions are visible.
    const user_env = ns_mgr.getNamespace("user") orelse {
        try writeStderr("Error: user namespace not found\n");
        std.process.exit(1);
    };

    if (arg_count == 0) {
        // No arguments: start REPL
        return repl.runRepl(allocator, user_env);
    }

    // Create iterator (initAllocator works on all platforms including Windows)
    var it = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer it.deinit();
    _ = it.next(); // skip program name

    var classpath_set = false;
    var main_ns: ?[]const u8 = null;
    var i: usize = 0;
    while (i < arg_count) : (i += 1) {
        const arg = it.next() orelse break;

        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            const expr = it.next() orelse {
                try writeStderr("Error: missing expression after -e\n");
                std.process.exit(1);
            };
            try runExpression(allocator, expr, user_env);
            // Collect after function returns so local vars are out of scope
            if (gc_mod.current_gc) |gc| gc.collect(gc_scan.valueScanFn);
        } else if (std.mem.eql(u8, arg, "-cp") or std.mem.eql(u8, arg, "--classpath")) {
            const cp = it.next() orelse {
                try writeStderr("Error: missing classpath after -cp\n");
                std.process.exit(1);
            };
            // Split classpath on ':' (Unix) or ';' (Windows)
            var cp_iter = std.mem.splitScalar(u8, cp, ':');
            while (cp_iter.next()) |dir| {
                if (dir.len > 0) try ns_mgr.addClasspath(dir);
            }
            classpath_set = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--main")) {
            main_ns = it.next() orelse {
                try writeStderr("Error: missing namespace after -m\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage() catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--repl")) {
            try repl.runRepl(allocator, user_env);
        } else {
            // Treat as a file to execute
            try runFile(allocator, arg, user_env);
            // Collect after function returns so local vars are out of scope
            if (gc_mod.current_gc) |gc| gc.collect(gc_scan.valueScanFn);
        }
    }

    // If -m was specified, execute the main function
    if (main_ns) |ns_name| {
        if (!classpath_set) {
            try writeStderr("Error: -m requires -cp to be set\n");
            std.process.exit(1);
        }
        try runMain(allocator, user_env, ns_name);
        // Collect after function returns so local vars are out of scope
        if (gc_mod.current_gc) |gc| gc.collect(gc_scan.valueScanFn);
    }
}

/// Copy all builtin_fn values from the root env into a target namespace env.
/// builtinFnValue clones are cheap (just a function pointer, no heap data).
fn copyBuiltinsToNamespace(root_env: *Env, target_env: *Env) anyerror!void {
    var it = root_env.entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.type == .builtin_fn) {
            // Skip zig-only functions that should not leak into clojure.core
            if (std.mem.eql(u8, entry.key_ptr.*, "temp-dir")) continue;
            // builtinFnValue is just a function pointer — clone is trivial
            try target_env.put(entry.key_ptr.*, Value.builtinFnValue(entry.value_ptr.builtin_fn_val));
        }
    }
}

/// Load the embedded Clojure core library silently (no output for defn names).
/// Uses main allocator directly since all values must persist.
fn loadCoreLibrary(allocator: Allocator, env: *Env) anyerror!void {
    const content = core_clj.core_clj_source;

    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();

    var forms = try p.parseAll();
    defer forms.deinit(allocator);

    for (forms.items) |form| {
        var result = try eval.eval(allocator, allocator, form, env);
        result.deinit(allocator);
        // Silent: don't print results during core library loading
    }
}

fn countArgs(args: std.process.Args, allocator: std.mem.Allocator) usize {
    var it = std.process.Args.Iterator.initAllocator(args, allocator) catch unreachable;
    defer it.deinit();
    var count: usize = 0;
    while (it.next()) |_| : (count += 1) {}
    return count - 1; // subtract program name
}

/// Get the current namespace's env for evaluation.
fn getCurrentNsEnv(env: *Env) ?*Env {
    const ns_mgr = eval.findNsManager(env) orelse return null;
    const current_ns = ns_mgr.getCurrentNamespace();
    return ns_mgr.getNamespace(current_ns);
}

fn runExpression(allocator: Allocator, expr: []const u8, env: *Env) anyerror!void {
    var p = try parser.Parser.init(allocator, expr);
    defer p.deinit();

    const forms = try p.parseAll();
    // Don't deinit forms — all values are GC-managed.
    // The GC will clean up at program exit.

    // Evaluate each form and print non-nil results (matching JVM clojure -e)
    // Protect the forms buffer as a GC root for the entire loop —
    // user code (e.g. zig.core/gc-sweep) may trigger collection mid-loop.
    if (gc_mod.current_gc) |gc| {
        if (forms.items.len > 0) {
            gc.addRoot(@as(*anyopaque, @ptrCast(forms.items.ptr)));
        }
    }
    defer {
        if (gc_mod.current_gc) |gc| {
            if (forms.items.len > 0) {
                gc.removeRoot(@as(*anyopaque, @ptrCast(forms.items.ptr)));
            }
        }
    }

    for (forms.items) |form| {
        // Use current namespace's env for evaluation
        const eval_env = getCurrentNsEnv(env) orelse env;
        const result = try eval.eval(allocator, allocator, form, eval_env);

        if (!result.equals(Value.nilValue())) {
            const print_val = if (result.type == .lazy_seq) blk: {
                const realized = try fullyRealizeLazySeq(allocator, result);
                break :blk realized;
            } else result;
            const formatted = try print_val.fmt(allocator);
            defer allocator.free(formatted);
            // Don't deinit print_val/result — GC handles it
            try writeStdout(formatted);
            try writeStdout("\n");
        }

        // Don't deinit result — GC handles it
        // Auto-GC: check threshold between form evaluations (safe point).
        if (gc_mod.current_gc) |gc| gc.tryAutoCollect();
    }
}

fn runFile(allocator: Allocator, filename: []const u8, env: *Env) anyerror!void {
    // Detect /dev/stdin — treat as REPL-like (print results) to match JVM clojure
    // where piped input runs as REPL. Regular script files are silent.
    const print_results = std.mem.eql(u8, filename, "/dev/stdin");

    const cwd = std.Io.Dir.cwd();
    var file = try std.Io.Dir.openFile(cwd, std.Options.debug_io, filename, .{});
    defer std.Io.File.close(file, std.Options.debug_io);

    var reader = file.reader(std.Options.debug_io, &[_]u8{});
    const content = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    // No defer free — source content is GC-managed but not a root.
    // After heavy GC activity it may be swept. OS reclaims on exit.

    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();

    var forms = try p.parseAll();
    defer forms.deinit(allocator);

    // Protect the forms buffer as a GC root for the entire loop —
    // user code (e.g. zig.core/gc-sweep) may trigger collection mid-loop.
    if (gc_mod.current_gc) |gc| {
        if (forms.items.len > 0) {
            gc.addRoot(@as(*anyopaque, @ptrCast(forms.items.ptr)));
        }
    }
    defer {
        if (gc_mod.current_gc) |gc| {
            if (forms.items.len > 0) {
                gc.removeRoot(@as(*anyopaque, @ptrCast(forms.items.ptr)));
            }
        }
    }

    for (forms.items) |form| {
        // Get current namespace's env for each form (ns form may change it)
        const eval_env = getCurrentNsEnv(env) orelse env;
        var result = try eval.eval(allocator, allocator, form, eval_env);

        if (print_results and !result.equals(Value.nilValue())) {
            var print_val: Value = undefined;
            if (result.type == .lazy_seq) {
                print_val = try fullyRealizeLazySeq(allocator, result);
                result.lazy_seq_val.thunk = null;
            } else {
                print_val = result;
            }
            const formatted = try print_val.fmt(allocator);
            defer allocator.free(formatted);
            print_val.deinit(allocator);
            try writeStdout(formatted);
            try writeStdout("\n");
        }

        result.deinit(allocator);
        // Auto-GC: check threshold between form evaluations (safe point).
        if (gc_mod.current_gc) |gc| gc.tryAutoCollect();
    }

}

var __num_buf: [20]u8 = undefined;

fn allNum(n: usize) []const u8 {
    return std.fmt.bufPrint(&__num_buf, "{d}", .{n}) catch "?";
}

fn allNumI32(n: i32) []const u8 {
    return std.fmt.bufPrint(&__num_buf, "{d}", .{n}) catch "?";
}

/// Parse a file and print debug info for each form (for debugging syntax issues).
fn runParseDebug(allocator: Allocator, filename: []const u8) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    var file = try std.Io.Dir.openFile(cwd, std.Options.debug_io, filename, .{});
    defer std.Io.File.close(file, std.Options.debug_io);

    var reader = file.reader(std.Options.debug_io, &[_]u8{});
    const content = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);

    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();
    p.debug_mode = true;

    var form_idx: usize = 0;
    while (true) {
        switch (p.current) {
            .eof => break,
            else => {},
        }

        _ = p.parse() catch |err| {
            const line = p.lexer.currentLine();
            std.debug.print("## PARSEDEBUG Line:{d} PARSE ERROR: {s}\n", .{ line, @errorName(err) });
            break;
        };

        form_idx += 1;
    }

    if (p.debug_stack.items.len > 0) {
        std.debug.print("\n## PARSEDEBUG UNMATCHED: {d} forms still open on stack\n", .{p.debug_stack.items.len});
    } else {
        std.debug.print("\n## PARSEDEBUG All forms matched. Total: {d} forms.\n", .{form_idx});
    }
}

/// Binary search for line number given a byte offset.
fn findLineNumber(line_starts: []const usize, offset: usize) usize {
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (offset < line_starts[mid]) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return lo; // 1-based line number
}

/// Run the -main function from a namespace.
/// This is called when -m flag is used.
fn runMain(allocator: Allocator, env: *Env, ns_name: []const u8) anyerror!void {
    // Find the namespace manager
    const ns_mgr = eval.findNsManager(env) orelse {
        try writeStderr("Error: no namespace manager available\n");
        std.process.exit(1);
    };

    // Resolve namespace to file path and load it
    const file_path = try ns_mgr.resolveNamespaceToPath(allocator, ns_name) orelse {
        const msg = try std.fmt.allocPrint(allocator, "Error: namespace '{s}' not found on classpath\n", .{ns_name});
        defer allocator.free(msg);
        try writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(file_path);

    // Read and evaluate the file
    const cwd = std.Io.Dir.cwd();
    var file = try std.Io.Dir.openFile(cwd, std.Options.debug_io, file_path, .{});
    defer std.Io.File.close(file, std.Options.debug_io);

    var reader = file.reader(std.Options.debug_io, &[_]u8{});
    const content = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    // No defer free — same reasoning as runFile.

    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();

    var forms = try p.parseAll();
    defer forms.deinit(allocator);

    for (forms.items) |form| {
        var result = try eval.eval(allocator, allocator, form, env);
        result.deinit(allocator);
    }

    // Look up -main function in the namespace
    const ns_env = ns_mgr.getNamespace(ns_name) orelse {
        const msg = try std.fmt.allocPrint(allocator, "Error: namespace '{s}' not loaded\n", .{ns_name});
        defer allocator.free(msg);
        try writeStderr(msg);
        std.process.exit(1);
    };

    // Look for -main in the namespace env
    const main_fn = ns_env.get("-main") orelse {
        const msg = try std.fmt.allocPrint(allocator, "Error: no -main function in namespace '{s}'\n", .{ns_name});
        defer allocator.free(msg);
        try writeStderr(msg);
        std.process.exit(1);
    };

    // Call (-main) with no arguments
    var call_list: list.List = .empty;
    defer call_list.deinit(allocator);
    try call_list.append(allocator, try main_fn.clone(allocator));
    var call_result = try eval.eval(allocator, allocator, Value.listValue(call_list), ns_env);
    call_result.deinit(allocator);

}

/// GC root callback: scans all env entries and NamespaceManager data.
fn gcRootCallback(gc_inst: *gc_mod.GC) void {
    var ctx = gc_mod.ScanContext{ .gc = gc_inst, .scan_fn = gc_scan.valueScanFn };
    // This function is called from within gc.collect().
    // We use static pointers set up during registration.
    if (gc_root_env) |env| {
        // Mark the Env struct itself (allocated via GC allocator)
        gc_inst.markRecursive(env, &ctx);
        scanEnvEntriesDirect(env, gc_inst);
    }
    if (gc_root_ns_mgr) |ns_mgr| {
        // Mark the NamespaceManager struct itself (allocated via GC allocator)
        gc_inst.markRecursive(ns_mgr, &ctx);
        // Register NamespaceManager's own allocations as roots.
        // These are not part of any Value, so the scan function won't find them.
        if (ns_mgr.current_ns.len > 0) {
            gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(ns_mgr.current_ns.ptr))), &ctx);
        }
        // Mark the namespaces HashMap's entries buffer (MultiArrayList bytes).
        // Set type to unknown so it's not scanned (it's not a Value array).
        if (ns_mgr.namespaces.entries.len > 0) {
            gc_inst.setObjectType(ns_mgr.namespaces.entries.bytes, gc_mod.GCObjectType.unknown);
            gc_inst.markRecursive(ns_mgr.namespaces.entries.bytes, &ctx);
        }
        // Mark the namespaces HashMap's index_header (separate allocation)
        if (ns_mgr.namespaces.index_header) |header| {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(header)), gc_mod.GCObjectType.unknown);
            gc_inst.markRecursive(@as(*anyopaque, @ptrCast(header)), &ctx);
        }
        // Namespace names (keys in the namespaces map)
        var nit = ns_mgr.namespaces.iterator();
        while (nit.next()) |entry| {
            // Key string
            if (entry.key_ptr.*.len > 0) {
                gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(entry.key_ptr.*.ptr))), &ctx);
            }
            // Mark the Env struct itself (allocated via GC allocator)
            gc_inst.markRecursive(entry.value_ptr.*, &ctx);
            // Namespace env entries
            scanEnvEntriesDirect(entry.value_ptr.*, gc_inst);
        }
        // Classpath entries buffer + individual strings
        if (ns_mgr.classpath.items.len > 0) {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(ns_mgr.classpath.items.ptr)), gc_mod.GCObjectType.unknown);
            gc_inst.markRecursive(@as(*anyopaque, @ptrCast(ns_mgr.classpath.items.ptr)), &ctx);
        }
        for (ns_mgr.classpath.items) |dir| {
            if (dir.len > 0) {
                gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(dir.ptr))), &ctx);
            }
        }
        // Aliases HashMap entries buffer + strings
        if (ns_mgr.aliases.entries.len > 0) {
            gc_inst.setObjectType(ns_mgr.aliases.entries.bytes, gc_mod.GCObjectType.unknown);
            gc_inst.markRecursive(ns_mgr.aliases.entries.bytes, &ctx);
        }
        // Mark the aliases HashMap's index_header (separate allocation)
        if (ns_mgr.aliases.index_header) |header| {
            gc_inst.setObjectType(@as(*anyopaque, @ptrCast(header)), gc_mod.GCObjectType.unknown);
            gc_inst.markRecursive(@as(*anyopaque, @ptrCast(header)), &ctx);
        }
        var ait = ns_mgr.aliases.iterator();
        while (ait.next()) |aentry| {
            if (aentry.key_ptr.*.len > 0) {
                gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(aentry.key_ptr.*.ptr))), &ctx);
            }
            // Mark inner HashMap (NamespaceAliases) entries buffer + index_header
            const inner_map = aentry.value_ptr.*;
            if (inner_map.entries.len > 0) {
                gc_inst.setObjectType(@as(*anyopaque, @ptrCast(inner_map.entries.bytes)), gc_mod.GCObjectType.unknown);
                gc_inst.markRecursive(@as(*anyopaque, @ptrCast(inner_map.entries.bytes)), &ctx);
            }
            if (inner_map.index_header) |header| {
                gc_inst.setObjectType(@as(*anyopaque, @ptrCast(header)), gc_mod.GCObjectType.unknown);
                gc_inst.markRecursive(@as(*anyopaque, @ptrCast(header)), &ctx);
            }
            var nit2 = inner_map.iterator();
            while (nit2.next()) |aentry2| {
                if (aentry2.key_ptr.*.len > 0) {
                    gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(aentry2.key_ptr.*.ptr))), &ctx);
                }
                if (aentry2.value_ptr.*.len > 0) {
                    gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(aentry2.value_ptr.*.ptr))), &ctx);
                }
            }
        }
    }
    // Mark REPL input history buffer so it survives sweeps.
    if (gc_mod.repl_history_buffer.len > 0) {
        gc_inst.setObjectType(
            @as(*anyopaque, @ptrCast(@constCast(gc_mod.repl_history_buffer.ptr))),
            gc_mod.GCObjectType.unknown,
        );
        gc_inst.markRecursive(
            @as(*anyopaque, @ptrCast(@constCast(gc_mod.repl_history_buffer.ptr))),
            &ctx,
        );
    }
}

/// Scan all Values in an env's entries and mark their child pointers.
fn scanEnvEntriesDirect(env: *Env, gc_inst: *gc_mod.GC) void {
    var ctx = gc_mod.ScanContext{ .gc = gc_inst, .scan_fn = gc_scan.valueScanFn };
    // Mark the entries buffer itself (MultiArrayList bytes)
    if (env.entries.entries.len > 0) {
        const bytes_ptr = @as(*anyopaque, @ptrCast(env.entries.entries.bytes));
        gc_inst.setObjectType(bytes_ptr, gc_mod.GCObjectType.unknown);
        gc_inst.markRecursive(bytes_ptr, &ctx);
    }
    // Mark the index_header (separate allocation for the hash index array)
    if (env.entries.index_header) |header| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(header)), gc_mod.GCObjectType.unknown);
        gc_inst.markRecursive(@as(*anyopaque, @ptrCast(header)), &ctx);
    }
    var it = env.entries.iterator();
    while (it.next()) |entry| {
        // Mark the key string data
        if (entry.key_ptr.*.len > 0) {
            gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(entry.key_ptr.*.ptr))), &ctx);
        }
        // Scan the Value's child pointers
        gc_scan.scanValueChildrenDirect(entry.value_ptr, &ctx);
    }
    // Mark referred_names list (strings added via :refer)
    if (env.referred_names.items.len > 0) {
        const items_ptr = @as(*anyopaque, @ptrCast(env.referred_names.items.ptr));
        gc_inst.setObjectType(items_ptr, gc_mod.GCObjectType.unknown);
        gc_inst.markRecursive(items_ptr, &ctx);
        for (env.referred_names.items) |name| {
            if (name.len > 0) {
                gc_inst.markRecursive(@as(*anyopaque, @ptrCast(@constCast(name.ptr))), &ctx);
            }
        }
    }
}

// Static pointers for root callback
var gc_root_env: ?*Env = null;
var gc_root_ns_mgr: ?*Value.NamespaceManager = null;

/// Register GC roots: main env entries + namespace env entries.
fn registerGcRoots(gc_inst: *gc_mod.GC, env: *Env, ns_mgr: *Value.NamespaceManager) void {
    gc_root_env = env;
    gc_root_ns_mgr = ns_mgr;
    gc_inst.root_fn = gcRootCallback;
}

fn printUsage() anyerror!void {
    try writeStdout(
        \\Usage: clojure-vm [OPTIONS] [FILE]
        \\
        \\Options:
        \\  -e, --eval EXPR   Evaluate expression and exit
        \\  --repl            Start interactive REPL
        \\  -h, --help        Show this help message
        \\
        \\If no options are given, starts an interactive REPL.
        \\If a file is given, executes the file.
        \\
    );
}

fn writeStdout(data: []const u8) anyerror!void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Options.debug_io, &buf);
    try writer.interface.writeAll(data);
    writer.flush() catch {};
}

fn writeStderr(data: []const u8) anyerror!void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writer(std.Options.debug_io, &buf);
    try writer.interface.writeAll(data);
    writer.flush() catch {};
}
