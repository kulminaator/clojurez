// zig.io subprocess async I/O built-in functions
// Process handles: spawn, read, write, wait, kill
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const gc_mod = @import("../../gc.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

// ============================================================
// Process handle — wraps a running subprocess with pipe access
// ============================================================

/// A GC-allocated handle wrapping a live subprocess.
/// The child struct is embedded directly — it contains only
/// File handles (OS file descriptors) and a PID, no GC pointers.
const ProcessHandle = struct {
    child: std.process.Child,
    allocator: Allocator,
    finished: bool = false,
    exit_code: ?i64 = null,

    /// Mark the process as finished and free resources.
    pub fn finish(self: *ProcessHandle) void {
        if (self.finished) return;
        self.finished = true;

        const io = std.Options.debug_io;

        // Close any remaining open pipes
        if (self.child.stdin) |s| {
            File.close(s, io);
            self.child.stdin = null;
        }
        if (self.child.stdout) |s| {
            File.close(s, io);
            self.child.stdout = null;
        }
        if (self.child.stderr) |s| {
            File.close(s, io);
            self.child.stderr = null;
        }

        self.allocator.destroy(self);
    }
};

// ============================================================
// Helper: parse opts map for a known key
// ============================================================

fn getOptString(opts: Value, key: []const u8) ?[]const u8 {
    if (std.meta.activeTag(opts) != .map) return null;
    for (opts.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword, key))
        {
            if (std.meta.activeTag(entry.value) == .string) {
                return entry.value.string;
            }
        }
    }
    return null;
}

fn getOptInt(opts: Value, key: []const u8) ?i64 {
    if (std.meta.activeTag(opts) != .map) return null;
    for (opts.map.entries.items) |entry| {
        if (std.meta.activeTag(entry.key) == .keyword and
            std.mem.eql(u8, entry.key.keyword, key))
        {
            if (std.meta.activeTag(entry.value) == .integer) {
                return entry.value.integer;
            }
        }
    }
    return null;
}

// ============================================================
// sh-execute-stream: spawn a subprocess with pipe handles
// ============================================================

pub fn core_sh_execute_stream(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const cmd_seq = args.items[0];
    if (std.meta.activeTag(cmd_seq) != .list and std.meta.activeTag(cmd_seq) != .vector) return error.TypeError;

    var cmd: std.ArrayListUnmanaged([]const u8) = .empty;
    defer env_env.allocator.free(cmd.items);

    const items = switch (cmd_seq) {
        .list => |data| data.items.items,
        .vector => |data| data.items.items,
        else => unreachable,
    };
    for (items) |arg| {
        if (std.meta.activeTag(arg) != .string) return error.TypeError;
        try cmd.append(env_env.allocator, try env_env.allocator.dupe(u8, arg.string));
    }

    const opts_map = if (args.items.len >= 2) args.items[1] else vm.nilValue();
    _ = opts_map; // :in, :dir, :env parsed in Phase 4.8+

    const gts: *Io.Threaded = @constCast(Io.Threaded.global_single_threaded);
    const saved_allocator = gts.allocator;
    gts.allocator = std.heap.page_allocator;
    defer gts.allocator = saved_allocator;

    const io = gts.io();
    const child = try std.process.spawn(io, .{
        .argv = cmd.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    const allocator = env_env.allocator;
    const handle = allocator.create(ProcessHandle) catch unreachable;
    handle.* = .{
        .child = child,
        .allocator = allocator,
    };

    if (gc_mod.current_gc) |gc| {
        gc.setObjectType(@as(*anyopaque, @ptrCast(handle)), gc_mod.GCObjectType.unknown);
    }

    return vm.wrapPtr(*ProcessHandle, handle);
}

// ============================================================
// sh-read-output: read from process stdout
// ============================================================

pub fn core_sh_read_output(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];
    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *ProcessHandle = vm.unwrapPtr(*ProcessHandle, handle_val);
    if (handle.finished) return error.ProcessFinished;

    const max_bytes: usize = if (args.items.len >= 2) blk: {
        const mb = args.items[1];
        if (std.meta.activeTag(mb) == .integer) break:blk @as(usize, @intCast(mb.integer));
        return error.TypeError;
    } else 4096;

    const io = std.Options.debug_io;
    const out_file = handle.child.stdout orelse return vm.nilValue();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer env_env.allocator.free(buf.items);

    var remaining: usize = max_bytes;
    while (remaining > 0) {
        const chunk_size = if (remaining < 4096) remaining else 4096;
        const chunk = try env_env.allocator.alloc(u8, chunk_size);
        errdefer env_env.allocator.free(chunk);

        var reader = out_file.reader(io, chunk);
        const bytes_read = reader.interface.readSliceShort(chunk) catch |err| {
            env_env.allocator.free(chunk);
            return err;
        };

        if (bytes_read == 0) {
            env_env.allocator.free(chunk);
            break;
        }

        try buf.appendSlice(env_env.allocator, chunk[0..bytes_read]);
        env_env.allocator.free(chunk);
        remaining -= bytes_read;
    }

    if (buf.items.len == 0) return vm.nilValue();
    return try vm.stringValue(env_env.allocator, buf.items);
}

// ============================================================
// sh-read-error: read from process stderr
// ============================================================

pub fn core_sh_read_error(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];
    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *ProcessHandle = vm.unwrapPtr(*ProcessHandle, handle_val);
    if (handle.finished) return error.ProcessFinished;

    const max_bytes: usize = if (args.items.len >= 2) blk: {
        const mb = args.items[1];
        if (std.meta.activeTag(mb) == .integer) break:blk @as(usize, @intCast(mb.integer));
        return error.TypeError;
    } else 4096;

    const io = std.Options.debug_io;
    const err_file = handle.child.stderr orelse return vm.nilValue();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer env_env.allocator.free(buf.items);

    var remaining: usize = max_bytes;
    while (remaining > 0) {
        const chunk_size = if (remaining < 4096) remaining else 4096;
        const chunk = try env_env.allocator.alloc(u8, chunk_size);
        errdefer env_env.allocator.free(chunk);

        var reader = err_file.reader(io, chunk);
        const bytes_read = reader.interface.readSliceShort(chunk) catch |err| {
            env_env.allocator.free(chunk);
            return err;
        };

        if (bytes_read == 0) {
            env_env.allocator.free(chunk);
            break;
        }

        try buf.appendSlice(env_env.allocator, chunk[0..bytes_read]);
        env_env.allocator.free(chunk);
        remaining -= bytes_read;
    }

    if (buf.items.len == 0) return vm.nilValue();
    return try vm.stringValue(env_env.allocator, buf.items);
}

// ============================================================
// sh-write-input: write to process stdin
// ============================================================

pub fn core_sh_write_input(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2) return error.ArityError;
    const handle_val = args.items[0];
    const data_val = args.items[1];

    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;
    if (std.meta.activeTag(data_val) != .string) return error.TypeError;

    const handle: *ProcessHandle = vm.unwrapPtr(*ProcessHandle, handle_val);
    if (handle.finished) return error.ProcessFinished;

    const io = std.Options.debug_io;
    const in_file = handle.child.stdin orelse return error.NoStdin;

    var writer = in_file.writer(io, &[_]u8{});
    try writer.interface.writeAll(data_val.string);
    try writer.flush();

    return vm.nilValue();
}

// ============================================================
// sh-wait: wait for process to finish
// ============================================================

pub fn core_sh_wait(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    _ = env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];
    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *ProcessHandle = vm.unwrapPtr(*ProcessHandle, handle_val);
    if (handle.finished) {
        return vm.intValue(handle.exit_code orelse -1);
    }

    const gts: *Io.Threaded = @constCast(Io.Threaded.global_single_threaded);
    const saved_allocator = gts.allocator;
    gts.allocator = std.heap.page_allocator;
    defer gts.allocator = saved_allocator;

    const io = gts.io();
    const term = handle.child.wait(io) catch std.process.Child.Term{ .unknown = 1 };

    const exit_code: i64 = switch (term) {
        .exited => |code| @as(i64, @intCast(code)),
        .signal => |sig| @as(i64, @intCast(@intFromEnum(sig))),
        .stopped => |sig| @as(i64, @intCast(@intFromEnum(sig))),
        .unknown => |code| @as(i64, @intCast(code)),
    };

    handle.exit_code = exit_code;
    handle.finish();

    return vm.intValue(exit_code);
}

// ============================================================
// sh-kill: kill a running process
// ============================================================

pub fn core_sh_kill(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];
    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *ProcessHandle = vm.unwrapPtr(*ProcessHandle, handle_val);
    if (handle.finished) return vm.nilValue();

    const gts: *Io.Threaded = @constCast(Io.Threaded.global_single_threaded);
    const saved_allocator = gts.allocator;
    gts.allocator = std.heap.page_allocator;
    defer gts.allocator = saved_allocator;

    const io = gts.io();
    std.process.Child.kill(&handle.child, io);

    handle.exit_code = -1;
    handle.finish();

    return vm.nilValue();
}

// ============================================================
// sh-close-input: close stdin pipe (signals EOF to subprocess)
// ============================================================

pub fn core_sh_close_input(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 1) return error.ArityError;
    const handle_val = args.items[0];
    if (std.meta.activeTag(handle_val) != .wrapped) return error.TypeError;

    const handle: *ProcessHandle = vm.unwrapPtr(*ProcessHandle, handle_val);
    if (handle.finished) return vm.nilValue();

    const io = std.Options.debug_io;
    if (handle.child.stdin) |s| {
        File.close(s, io);
        handle.child.stdin = null;
    }

    return vm.nilValue();
}

// ============================================================
// Registration
// ============================================================

pub fn registerShellFunctions(env: *Env) anyerror!void {
    try env.put("sh-execute-stream", vm.builtinFnValue(core_sh_execute_stream));
    try env.put("sh-read-output", vm.builtinFnValue(core_sh_read_output));
    try env.put("sh-read-error", vm.builtinFnValue(core_sh_read_error));
    try env.put("sh-write-input", vm.builtinFnValue(core_sh_write_input));
    try env.put("sh-close-input", vm.builtinFnValue(core_sh_close_input));
}
