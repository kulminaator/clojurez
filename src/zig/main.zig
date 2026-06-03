const std = @import("std");
const Value = @import("value.zig");
const Env = Value.Env;
const core = @import("core.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const repl = @import("repl.zig");
const core_clj = @import("core_clj.zig");
const debug_allocator = @import("debug_allocator.zig");

const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    // Memory trace: toggle with CLJVM_MEM_TRACE=1 (stderr) or CLJVM_MEM_TRACE=file:path
    // The tracing condition is evaluated once at startup. When disabled, log_fn is null
    // so every alloc/free has zero overhead beyond the wrapped allocator call.
    var debug_alloc: debug_allocator.DebugAllocator = undefined;
    if (debug_allocator.getMemTraceConfig(init.environ)) |trace_cfg| {
        defer std.heap.page_allocator.free(trace_cfg);
        debug_alloc = debug_allocator.DebugAllocator.init(std.heap.page_allocator, trace_cfg);
    } else {
        debug_alloc = debug_allocator.DebugAllocator.init(std.heap.page_allocator, null);
    }
    defer debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    // Create global environment
    var env: Env = Env.init(allocator);
    defer env.deinit(allocator);

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

    var i: usize = 0;
    while (i < arg_count) : (i += 1) {
        const arg = args.next() orelse break;

        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            const expr = args.next() orelse {
                try writeStderr("Error: missing expression after -e\n");
                std.process.exit(1);
            };
            try runExpression(allocator, expr, &env);
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

fn runExpression(allocator: Allocator, expr: []const u8, env: *Env) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var p = try parser.Parser.init(arena_alloc, expr);
    defer p.deinit();

    var form = Value.nilValue();
    errdefer form.deinit(arena_alloc);
    form = try p.parse();
    var result = try eval.eval(allocator, arena_alloc, form, env);
    defer result.deinit(arena_alloc);

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
        var result = try eval.eval(allocator, arena_alloc, form, env);

        // Print non-nil results (like Clojure REPL)
        if (!result.equals(Value.nilValue())) {
            const formatted = try result.fmt(allocator);
            defer allocator.free(formatted);
            try writeStdout(formatted);
            try writeStdout("\n");
        }

        result.deinit(arena_alloc);
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
