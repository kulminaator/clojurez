// I/O built-in functions: print, println, read-line, spit, slurp, nano-time
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const Env = Value.Env;

const stdout_file = std.Io.File.stdout();
const stdin_file = std.Io.File.stdin();

pub fn core_print(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var buf: [256]u8 = undefined;
    var writer = stdout_file.writer(std.Options.debug_io, &buf);
    for (args.items) |arg| {
        const s = try arg.fmt(env_env.allocator);
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
    var buf: [256]u8 = undefined;
    var writer = stdout_file.writer(std.Options.debug_io, &buf);
    for (args.items, 0..) |arg, i| {
        if (i > 0) try writer.interface.writeAll(" ");
        const s = try arg.fmt(env_env.allocator);
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
    var buf: [1024]u8 = undefined;
    var reader = stdin_file.reader(std.Options.debug_io, &buf);
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
    const allocator = env.allocator;
    try env.put(allocator, "print", Value.builtinFnValue(core_print));
    try env.put(allocator, "println", Value.builtinFnValue(core_println));
    try env.put(allocator, "read-line", Value.builtinFnValue(core_read_line));
    try env.put(allocator, "spit", Value.builtinFnValue(core_spit));
    try env.put(allocator, "slurp", Value.builtinFnValue(core_slurp));
    try env.put(allocator, "nano-time", Value.builtinFnValue(core_nano_time));
}

