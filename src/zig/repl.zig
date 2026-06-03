const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;

pub fn runRepl(allocator: Allocator, env: *Value.Env) anyerror!void {
    try writeStdout("Clojure VM in Zig\n");

    var input_buf: [4096]u8 = undefined;
    var leftover_buf: [4096]u8 = undefined;
    var leftover_len: usize = 0;

    // Multi-line buffer for incomplete expressions
    var multiline_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer multiline_buf.deinit(allocator);

    while (true) {
        // Print prompt (normal or continuation)
        if (multiline_buf.items.len == 0) {
            try writeStdout("user=> ");
        } else {
            try writeStdout("#_=> ");
        }

        const len = readLineWithLeftover(&input_buf, &leftover_buf, &leftover_len) catch |err| {
            // EOF - if we have accumulated input, try to evaluate it
            if (multiline_buf.items.len > 0) {
                _ = try evaluateAndPrint(allocator, multiline_buf.items, env);
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

        // Try to parse a complete form from the accumulated buffer
        const full_input = multiline_buf.items;
        var p = try parser.Parser.init(allocator, full_input);
        defer p.deinit();

        const parse_result = p.parse();
        if (parse_result == error.UnexpectedEof) {
            // Incomplete expression, wait for more input
            continue;
        } else {
            // We have a complete form - evaluate it (and any remaining forms)
            const should_exit = try evaluateAndPrint(allocator, full_input, env);
            if (should_exit) break;

            // Clear the multiline buffer for the next expression
            multiline_buf.clearRetainingCapacity();
        }
    }
}

/// Returns true if the REPL should exit (e.g., quit/exit called)
fn evaluateAndPrint(allocator: Allocator, input: []const u8, env: *Value.Env) anyerror!bool {
    var pos: usize = 0;
    while (pos < input.len) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        var p = try parser.Parser.init(arena_alloc, input[pos..]);

        const form_result = p.parse();
        const consumed = p.consumed();
        p.deinit();

        const parsed_form = form_result catch |err| {
            // Parser failed
            arena.deinit();
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
        var form = parsed_form;
        var result = eval.eval(allocator, arena_alloc, form, env) catch |err| {
            form.deinit(arena_alloc);
            switch (err) {
                eval.EvalError.ReplExit => {
                    arena.deinit();
                    return true; // signal exit
                },
                else => {
                    arena.deinit();
                    try writeStdout("Error: ");
                    try writeStdout(@errorName(err));
                    try writeStdout("\n");
                    pos += consumed;
                    continue;
                },
            }
        };
        const formatted = try result.fmt(allocator);
        try writeStdout(formatted);
        try writeStdout("\n");
        allocator.free(formatted);
        result.deinit(arena_alloc);
        form.deinit(arena_alloc);

        arena.deinit();
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

    // Read more data from stdin
    var hit_eof = false;
    while (len < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[len..]) catch break;
        if (n == 0) {
            hit_eof = true;
            break; // EOF
        }
        len += @as(usize, n);
        // Find the FIRST newline in the buffer
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl_pos| {
            const line_len = nl_pos;
            // Store remaining data (after the newline) as leftover
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
