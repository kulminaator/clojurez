const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const eval_ns = @import("eval_ns.zig");
const sequences = @import("namespaces/core/sequences.zig");
const gc_mod = @import("gc.zig");
const gc_scan = @import("gc_scan.zig");

const Allocator = std.mem.Allocator;

/// Fully realize a lazy-seq into a concrete list by repeatedly forcing one level.
/// This avoids the deep recursion problem of forceLazySeqHelper.
fn fullyRealizeLazySeq(allocator: Allocator, val: Value) anyerror!Value {
    if (std.meta.activeTag(val) != .lazy_seq) return try vm.clone(&val, allocator);

    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    var current: Value = val;
    var max_iter: usize = 100000;
    while (max_iter > 0) : (max_iter -= 1) {
        if (std.meta.activeTag(current) != .lazy_seq) break;

        // Force one level
        var forced = try sequences.forceLazySeqHelper(allocator, current);
        vm.valueDeinit(&current, allocator);

        if (std.meta.activeTag(forced) != .list) {
            vm.valueDeinit(&forced, allocator);
            break;
        }

        // Append elements from the forced list
        for (forced.list.items.items) |item| {
            if (std.meta.activeTag(item) == .lazy_seq) {
                // Recursively realize nested lazy-seqs
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

        // Check if there's a lazy-seq tail to continue
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

pub fn runRepl(allocator: Allocator, env: *vm.Env) anyerror!void {
    try writeStdout("Clojure VM in Zig\n");

    var input_buf: [4096]u8 = undefined;
    var leftover_buf: [4096]u8 = undefined;
    var leftover_len: usize = 0;

    // Multi-line buffer for incomplete expressions
    var multiline_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer multiline_buf.deinit(allocator);

    while (true) {
        // Print prompt (normal or continuation) - show current namespace
        if (multiline_buf.items.len == 0) {
            if (eval_ns.findNsManager(env)) |ns_mgr| {
                const current_ns = ns_mgr.getCurrentNamespace();
                try writeStdout(current_ns);
                try writeStdout("=> ");
            } else {
                try writeStdout("user=> ");
            }
        } else {
            try writeStdout("#_=> ");
        }

        const len = readLineWithLeftover(&input_buf, &leftover_buf, &leftover_len) catch |err| {
            // EOF - if we have accumulated input, try to evaluate it
            if (multiline_buf.items.len > 0) {
                const eval_env = getCurrentNsEnv(env) orelse env;
                _ = try evaluateAndPrint(allocator, multiline_buf.items, eval_env);
            }
            if (err == error.Eof) break;
            return err;
        };

        // Strip trailing whitespace
        var end = len;
        while (end > 0 and std.ascii.isWhitespace(input_buf[end - 1])) {
            end -= 1;
        }
        const trimmed = input_buf[0..end];

        if (trimmed.len == 0) continue;

        // Append to multiline buffer with newline
        try multiline_buf.appendSlice(allocator, trimmed);
        try multiline_buf.append(allocator, '\n');
        // Update GC root so the history buffer survives sweeps
        gc_mod.repl_history_buffer = multiline_buf.items;

        // Try to parse a complete form from the accumulated buffer
        const full_input = multiline_buf.items;
        const init_result = parser.Parser.init(allocator, full_input);
        if (init_result == error.UnexpectedEof or
            init_result == error.UnterminatedString) {
            // Incomplete expression or multiline string, wait for more input
            continue;
        }
        var p = init_result catch |err| {
            // Other parse error during init
            try writeStdout("Error: ");
            try writeStdout(@errorName(err));
            try writeStdout("\n");
            multiline_buf.clearRetainingCapacity();
            gc_mod.repl_history_buffer = multiline_buf.items;
            continue;
        };
        defer p.deinit();

        const parse_result = p.parse();
        if (parse_result == error.UnexpectedEof or
            parse_result == error.UnterminatedString) {
            // Incomplete expression or multiline string, wait for more input
            continue;
        } else {
            // We have a complete form - evaluate it (and any remaining forms)
            // Use current namespace's env for evaluation
            const eval_env = getCurrentNsEnv(env) orelse env;
            const should_exit = try evaluateAndPrint(allocator, full_input, eval_env);
            if (should_exit) break;

            // Collect garbage after each expression — temporary values from
            // evaluation (strings, lists, intermediate results) are no longer
            // reachable and should be swept.
            if (gc_mod.current_gc) |gc| gc.collect(gc_scan.valueScanFn);

            // Clear the multiline buffer for the next expression
            multiline_buf.clearRetainingCapacity();
            gc_mod.repl_history_buffer = multiline_buf.items;
        }
    }

    // Collect garbage — history buffer is a root so it survives.
    if (gc_mod.current_gc) |gc| gc.collect(gc_scan.valueScanFn);
}

/// Get the current namespace's env for evaluation.
fn getCurrentNsEnv(env: *vm.Env) ?*vm.Env {
    const ns_mgr = eval_ns.findNsManager(env) orelse return null;
    const current_ns = ns_mgr.getCurrentNamespace();
    return ns_mgr.getNamespace(current_ns);
}

/// Returns true if the REPL should exit (e.g., quit/exit called)
fn evaluateAndPrint(allocator: Allocator, input: []const u8, env: *vm.Env) anyerror!bool {
    var pos: usize = 0;
    while (pos < input.len) {
        var p = try parser.Parser.init(allocator, input[pos..]);

        const form_result = p.parse();
        const consumed = p.consumed();
        p.deinit();

        const parsed_form = form_result catch |err| {
            // Parser failed
            if (err == error.UnexpectedEof) {
                // No more complete forms (possibly trailing whitespace)
                break;
            }
            // Other parse error - print and advance to avoid infinite loop
            try writeStdout("Error: ");
            try writeStdout(@errorName(err));
            try writeStdout("\n");
            pos += if (consumed > 0) consumed else 1;
            continue;
        };

        // Parser succeeded - evaluate the form
        const form = parsed_form;
        const result_ptr = eval.eval(allocator, form, env) catch |err| {
            // GC handles form cleanup
            switch (err) {
                eval.EvalError.ReplExit => {
                    return true; // signal exit
                },
                else => {
                    try writeStdout("Error: ");
                    try writeStdout(@errorName(err));
                    try writeStdout("\n");
                    pos += consumed;
                    continue;
                },
            }
        };
        // Force lazy-seqs before printing so they show realized values
        var print_val: Value = undefined;
        if (std.meta.activeTag(result_ptr.*) == .lazy_seq) {
            print_val = try fullyRealizeLazySeq(allocator, result_ptr.*);
        } else {
            print_val = result_ptr.*;
        }
        const formatted = try vm.fmt(print_val, allocator);
        try writeStdout(formatted);
        try writeStdout("\n");
        // GC handles all cleanup — no manual deinit/free for GC-allocated values.

        pos += consumed;
    }

    return false;
}

fn readLineWithLeftover(buf: []u8, leftover_buf: []u8, leftover_len: *usize) anyerror!usize {
    var len: usize = 0;

    // First, check if there's leftover data from a previous read
    if (leftover_len.* > 0) {
        const lo = leftover_buf[0..leftover_len.*];
        // Find newline in leftover
        if (std.mem.indexOfScalar(u8, lo, '\n')) |nl_pos| {
            const line_len = nl_pos;
            @memcpy(buf[0..line_len], lo[0..line_len]);
            // Update leftover to skip past the newline
            const remaining = lo[nl_pos + 1..];
            const store_len = if (remaining.len < leftover_buf.len) remaining.len else leftover_buf.len;
            std.mem.copyForwards(u8, leftover_buf[0..store_len], remaining[0..store_len]);
            leftover_len.* = remaining.len;
            return line_len;
        }
        // No newline in leftover, need more data
        const copy_len = if (lo.len < buf.len) lo.len else buf.len;
        @memcpy(buf[0..copy_len], lo[0..copy_len]);
        len = copy_len;
        leftover_len.* = 0;
    }

    // Read more data from stdin using a streaming reader's readVec.
    // We use streaming mode directly to avoid the positional->streaming
    // mode switch that causes readVec to return 0 on pipes/TTYs.
    // We call readVec once per iteration (not in a loop like readSliceShort)
    // so we get available data without blocking for more.
    var hit_eof = false;
    var stdin_reader = std.Io.File.stdin().readerStreaming(std.Options.debug_io, &[_]u8{});
    while (len < buf.len) {
        var data: [1][]u8 = .{buf[len..]};
        const n = stdin_reader.interface.readVec(&data) catch |err| {
            if (err == error.EndOfStream) {
                hit_eof = true;
            }
            break;
        };
        if (n == 0) {
            // readVec can return 0 when switching modes. In streaming mode
            // this means EOF, but we need to distinguish from temporary 0.
            // If we have no data at all, it's EOF.
            if (len == 0) {
                hit_eof = true;
            }
            break;
        }
        len += n;
        // Find newline in the data we just read
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl_pos| {
            const line_len = nl_pos;
            // Store remaining data as leftover
            const remaining = buf[nl_pos + 1 .. len];
            const store_len = if (remaining.len < leftover_buf.len) remaining.len else leftover_buf.len;
            std.mem.copyForwards(u8, leftover_buf[0..store_len], remaining[0..store_len]);
            leftover_len.* = remaining.len;
            return line_len;
        }
    }
    leftover_len.* = 0;
    if (hit_eof and len == 0) return error.Eof;
    return len;
}

fn writeStdout(data: []const u8) anyerror!void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Options.debug_io, &buf);
    try writer.interface.writeAll(data);
    writer.flush() catch {};
}
