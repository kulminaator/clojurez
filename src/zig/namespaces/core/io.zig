// I/O built-in functions: print, println, read-line, spit, slurp, nano-time
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = Value.Env;
const sequences = @import("sequences.zig");



/// Fully realize a lazy-seq into a concrete list for printing.
fn fullyRealizeLazySeq(allocator: std.mem.Allocator, val: Value) anyerror!Value {
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

/// Format a value, forcing lazy-seqs first.
fn fmtValue(allocator: std.mem.Allocator, val: Value) anyerror![]const u8 {
    if (val.type == .lazy_seq) {
        var realized = try fullyRealizeLazySeq(allocator, val);
        defer realized.deinit(allocator);
        return try realized.fmt(allocator);
    }
    return try val.fmt(allocator);
}

pub fn core_print(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const stdout = std.Io.File.stdout();
    var buf: [256]u8 = undefined;
    var writer = stdout.writer(std.Options.debug_io, &buf);
    for (args.items) |arg| {
        const s = try fmtValue(env_env.allocator, arg);
        defer env_env.allocator.free(s);
        if (arg.type == .string and s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            try writer.interface.writeAll(s[1 .. s.len - 1]);
        } else {
            try writer.interface.writeAll(s);
        }
    }
    writer.flush() catch {};
    return Value.nilValue();
}

pub fn core_println(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const stdout = std.Io.File.stdout();
    var buf: [256]u8 = undefined;
    var writer = stdout.writer(std.Options.debug_io, &buf);
    for (args.items, 0..) |arg, i| {
        if (i > 0) try writer.interface.writeAll(" ");
        const s = try fmtValue(env_env.allocator, arg);
        defer env_env.allocator.free(s);
        if (arg.type == .string and s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            try writer.interface.writeAll(s[1 .. s.len - 1]);
        } else {
            try writer.interface.writeAll(s);
        }
    }
    try writer.interface.writeAll("\n");
    writer.flush() catch {};
    return Value.nilValue();
}

pub fn core_read_line(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = args;
    const stdin = std.Io.File.stdin();
    var buf: [1024]u8 = undefined;
    var reader = stdin.reader(std.Options.debug_io, &buf);
    var len: usize = 0;
    while (len < buf.len) {
        var slices = [_][]u8{buf[len..]};
        const bytes = reader.interface.readVec(&slices) catch break;
        if (bytes == 0) break;
        len += bytes;
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
    if (len == 0) return Value.nilValue();
    var end = len;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) {
        end -= 1;
    }
    return Value.stringValue(env_env.allocator, buf[0..end]);
}

pub fn core_slurp(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const filename = args.items[0];
    if (filename.type != .string) return error.TypeError;

    const cwd = std.Io.Dir.cwd();
    const file = std.Io.Dir.openFile(cwd, std.Options.debug_io, filename.str_val, .{}) catch {
        return error.FileError;
    };
    defer std.Io.File.close(file, std.Options.debug_io);

    var reader = file.reader(std.Options.debug_io, &[_]u8{});
    const content = try reader.interface.allocRemaining(env_env.allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    return Value.stringValue(env_env.allocator, content);
}

pub fn core_spit(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const filename = args.items[0];
    if (filename.type != .string) return error.TypeError;

    var content_buf: std.ArrayList(u8) = .empty;
    errdefer content_buf.deinit(env_env.allocator);

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (arg.type == .keyword) continue;
        const s = try arg.fmt(env_env.allocator);
        defer env_env.allocator.free(s);
        if (arg.type == .string and s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            try content_buf.appendSlice(env_env.allocator, s[1 .. s.len - 1]);
        } else {
            try content_buf.appendSlice(env_env.allocator, s);
        }
    }

    const cwd = std.Io.Dir.cwd();
    const file = try std.Io.Dir.createFile(cwd, std.Options.debug_io, filename.str_val, .{});
    defer std.Io.File.close(file, std.Options.debug_io);

    var writer = file.writer(std.Options.debug_io, &[_]u8{});
    try writer.interface.writeAll(content_buf.items);
    writer.flush() catch {};

    return Value.nilValue();
}

pub fn core_nano_time(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    _ = args;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return Value.intValue((ts.sec * 1_000_000_000) + ts.nsec);
}

pub fn registerIOFunctions(env: *Env) anyerror!void {
    try env.put("print", Value.builtinFnValue(core_print));
    try env.put("println", Value.builtinFnValue(core_println));
    try env.put("read-line", Value.builtinFnValue(core_read_line));
    try env.put("spit", Value.builtinFnValue(core_spit));
    try env.put("slurp", Value.builtinFnValue(core_slurp));
    try env.put("nano-time", Value.builtinFnValue(core_nano_time));
}

