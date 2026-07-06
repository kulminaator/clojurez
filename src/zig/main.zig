const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const Env = vm.Env;
const list = @import("list.zig");
const core = @import("namespaces/core/core.zig");
const io_mod = @import("namespaces/core/io.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const repl = @import("repl.zig");
const core_clj = @import("namespaces/core/core_clj.zig");
const string_clj = @import("namespaces/core/string_clj.zig");
const io_clj = @import("namespaces/core/io_clj.zig");
const io_fs = @import("namespaces/core/io_fs.zig");
const io_stream = @import("namespaces/core/io_stream.zig");
const io_shell = @import("namespaces/core/io_shell.zig");
const strings = @import("namespaces/core/strings.zig");
const regexp_api = @import("namespaces/regexp/api.zig");
const debug_allocator = @import("debug_allocator.zig");
const slab_allocator = @import("slab_allocator.zig");
const debug = @import("debug.zig");
const gc_mod = @import("gc.zig");
const gc_scan = @import("gc_scan.zig");
const stack_stats = @import("stack_stats.zig");
const sequences = @import("namespaces/core/sequences.zig");
const phm = @import("persistent_hash_map.zig");

const Allocator = std.mem.Allocator;

/// Fully realize a lazy-seq into a concrete list for printing.
fn fullyRealizeLazySeq(allocator: Allocator, val: Value) anyerror!Value {
    if (std.meta.activeTag(val) != .lazy_seq) return try vm.clone(&val, allocator);

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var current: Value = val;
    var max_iter: usize = 100000;
    while (max_iter > 0) : (max_iter -= 1) {
        if (std.meta.activeTag(current) != .lazy_seq) break;

        var forced = try sequences.forceLazySeqHelper(allocator, current);
        vm.valueDeinit(&current, allocator);

        if (std.meta.activeTag(forced) != .list) {
            vm.valueDeinit(&forced, allocator);
            break;
        }

        for (forced.list.items.items) |item| {
            if (std.meta.activeTag(item) == .lazy_seq) {
                const realized = try fullyRealizeLazySeq(allocator, item);
                if (std.meta.activeTag(realized) == .list) {
                    for (realized.list.items.items) |ri| {
                        try result.append(allocator, try vm.clone(&ri, allocator));
                    }
                } else {
                    try result.append(allocator, realized);
                }
            } else {
                try result.append(allocator, try vm.clone(&item, allocator));
            }
        }
        vm.valueDeinit(&forced, allocator);

        if (result.items.len > 0 and std.meta.activeTag(result.items[result.items.len - 1]) == .lazy_seq) {
            current = result.pop() orelse break;
        } else {
            break;
        }
    }
    if (std.meta.activeTag(current) != .lazy_seq) {
        vm.valueDeinit(&current, allocator);
    }
    return try vm.listValue(allocator, result);
}

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    // Record the earliest possible stack pointer baseline.
    stack_stats.recordAppBaseline();

    // --parse-debug: handle BEFORE any VM initialization.
    // Needs only a simple allocator — no GC, no namespaces, no library loading.
    {
        var args_it = std.process.Args.Iterator.initAllocator(init.args, std.heap.page_allocator) catch unreachable;
        _ = args_it.next(); // skip program name
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--parse-debug")) {
                const filename = args_it.next() orelse {
                    std.debug.print("Error: missing filename after --parse-debug\n", .{});
                    std.process.exit(1);
                };
                _ = runParseDebug(std.heap.page_allocator, filename) catch {};
                std.process.exit(0);
            }
        }
    }

    // Debug output: toggle with CLJVM_DEBUG=1 (all) or CLJVM_DEBUG=gc,eval (categories)
    debug.init(init.environ);
    debug.log("startup", "clojurez starting", .{});

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
    // Sweep can be disabled at startup via CLJVM_GC_SWEEP=0 for debugging.
    gc_instance.setSweepEnabled(gc_mod.isGcSweepEnabled(init.environ));
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
    var ns_mgr = try vm.NamespaceManager.init(allocator);
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
    try stack_stats.registerStackStats(zc_env);

    // Copy builtins to clojure.core as well, so they are directly accessible.
    // The Clojure wrappers in core.clj will shadow these with docstrings.
    try copyBuiltinsToNamespace(zc_env, clojure_core_env);

    // Load embedded Clojure core library into clojure.core namespace.
    // The defn wrappers shadow the raw builtins with docstrings.
    try loadCoreLibrary(allocator, clojure_core_env);

    // Record vm-baseline after core library is fully loaded.
    stack_stats.recordVMBaseline();

    // Create clojure.string namespace — string utility functions.
    // Parent set to clojure.core so string code can use core functions.
    const cs_env = try ns_mgr.createNamespace("clojure.string");
    cs_env.parent = clojure_core_env;
    cs_env.ns_manager = ns_mgr;

    // Register clojure.string built-in functions in zig.core (same pattern as other builtins).
    // The Clojure wrappers in string.clj reference zig.core/upper-case etc.
    try strings.registerStringNamespaceFunctions(zc_env);

    // Load embedded Clojure string library into clojure.string namespace.
    // The defn wrappers shadow the raw builtins with docstrings.
    try loadStringLibrary(allocator, cs_env);

    // Create zig.regexp virtual namespace — regexp engine in pure Zig.
    // Parent set to clojure.core so regexp code can use core functions.
    const zr_env = try ns_mgr.createNamespace("zig.regexp");
    zr_env.parent = clojure_core_env;

    // Register regexp built-in functions into zig.regexp namespace.
    try regexp_api.registerRegexpFunctions(zr_env);
    try zr_env.markAllOwned();

    // Create zig.io namespace — I/O utilities for ClojureZ.
    // Parent set to clojure.core so io code can use core functions.
    const zio_env = try ns_mgr.createNamespace("zig.io");
    zio_env.parent = clojure_core_env;
    zio_env.ns_manager = ns_mgr;

    // Register zig.io filesystem, stream, and shell built-in functions.
    // The Clojure wrappers in io.clj reference zig.io/file-stat etc.
    try io_fs.registerFsFunctions(zio_env);
    try io_stream.registerStreamFunctions(zio_env);
    try io_shell.registerShellFunctions(zio_env);
    try zio_env.markAllOwned();

    // Register colliding builtins in zig.core (copy, sh-wait, sh-kill)
    // These have Clojure wrappers with the same name in zig.io,
    // so the wrappers reference zig.core/ to avoid shadowing.
    try zc_env.put("copy", vm.builtinFnValue(io_fs.core_copy));
    try zc_env.put("sh-wait", vm.builtinFnValue(io_shell.core_sh_wait));
    try zc_env.put("sh-kill", vm.builtinFnValue(io_shell.core_sh_kill));
    // Mark all zig.core builtins as owned so ns-interns works correctly.
    try zc_env.markAllOwned();

    // Copy I/O builtins to clojure.core for direct access
    try copyBuiltinsToNamespaceSelective(zio_env, clojure_core_env, &.{
        "file-stat", "file-exists?", "file-size", "is-directory?", "is-file?",
        "is-symlink?", "list-dir", "walk-dir", "make-dir", "make-parents",
        "delete-file", "delete-dir", "delete-tree", "rename", "copy-file",
        "sym-link", "read-link", "file-modified-time", "file-parent",
        "file-name", "absolute-path", "sh-execute",
        "open-input-stream", "open-output-stream", "read-bytes", "write-bytes",
        "open-reader", "open-writer", "read-line-stream", "write-string",
        "close-stream", "flush-stream",
        "sh-execute-stream", "sh-read-output", "sh-read-error",
        "sh-write-input", "sh-close-input",
    });
    // Also copy the colliding builtins from zig.core to clojure.core
    try copyBuiltinsToNamespaceSelective(zc_env, clojure_core_env, &.{"copy", "sh-wait", "sh-kill"});

    // Load embedded Clojure I/O library into zig.io namespace.
    try loadIoLibrary(allocator, zio_env);

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

    // Register all namespace environments and NamespaceManager as permanent roots.
    // Permanent roots are NEVER swept — they and everything reachable from them
    // (function definitions, vars, metadata) survive all GC cycles.
    registerPermanentRoots(&gc_instance, ns_mgr, clojure_core_env, zc_env, cs_env, zr_env, zio_env);

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
            // For file execution, skip post-run GC — OS reclaims all memory on exit.
            // The GC deinit is now O(1) (just resets pointers, no individual block freeing).
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
    // Wait for detached threads to finish their cleanup (gc.threadDone, env.deinit, etc.)
    // before we deinitialize the GC and slab allocator. Without this, detached threads
    // may access freed memory during their defer cleanup, causing SIGABRT on macOS.
    if (gc_mod.current_gc) |gc| gc.waitForThreads();
    debug.log("startup", "clojurez shutting down", .{});
}

/// Copy all builtin_fn values from the root env into a target namespace env.
/// builtinFnValue clones are cheap (just a function pointer, no heap data).
fn copyBuiltinsToNamespace(root_env: *Env, target_env: *Env) anyerror!void {
    var it = root_env.entries.entryIterator();
    while (it.next()) |entry| {
        if (std.meta.activeTag(entry.val) == .builtin_fn) {
            // Skip zig-only functions that should not leak into clojure.core
            if (std.meta.activeTag(entry.key) == .symbol and std.mem.eql(u8, entry.key.symbol, "temp-dir")) continue;
            // builtinFnValue is just a function pointer — clone is trivial
            if (std.meta.activeTag(entry.key) == .symbol) {
                try target_env.put(entry.key.symbol, vm.builtinFnValue(entry.val.builtin_fn));
            }
        }
    }
}

/// Copy only specific builtin_fn values from root env into a target namespace.
fn copyBuiltinsToNamespaceSelective(
    root_env: *Env,
    target_env: *Env,
    names: []const []const u8,
) anyerror!void {
    for (names) |name| {
        const key = phm.sym(name);
        if (root_env.entries.find(key)) |val| {
            if (std.meta.activeTag(val) == .builtin_fn) {
                try target_env.put(name, vm.builtinFnValue(val.builtin_fn));
            }
        }
    }
}

/// Load the embedded Clojure core library silently (no output for defn names).
/// Uses main allocator directly since all values must persist.
fn loadCoreLibrary(allocator: Allocator, env: *Env) anyerror!void {
    const content = core_clj.core_clj_source;

    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();

    const forms = try p.parseAll();
    // GC handles cleanup.

    for (forms.items) |form| {
        const result_ptr = try eval.eval(allocator, form, env);
        vm.valueDeinit(&result_ptr.*, allocator);
        // GC handles result cleanup.
        // Silent: don't print results during core library loading
    }
}

/// Load the embedded Clojure string library silently (no output for defn names).
fn loadStringLibrary(allocator: Allocator, env: *Env) anyerror!void {
    const content = string_clj.string_clj_source;

    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();

    const forms = try p.parseAll();
    // GC handles cleanup.

    for (forms.items) |form| {
        const result_ptr = try eval.eval(allocator, form, env);
        vm.valueDeinit(&result_ptr.*, allocator);
        // GC handles result cleanup.
        // Silent: don't print results during string library loading
    }
}

/// Load the embedded Clojure I/O library silently (no output for defn names).
fn loadIoLibrary(allocator: Allocator, env: *Env) anyerror!void {
    const content = io_clj.io_clj_source;

    var p = try parser.Parser.init(allocator, content);
    defer p.deinit();

    const forms = try p.parseAll();
    // GC handles cleanup.

    for (forms.items) |form| {
        const result_ptr = try eval.eval(allocator, form, env);
        vm.valueDeinit(&result_ptr.*, allocator);
        // GC handles result cleanup.
        // Silent: don't print results during io library loading
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
        const result_ptr = eval.evalWithFile(allocator, form, eval_env, "<string>") catch |err| {
            // Error already formatted with source location in evalWithFile
            std.process.exit(1);
            _ = err;
            unreachable;
        };

        if (!vm.equals(result_ptr.*, vm.nilValue())) {
            const print_val = if (std.meta.activeTag(result_ptr.*) == .lazy_seq) blk: {
                const realized = try fullyRealizeLazySeq(allocator, result_ptr.*);
                break :blk realized;
            } else result_ptr.*;
            const formatted = try vm.fmt(print_val, allocator);
            // GC handles all cleanup — no manual deinit/free for GC-allocated values.
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

    const forms = try p.parseAll();
    // Don't deinit forms — all values are GC-managed.

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
        const result_ptr = eval.evalWithFile(allocator, form, eval_env, filename) catch |err| {
            // Error already formatted with source location in evalWithFile
            std.process.exit(1);
            _ = err; // unreachable but silences unused warning
            unreachable;
        };

        if (print_results and !vm.equals(result_ptr.*, vm.nilValue())) {
            const print_val = if (std.meta.activeTag(result_ptr.*) == .lazy_seq) blk: {
                const realized = try fullyRealizeLazySeq(allocator, result_ptr.*);
                break :blk realized;
            } else result_ptr.*;
            const formatted = try vm.fmt(print_val, allocator);
            // GC handles all cleanup — no manual deinit/free for GC-allocated values.
            try writeStdout(formatted);
            try writeStdout("\n");
        }

        // GC handles result cleanup.
        // For file execution, handle only deferred manual sweeps (from gc-sweep).
        // Skip auto-GC — OS reclaims all memory on exit.
        if (gc_mod.current_gc) |gc| gc.tryDeferredSweep();
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

    const forms = try p.parseAll();
    // GC handles cleanup.

    for (forms.items) |form| {
        const result_ptr = try eval.evalWithFile(allocator, form, env, file_path);
        vm.valueDeinit(&result_ptr.*, allocator);
        // GC handles result cleanup.
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
    try call_list.append(allocator, try vm.clone(&main_fn, allocator));
    const call_result_ptr = try eval.evalWithFile(allocator, try vm.listValue(allocator, call_list), ns_env, file_path);
    vm.valueDeinit(&call_result_ptr.*, allocator);

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
        // Mark the namespaces PersistentHashMap root node.
        // HAMT nodes are tracked via scanHashMapNode which marks keys, values, and wrapped pointers.
        if (ns_mgr.namespaces.root) |root| {
            gc_inst.markRecursive(root, &ctx);
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
        // Mark the aliases PersistentHashMap root node.
        // HAMT nodes are tracked via scanHashMapNode — keys and Value.string values are scanned automatically.
        if (ns_mgr.aliases.root) |root| {
            gc_inst.markRecursive(root, &ctx);
        }
    }
    // Mark REPL input history buffer so it survives sweeps.
    // Use mark() NOT markRecursive() — the buffer contains raw source text bytes,
    // not Value objects. Scanning them as Values causes crashes when raw bytes
    // are interpreted as Value pointers.
    if (gc_mod.repl_history_buffer.len > 0) {
        gc_inst.mark(
            @as(*anyopaque, @ptrCast(@constCast(gc_mod.repl_history_buffer.ptr))),
        );
    }
}

/// Scan all Values in an env's entries and mark their child pointers.
fn scanEnvEntriesDirect(env: *Env, gc_inst: *gc_mod.GC) void {
    var ctx = gc_mod.ScanContext{ .gc = gc_inst, .scan_fn = gc_scan.valueScanFn };
    // Mark the HAMT root node (triggers recursive scanning)
    if (env.entries.root) |root| {
        gc_inst.markRecursive(root, &ctx);
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
var gc_root_ns_mgr: ?*vm.NamespaceManager = null;

/// Register GC roots: main env entries + namespace env entries.
fn registerGcRoots(gc_inst: *gc_mod.GC, env: *Env, ns_mgr: *vm.NamespaceManager) void {
    gc_root_env = env;
    gc_root_ns_mgr = ns_mgr;
    gc_inst.root_fn = gcRootCallback;
}

/// Register all namespace environments and NamespaceManager as permanent roots.
/// Permanent roots are NEVER swept by the GC — they and everything reachable
/// from them (function definitions, vars, metadata) survive all collection cycles.
fn registerPermanentRoots(
    gc_inst: *gc_mod.GC,
    ns_mgr: *vm.NamespaceManager,
    clojure_core: *Env,
    zig_core: *Env,
    clojure_string: *Env,
    zig_regexp: *Env,
    zig_io: *Env,
) void {
    // NamespaceManager — the registry of all namespaces
    gc_inst.addPermanentRoot(@as(*anyopaque, @ptrCast(ns_mgr)));

    // Core namespace environments — contain all function definitions
    gc_inst.addPermanentRoot(@as(*anyopaque, @ptrCast(clojure_core)));
    gc_inst.addPermanentRoot(@as(*anyopaque, @ptrCast(zig_core)));
    gc_inst.addPermanentRoot(@as(*anyopaque, @ptrCast(clojure_string)));
    gc_inst.addPermanentRoot(@as(*anyopaque, @ptrCast(zig_regexp)));
    gc_inst.addPermanentRoot(@as(*anyopaque, @ptrCast(zig_io)));

    // User namespace — default REPL namespace
    if (ns_mgr.getNamespace("user")) |user_env| {
        gc_inst.addPermanentRoot(@as(*anyopaque, @ptrCast(user_env)));
    }
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
