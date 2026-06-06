const std = @import("std");
const Value = @import("value.zig");
const Env = Value.Env;
const list = @import("list.zig");
const core = @import("core.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const repl = @import("repl.zig");
const core_clj = @import("core_clj.zig");
const debug_allocator = @import("debug_allocator.zig");
const slab_allocator = @import("slab_allocator.zig");
const sequences = @import("core/sequences.zig");

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

    // Slab allocator: sits between page_allocator and debug_allocator.
    // Reduces system calls by batching small allocations into large pages.
    var slab = slab_allocator.SlabAllocator.init(std.heap.page_allocator);
    defer slab.deinit();

    var debug_alloc: debug_allocator.DebugAllocator = undefined;
    if (debug_allocator.getMemTraceConfig(init.environ)) |trace_cfg| {
        defer std.heap.page_allocator.free(trace_cfg);
        debug_alloc = debug_allocator.DebugAllocator.init(slab.allocator(), trace_cfg);
    } else {
        debug_alloc = debug_allocator.DebugAllocator.init(slab.allocator(), null);
    }
    defer debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    // Create namespace manager
    var ns_mgr = try Value.NamespaceManager.init(allocator);
    defer ns_mgr.deinit();

    // Create global environment
    var env: Env = Env.init(allocator);
    defer env.deinit(allocator);
    env.ns_manager = ns_mgr;

    // Set "user" namespace's parent to root env so builtins are visible
    if (ns_mgr.getNamespace("user")) |user_env| {
        user_env.parent = &env;
    }

    // Register Zig built-in functions
    try core.registerCoreFunctions(&env);

    // Load embedded Clojure core library (silent — no output)
    try loadCoreLibrary(allocator, &env);

    // Parse arguments
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // skip program name

    const arg_count = countArgs(init.args);

    if (arg_count == 0) {
        // No arguments: start REPL
        return repl.runRepl(allocator, &env);
    }

    // Reset iterator and skip program name
    args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var classpath_set = false;
    var main_ns: ?[]const u8 = null;
    var i: usize = 0;
    while (i < arg_count) : (i += 1) {
        const arg = args.next() orelse break;

        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            const expr = args.next() orelse {
                try writeStderr("Error: missing expression after -e\n");
                std.process.exit(1);
            };
            try runExpression(allocator, expr, &env);
        } else if (std.mem.eql(u8, arg, "-cp") or std.mem.eql(u8, arg, "--classpath")) {
            const cp = args.next() orelse {
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
            main_ns = args.next() orelse {
                try writeStderr("Error: missing namespace after -m\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage() catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--repl")) {
            try repl.runRepl(allocator, &env);
        } else {
            // Treat as a file to execute
            try runFile(allocator, arg, &env);
        }
    }

    // If -m was specified, execute the main function
    if (main_ns) |ns_name| {
        if (!classpath_set) {
            try writeStderr("Error: -m requires -cp to be set\n");
            std.process.exit(1);
        }
        try runMain(allocator, &env, ns_name);
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

fn countArgs(args: std.process.Args) usize {
    var it = std.process.Args.Iterator.init(args);
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var p = try parser.Parser.init(arena_alloc, expr);
    defer p.deinit();

    var form = Value.nilValue();
    errdefer form.deinit(arena_alloc);
    form = try p.parse();
    // Use current namespace's env for evaluation
    const eval_env = getCurrentNsEnv(env) orelse env;
    var result = try eval.eval(allocator, arena_alloc, form, eval_env);
    defer result.deinit(arena_alloc);

    // Force lazy-seqs before printing
    if (result.type == .lazy_seq) {
        var realized = try fullyRealizeLazySeq(allocator, result);
        // Null out the thunk to prevent double-free from the defer
        result.lazy_seq_val.thunk = null;
        const formatted = try realized.fmt(allocator);
        defer allocator.free(formatted);
        realized.deinit(allocator);
        try writeStdout(formatted);
        try writeStdout("\n");
        return;
    }

    const formatted = try result.fmt(allocator);
    defer allocator.free(formatted);
    try writeStdout(formatted);
    try writeStdout("\n");
}

fn runFile(allocator: Allocator, filename: []const u8, env: *Env) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    var file = try std.Io.Dir.openFile(cwd, std.Options.debug_io, filename, .{});
    defer std.Io.File.close(file, std.Options.debug_io);

    var reader = file.reader(std.Options.debug_io, &[_]u8{});
    const content = try reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var p = try parser.Parser.init(arena_alloc, content);
    defer p.deinit();

    var forms = try p.parseAll();
    defer forms.deinit(arena_alloc);

    for (forms.items) |form| {
        // Get current namespace's env for each form (ns form may change it)
        const eval_env = getCurrentNsEnv(env) orelse env;
        var result = try eval.eval(allocator, arena_alloc, form, eval_env);

        // Print non-nil results (like Clojure REPL)
        if (!result.equals(Value.nilValue())) {
            var print_val: Value = undefined;
            if (result.type == .lazy_seq) {
                print_val = try fullyRealizeLazySeq(allocator, result);
                // Null out the thunk to prevent double-free
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

        result.deinit(arena_alloc);
    }
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
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var p = try parser.Parser.init(arena_alloc, content);
    defer p.deinit();

    var forms = try p.parseAll();
    defer forms.deinit(arena_alloc);

    for (forms.items) |form| {
        var result = try eval.eval(allocator, arena_alloc, form, env);
        result.deinit(arena_alloc);
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
    defer call_list.deinit(arena_alloc);
    try call_list.append(arena_alloc, try main_fn.clone(arena_alloc));
    var call_result = try eval.eval(allocator, arena_alloc, Value.listValue(call_list), ns_env);
    call_result.deinit(arena_alloc);
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
