// I/O built-in functions: print, println, read-line, spit, slurp, nano-time, load-file
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const vec = @import("../../vector.zig");
const Env = Value.Env;
const sequences = @import("sequences.zig");
const parser = @import("../../parser.zig");
const eval_mod = @import("../../eval.zig");

/// Global environment variable map, populated once at startup.
/// Valid for the lifetime of the process — no cleanup needed.
pub var env_vars: std.process.Environ.Map = undefined;

/// temp-dir: returns the OS temp directory as a string.
/// Checks TMPDIR (Unix), TEMP and TMP (Windows) environment variables.
/// Falls back to /tmp on Unix-like systems.
pub fn core_temp_dir(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = args;

    const builtin = @import("builtin");

    if (builtin.target.os.tag == .windows) {
        // Windows: check TEMP, then TMP
        if (env_vars.get("TEMP")) |temp| {
            return Value.stringValue(env_env.allocator, temp);
        }
        if (env_vars.get("TMP")) |tmp| {
            return Value.stringValue(env_env.allocator, tmp);
        }
        // Fallback for Windows
        return Value.stringValue(env_env.allocator, "C:\\Windows\\Temp");
    } else {
        // Unix-like: check TMPDIR, fall back to /tmp
        if (env_vars.get("TMPDIR")) |tmpdir| {
            return Value.stringValue(env_env.allocator, tmpdir);
        }
        return Value.stringValue(env_env.allocator, "/tmp");
    }
}

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
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Clock.awake.now(io);
    return Value.intValue(@as(i64, @intCast(ts.nanoseconds)));
}

/// read-string: parses a string into a single Clojure form (data structure).
/// Returns the parsed form (list, vector, map, symbol, etc.).
pub fn core_read_string(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const input = args.items[0];
    if (input.type != .string) return error.TypeError;

    var p = try parser.Parser.init(env_env.allocator, input.str_val);
    defer p.deinit();

    const form = try p.parse();
    return form;
}

/// load-file: reads a file, parses and evaluates all forms, returns last result.
pub fn core_load_file(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const filename = args.items[0];
    if (filename.type != .string) return error.TypeError;

    // Open and read the file
    const cwd = std.Io.Dir.cwd();
    var file = std.Io.Dir.openFile(cwd, std.Options.debug_io, filename.str_val, .{}) catch {
        return error.FileError;
    };
    defer std.Io.File.close(file, std.Options.debug_io);

    var reader = file.reader(std.Options.debug_io, &[_]u8{});
    const content = try reader.interface.allocRemaining(env_env.allocator, std.Io.Limit.limited(10 * 1024 * 1024));

    // Parse all forms
    var p = try parser.Parser.init(env_env.allocator, content);
    defer p.deinit();
    const forms = try p.parseAll();

    // Evaluate each form, keeping track of last result
    var last_result: Value = Value.nilValue();
    for (forms.items) |form| {
        var eval_env: *Env = env_env;
        if (eval_mod.findNsManager(env_env)) |ns_mgr| {
            const current_ns = ns_mgr.getCurrentNamespace();
            if (ns_mgr.getNamespace(current_ns)) |ns_env| {
                eval_env = ns_env;
            }
        }
        const result_ptr = try eval_mod.eval(env_env.allocator, form, eval_env);
        last_result.deinit(env_env.allocator);
        last_result = result_ptr.*;
    }

    return last_result;
}

/// eval: evaluates a single Clojure form (data structure) in the current environment.
pub fn core_eval(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const form = args.items[0];

    // Resolve current namespace's env (same as main.zig's runExpression)
    var eval_env: *Env = env_env;
    if (eval_mod.findNsManager(env_env)) |ns_mgr| {
        const current_ns = ns_mgr.getCurrentNamespace();
        if (ns_mgr.getNamespace(current_ns)) |ns_env| {
            eval_env = ns_env;
        }
    }

    const result_ptr = try eval_mod.eval(env_env.allocator, form, eval_env);
    return result_ptr.*;
}

pub fn registerIOFunctions(env: *Env) anyerror!void {
    try env.put("print", Value.builtinFnValue(core_print));
    try env.put("println", Value.builtinFnValue(core_println));
    try env.put("read-line", Value.builtinFnValue(core_read_line));
    try env.put("spit", Value.builtinFnValue(core_spit));
    try env.put("slurp", Value.builtinFnValue(core_slurp));
    try env.put("nano-time", Value.builtinFnValue(core_nano_time));
    try env.put("read-string", Value.builtinFnValue(core_read_string));
    try env.put("eval", Value.builtinFnValue(core_eval));
    try env.put("load-file", Value.builtinFnValue(core_load_file));
    try env.put("temp-dir", Value.builtinFnValue(core_temp_dir));
}

