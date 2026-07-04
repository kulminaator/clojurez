// zig.io filesystem built-in functions
// File system operations: stat, list-dir, walk-dir, make-dir, delete, rename, copy, etc.
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

// ---- Helper: convert File.Kind to keyword string ----

fn kindToString(kind: File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        .named_pipe => "named_pipe",
        .block_device => "block_device",
        .character_device => "character_device",
        .unix_domain_socket => "unix_domain_socket",
        .whiteout => "whiteout",
        .door => "door",
        .event_port => "event_port",
        .unknown => "unknown",
    };
}

// ---- Helper: build a stat result map ----

fn buildStatMap(allocator: Allocator, path: []const u8, stat: File.Stat) anyerror!Value {
    var entries: std.ArrayListUnmanaged(vm.MapEntry) = .empty;
    errdefer {
        for (entries.items) |*e| {
            vm.valueDeinit(&e.key, allocator);
            vm.valueDeinit(&e.value, allocator);
        }
        allocator.free(entries.items);
    }

    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "path"),
        .value = try vm.stringValue(allocator, path),
    });
    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "size"),
        .value = vm.intValue(@as(i64, @intCast(stat.size))),
    });
    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "modified"),
        .value = vm.intValue(@as(i64, @intCast(stat.mtime.nanoseconds))),
    });
    try entries.append(allocator, .{
        .key = try vm.keywordValue(allocator, "kind"),
        .value = try vm.keywordValue(allocator, kindToString(stat.kind)),
    });

    return try vm.mapValue(allocator, entries);
}

// ---- Helper: open a directory for operations ----

fn openDirForPath(allocator: Allocator, path: []const u8) anyerror!struct { Dir, []const u8, []const u8 } {
    _ = allocator;
    const cwd = Dir.cwd();
    const io = std.Options.debug_io;

    // Split into parent dir and base name
    var slash: usize = 0;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            slash = i;
            break;
        }
    }

    const parent_path = if (slash > 0) path[0..slash] else if (path.len > 0 and path[0] == '/') "/" else ".";
    const base_name = if (slash > 0) path[slash + 1 ..] else path;

    var parent_dir: Dir = undefined;
    if (std.mem.eql(u8, parent_path, "/")) {
        parent_dir = try Dir.openDirAbsolute(io, "/", .{ .iterate = true });
    } else if (std.mem.eql(u8, parent_path, ".")) {
        parent_dir = cwd;
    } else {
        parent_dir = try Dir.openDir(cwd, io, parent_path, .{ .iterate = true });
    }

    return .{ parent_dir, parent_path, base_name };
}

// ---- file-stat: stat a file or directory ----

pub fn core_file_stat(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    const stat_result = Dir.statFile(cwd, io, path.string, .{}) catch return vm.nilValue();
    return try buildStatMap(env_env.allocator, path.string, stat_result);
}

// ---- file-exists?: check if a path exists ----

pub fn core_file_exists(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    const exists = Dir.statFile(cwd, io, path.string, .{}) catch return vm.boolValue(false);
    _ = exists;
    return vm.boolValue(true);
}

// ---- file-size: get file size in bytes ----

pub fn core_file_size(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    const stat_result = Dir.statFile(cwd, io, path.string, .{}) catch return vm.nilValue();
    return vm.intValue(@as(i64, @intCast(stat_result.size)));
}

// ---- is-directory?: check if path is a directory ----

pub fn core_is_directory(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    const stat_result = Dir.statFile(cwd, io, path.string, .{}) catch return vm.boolValue(false);
    return vm.boolValue(stat_result.kind == .directory);
}

// ---- is-file?: check if path is a regular file ----

pub fn core_is_file(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    const stat_result = Dir.statFile(cwd, io, path.string, .{}) catch return vm.boolValue(false);
    return vm.boolValue(stat_result.kind == .file);
}

// ---- is-symlink?: check if path is a symbolic link ----

pub fn core_is_symlink(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    const stat_result = Dir.statFile(cwd, io, path.string, .{ .follow_symlinks = false }) catch return vm.boolValue(false);
    return vm.boolValue(stat_result.kind == .sym_link);
}

// ---- list-dir: list directory contents ----

pub fn core_list_dir(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    var target_dir: Dir = undefined;

    if (std.mem.eql(u8, path.string, "/")) {
        target_dir = try Dir.openDirAbsolute(io, "/", .{ .iterate = true });
    } else if (std.mem.eql(u8, path.string, ".")) {
        target_dir = try Dir.openDir(cwd, io, ".", .{ .iterate = true });
    } else {
        target_dir = try Dir.openDir(cwd, io, path.string, .{ .iterate = true });
    }

    var it = Dir.iterate(target_dir);
    var vec_items: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (vec_items.items) |*v| vm.valueDeinit(v, env_env.allocator);
        env_env.allocator.free(vec_items.items);
    }

    while (try it.next(io)) |entry| {
        var entries: std.ArrayListUnmanaged(vm.MapEntry) = .empty;
        errdefer {
            for (entries.items) |*e| {
                vm.valueDeinit(&e.key, env_env.allocator);
                vm.valueDeinit(&e.value, env_env.allocator);
            }
            env_env.allocator.free(entries.items);
        }

        try entries.append(env_env.allocator, .{
            .key = try vm.keywordValue(env_env.allocator, "name"),
            .value = try vm.stringValue(env_env.allocator, entry.name),
        });
        try entries.append(env_env.allocator, .{
            .key = try vm.keywordValue(env_env.allocator, "kind"),
            .value = try vm.keywordValue(env_env.allocator, kindToString(entry.kind)),
        });

        try vec_items.append(env_env.allocator, try vm.mapValue(env_env.allocator, entries));
        entries = .empty;
    }

    return try vm.vectorValue(env_env.allocator, vec_items);
}

// ---- walk-dir: recursive directory walker (returns a list) ----

pub fn core_walk_dir(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    var start_dir: Dir = undefined;
    if (std.mem.eql(u8, path.string, "/")) {
        start_dir = try Dir.openDirAbsolute(io, "/", .{ .iterate = true });
    } else if (std.mem.eql(u8, path.string, ".")) {
        start_dir = try Dir.openDir(cwd, io, ".", .{ .iterate = true });
    } else {
        start_dir = try Dir.openDir(cwd, io, path.string, .{ .iterate = true });
    }
    var walker = Dir.walk(start_dir, env_env.allocator) catch return error.FileError;
    defer walker.deinit();

    var vec_items: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (vec_items.items) |*v| vm.valueDeinit(v, env_env.allocator);
        env_env.allocator.free(vec_items.items);
    }

    while (try walker.next(io)) |entry| {
        var entries: std.ArrayListUnmanaged(vm.MapEntry) = .empty;
        errdefer {
            for (entries.items) |*e| {
                vm.valueDeinit(&e.key, env_env.allocator);
                vm.valueDeinit(&e.value, env_env.allocator);
            }
            env_env.allocator.free(entries.items);
        }

        try entries.append(env_env.allocator, .{
            .key = try vm.keywordValue(env_env.allocator, "path"),
            .value = try vm.stringValue(env_env.allocator, entry.path),
        });
        try entries.append(env_env.allocator, .{
            .key = try vm.keywordValue(env_env.allocator, "name"),
            .value = try vm.stringValue(env_env.allocator, entry.basename),
        });
        try entries.append(env_env.allocator, .{
            .key = try vm.keywordValue(env_env.allocator, "kind"),
            .value = try vm.keywordValue(env_env.allocator, kindToString(entry.kind)),
        });

        try vec_items.append(env_env.allocator, try vm.mapValue(env_env.allocator, entries));
        entries = .empty;
    }

    return try vm.vectorValue(env_env.allocator, vec_items);
}

// ---- make-dir: create a single directory ----

pub fn core_make_dir(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const result = openDirForPath(env_env.allocator, path.string);
    if (result) |r| {
        const io = std.Options.debug_io;
        Dir.createDir(r[0], io, r[2], File.Permissions.default_dir) catch |err| {
            if (!std.mem.eql(u8, @errorName(err), "PathAlreadyExists")) return err;
        };
    } else |err| return err;

    return vm.nilValue();
}

// ---- make-parents: create all parent directories (mkdir -p) ----

pub fn core_make_parents(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    _ = Dir.createDirPathStatus(cwd, io, path.string, File.Permissions.default_dir) catch |err| {
        // PathAlreadyExists is acceptable
        if (!std.mem.eql(u8, @errorName(err), "PathAlreadyExists")) return err;
    };

    return vm.nilValue();
}

// ---- delete-file: delete a file ----

pub fn core_delete_file(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    Dir.deleteFile(cwd, io, path.string) catch |err| {
        if (!std.mem.eql(u8, @errorName(err), "AccessDenied") and
            !std.mem.eql(u8, @errorName(err), "NotFound"))
        {
            return err;
        }
    };

    return vm.nilValue();
}

// ---- delete-dir: delete an empty directory ----

pub fn core_delete_dir(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    Dir.deleteDir(cwd, io, path.string) catch |err| {
        if (!std.mem.eql(u8, @errorName(err), "DirectoryNotEmpty") and
            !std.mem.eql(u8, @errorName(err), "AccessDenied") and
            !std.mem.eql(u8, @errorName(err), "NotFound"))
        {
            return err;
        }
    };

    return vm.nilValue();
}

// ---- delete-tree: recursively delete a directory tree ----

pub fn core_delete_tree(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    Dir.deleteTree(cwd, io, path.string) catch |err| {
        if (!std.mem.eql(u8, @errorName(err), "AccessDenied") and
            !std.mem.eql(u8, @errorName(err), "NotFound"))
        {
            return err;
        }
    };

    return vm.nilValue();
}

// ---- rename-file: rename/move a file or directory ----

pub fn core_rename(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const src = args.items[0];
    const dst = args.items[1];
    if (std.meta.activeTag(src) != .string) return error.TypeError;
    if (std.meta.activeTag(dst) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    Dir.rename(cwd, src.string, cwd, dst.string, io) catch |err| {
        if (!std.mem.eql(u8, @errorName(err), "AccessDenied") and
            !std.mem.eql(u8, @errorName(err), "NotFound"))
        {
            return err;
        }
    };

    return vm.nilValue();
}

// ---- copy-file: copy a file ----

pub fn core_copy_file(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const src = args.items[0];
    const dst = args.items[1];
    if (std.meta.activeTag(src) != .string) return error.TypeError;
    if (std.meta.activeTag(dst) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    Dir.copyFile(cwd, src.string, cwd, dst.string, io, .{}) catch |err| {
        if (!std.mem.eql(u8, @errorName(err), "AccessDenied") and
            !std.mem.eql(u8, @errorName(err), "NotFound"))
        {
            return err;
        }
    };

    return vm.nilValue();
}

// ---- create-symlink: create a symbolic link ----

pub fn core_sym_link(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const target = args.items[0];
    const link_path = args.items[1];
    if (std.meta.activeTag(target) != .string) return error.TypeError;
    if (std.meta.activeTag(link_path) != .string) return error.TypeError;

    const result = openDirForPath(env_env.allocator, link_path.string);
    if (result) |r| {
        const io = std.Options.debug_io;
        Dir.symLink(r[0], io, target.string, r[2], .{}) catch |err| {
            if (!std.mem.eql(u8, @errorName(err), "PathAlreadyExists")) return err;
        };
    } else |err| return err;

    return vm.nilValue();
}

// ---- read-link: read symlink target ----

pub fn core_read_link(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    var buf: [1024]u8 = undefined;
    const len = Dir.readLink(cwd, io, path.string, &buf) catch return vm.nilValue();
    return try vm.stringValue(env_env.allocator, buf[0..len]);
}

// ---- file-modified-time: get mtime as nanoseconds ----

pub fn core_file_modified_time(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    const cwd = Dir.cwd();
    const io = std.Options.debug_io;
    const stat_result = Dir.statFile(cwd, io, path.string, .{}) catch return vm.nilValue();
    return vm.intValue(@as(i64, @intCast(stat_result.mtime.nanoseconds)));
}

// ---- file-parent: get parent directory of a path ----

pub fn core_file_parent(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    var i: usize = path.string.len;
    while (i > 0) {
        i -= 1;
        if (path.string[i] == '/') {
            if (i == 0) return try vm.stringValue(env_env.allocator, "/");
            return try vm.stringValue(env_env.allocator, path.string[0..i]);
        }
    }
    return try vm.stringValue(env_env.allocator, ".");
}

// ---- file-name: get the base name of a path ----

pub fn core_file_name(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    var i: usize = path.string.len;
    while (i > 0) {
        i -= 1;
        if (path.string[i] == '/') {
            if (i + 1 >= path.string.len) return vm.nilValue();
            return try vm.stringValue(env_env.allocator, path.string[i + 1 ..]);
        }
    }
    // No slash found — the whole string is the name
    return try vm.stringValue(env_env.allocator, path.string);
}

// ---- absolute-path: convert a relative path to absolute ----

pub fn core_absolute_path(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const path = args.items[0];
    if (std.meta.activeTag(path) != .string) return error.TypeError;

    // If already absolute, return as-is
    if (path.string.len > 0 and path.string[0] == '/') {
        return try vm.stringValue(env_env.allocator, path.string);
    }

    // Get current working directory using getcwd syscall
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    if (cwd_len == 0) {
        return try vm.stringValue(env_env.allocator, path.string);
    }
    const cwd_str = cwd_buf[0..cwd_len];
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer env_env.allocator.free(result.items);
    try result.appendSlice(env_env.allocator, cwd_str);
    try result.append(env_env.allocator, '/');
    try result.appendSlice(env_env.allocator, path.string);
    return try vm.stringValue(env_env.allocator, result.items);
}

// ---- copy: copy data between sources (delegates to copy-file for string args) ----

pub fn core_copy(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    if (args.items.len < 2) return error.ArityError;
    const input = args.items[0];
    const output = args.items[1];

    // For now, handle string-to-string (file-to-file) copy
    if (std.meta.activeTag(input) == .string and std.meta.activeTag(output) == .string) {
        // Build a 2-arg list for core_copy_file
        var copy_args: list.List = .empty;
        defer copy_args.deinit(env_env.allocator);
        try copy_args.append(env_env.allocator, try vm.clone(&input, env_env.allocator));
        try copy_args.append(env_env.allocator, try vm.clone(&output, env_env.allocator));
        return core_copy_file(self, &copy_args, env_env);
    }

    // For stream-to-stream copy, we'll implement in Phase 2
    // For now, return nil (no-op)
    return vm.nilValue();
}

// ---- sh-execute: execute a subprocess (stub for Phase 4) ----

pub fn core_sh_execute(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const cmd_seq = args.items[0];
    if (std.meta.activeTag(cmd_seq) != .list and std.meta.activeTag(cmd_seq) != .vector) return error.TypeError;

    var cmd: std.ArrayListUnmanaged([]const u8) = .empty;
    defer env_env.allocator.free(cmd.items);

    // Iterate over list or vector elements
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
    _ = opts_map; // opts parsed in Phase 4

    // std.process.spawn needs a real allocator on the Threaded instance.
    // global_single_threaded has .allocator = .failing by default.
    // We temporarily set it to page_allocator for the spawn call.
    const gts: *std.Io.Threaded = @constCast(std.Io.Threaded.global_single_threaded);
    const saved_allocator = gts.allocator;
    gts.allocator = std.heap.page_allocator;
    defer gts.allocator = saved_allocator;

    const io = gts.io();
    var child = try std.process.spawn(io, .{
        .argv = cmd.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.stdin = null;

    // Read stdout
    var stdout_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer env_env.allocator.free(stdout_buf.items);
    if (child.stdout) |out_file| {
        var reader = out_file.reader(io, &[_]u8{});
        const content = try reader.interface.allocRemaining(env_env.allocator, Io.Limit.limited(10 * 1024 * 1024));
        try stdout_buf.appendSlice(env_env.allocator, content);
    }

    // Read stderr
    var stderr_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer env_env.allocator.free(stderr_buf.items);
    if (child.stderr) |err_file| {
        var reader = err_file.reader(io, &[_]u8{});
        const content = try reader.interface.allocRemaining(env_env.allocator, Io.Limit.limited(10 * 1024 * 1024));
        try stderr_buf.appendSlice(env_env.allocator, content);
    }

    // Wait for exit
    const term = child.wait(io) catch std.process.Child.Term{ .unknown = 1 };
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => 1,
    };

    // Build result map
    var entries: std.ArrayListUnmanaged(vm.MapEntry) = .empty;
    errdefer {
        for (entries.items) |*e| {
            vm.valueDeinit(&e.key, env_env.allocator);
            vm.valueDeinit(&e.value, env_env.allocator);
        }
        env_env.allocator.free(entries.items);
    }

    try entries.append(env_env.allocator, .{
        .key = try vm.keywordValue(env_env.allocator, "exit"),
        .value = vm.intValue(@as(i64, @intCast(exit_code))),
    });
    try entries.append(env_env.allocator, .{
        .key = try vm.keywordValue(env_env.allocator, "out"),
        .value = try vm.stringValue(env_env.allocator, stdout_buf.items),
    });
    try entries.append(env_env.allocator, .{
        .key = try vm.keywordValue(env_env.allocator, "err"),
        .value = try vm.stringValue(env_env.allocator, stderr_buf.items),
    });

    return try vm.mapValue(env_env.allocator, entries);
}

// ---- Registration ----

pub fn registerFsFunctions(env: *Env) anyerror!void {
    try env.put("file-stat", vm.builtinFnValue(core_file_stat));
    try env.put("file-exists?", vm.builtinFnValue(core_file_exists));
    try env.put("file-size", vm.builtinFnValue(core_file_size));
    try env.put("is-directory?", vm.builtinFnValue(core_is_directory));
    try env.put("is-file?", vm.builtinFnValue(core_is_file));
    try env.put("is-symlink?", vm.builtinFnValue(core_is_symlink));
    try env.put("list-dir", vm.builtinFnValue(core_list_dir));
    try env.put("walk-dir", vm.builtinFnValue(core_walk_dir));
    try env.put("make-dir", vm.builtinFnValue(core_make_dir));
    try env.put("make-parents", vm.builtinFnValue(core_make_parents));
    try env.put("delete-file", vm.builtinFnValue(core_delete_file));
    try env.put("delete-dir", vm.builtinFnValue(core_delete_dir));
    try env.put("delete-tree", vm.builtinFnValue(core_delete_tree));
    try env.put("rename", vm.builtinFnValue(core_rename));
    try env.put("copy-file", vm.builtinFnValue(core_copy_file));
    try env.put("sym-link", vm.builtinFnValue(core_sym_link));
    try env.put("read-link", vm.builtinFnValue(core_read_link));
    try env.put("file-modified-time", vm.builtinFnValue(core_file_modified_time));
    try env.put("file-parent", vm.builtinFnValue(core_file_parent));
    try env.put("file-name", vm.builtinFnValue(core_file_name));
    try env.put("absolute-path", vm.builtinFnValue(core_absolute_path));
    try env.put("copy", vm.builtinFnValue(core_copy));
    try env.put("sh-execute", vm.builtinFnValue(core_sh_execute));
}
