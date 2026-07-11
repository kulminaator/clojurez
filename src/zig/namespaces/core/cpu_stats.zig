// CPU and system statistics: exposes zig.core/cpu-stats for runtime inspection.
const std = @import("std");
const builtin = @import("builtin");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;

const Allocator = std.mem.Allocator;

/// zig.core/cpu-stats — return a map of CPU and system information.
/// Takes no arguments. Returns a map with keys:
///   :core-count  — number of logical CPU cores
///   :arch        — CPU architecture string (e.g. "x86_64", "aarch64")
///   :os          — OS tag string (e.g. "linux", "macos", "windows")
///   :page-size   — system page size in bytes
///   :endian      — CPU endianness string ("little" or "big")
pub fn core_cpu_stats(self: *const Value, args: *const list.List, env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 0) return error.ArityError;

    const allocator = env.allocator;

    const core_count = std.Thread.getCpuCount() catch 1;
    const arch_name = @tagName(builtin.cpu.arch);
    const os_name = @tagName(builtin.os.tag);
    const page_size = std.heap.page_size_min;
    const endian_name = @tagName(builtin.cpu.arch.endian());

    var entries: std.ArrayListUnmanaged(vm.MapEntry) = .empty;
    errdefer {
        for (entries.items) |*e| {
            vm.valueDeinit(&e.key, allocator);
            vm.valueDeinit(&e.value, allocator);
        }
        entries.deinit(allocator);
    }

    // Integer fields
    const int_fields = [_]struct { key: []const u8, val: usize }{
        .{ .key = "core-count", .val = core_count },
        .{ .key = "page-size", .val = page_size },
    };
    for (int_fields) |f| {
        const key = try vm.keywordValue(allocator, f.key);
        const val = vm.intValue(@as(i64, @intCast(f.val)));
        try entries.append(allocator, .{ .key = key, .value = val });
    }

    // String fields
    const str_fields = [_][]const u8{ arch_name, os_name, endian_name };
    const str_keys = [_][]const u8{ "arch", "os", "endian" };
    var i: usize = 0;
    while (i < str_fields.len) : (i += 1) {
        const key = try vm.keywordValue(allocator, str_keys[i]);
        const val = try vm.stringValue(allocator, str_fields[i]);
        try entries.append(allocator, .{ .key = key, .value = val });
    }

    return try vm.mapValue(allocator, entries);
}

/// Register the cpu-stats builtin in the zig.core namespace.
pub fn registerCpuStats(env: *Env) anyerror!void {
    try env.put("cpu-stats", vm.builtinFnValue(core_cpu_stats));
}
