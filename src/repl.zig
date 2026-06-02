const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;

pub fn runRepl(allocator: Allocator, env: *Value.Env) anyerror!void {
    try writeStdout("Clojure VM in Zig\n");
    try writeStdout("Type :quit or :exit to exit\n\n");

    var input_buf: [4096]u8 = undefined;

    while (true) {
        // Print prompt
        try writeStdout("user=> ");

        const len = readLine(&input_buf) catch break;
        if (len == 0) continue;

        // Strip trailing whitespace
        var end = len;
        while (end > 0 and std.ascii.isWhitespace(input_buf[end - 1])) {
            end -= 1;
        }
        const trimmed = input_buf[0..end];

        if (trimmed.len == 0) continue;

        // Check for exit commands
        if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":exit")) {
            break;
        }

        // Parse and evaluate
        const result = (blk: {
            var p = try parser.Parser.init(allocator, trimmed);
            defer p.deinit();
            const form = try p.parse();
            break :blk eval.eval(allocator, form, env);
        }) catch |err| {
            try writeStdout("Error: ");
            try writeStdout(@errorName(err));
            try writeStdout("\n");
            continue;
        };

        // Print result
        const formatted = try result.fmt(allocator);
        defer allocator.free(formatted);
        try writeStdout(formatted);
        try writeStdout("\n");

        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
}

fn readLine(buf: []u8) anyerror!usize {
    var reader = std.Io.File.stdin().reader(std.Options.debug_io, buf);
    var len: usize = 0;
    while (len < buf.len) {
        var slices = [_][]u8{buf[len..]};
        const bytes = reader.interface.readVec(&slices) catch break;
        if (bytes == 0) break;
        len += bytes;
        // Check if we got a newline
        var found_nl = false;
        var i: usize = 0;
        while (i < bytes) : (i += 1) {
            if (buf[len - bytes + i] == '\n') {
                len = len - bytes + i;
                found_nl = true;
                break;
            }
        }
        if (found_nl) break;
    }
    return len;
}

fn writeStdout(data: []const u8) anyerror!void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Options.debug_io, &buf);
    try writer.interface.writeAll(data);
    writer.flush() catch {};
}
