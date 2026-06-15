// debug.zig — Conditional debug output controlled by CLJVM_DEBUG environment variable.
//
// Usage:
//   CLJVM_DEBUG=1 ./zig-out/bin/clojurez -e '(+ 1 2)'   // Enable all debug output
//   CLJVM_DEBUG=gc ./zig-out/bin/clojurez -e '(+ 1 2)'   // Enable only 'gc' category
//   CLJVM_DEBUG=gc,eval ./zig-out/bin/clojurez            // Enable 'gc' and 'eval' categories
//
// In code:
//   const debug = @import("debug.zig");
//   debug.log("gc", "collected {} bytes", .{bytes_collected});
//
// The environment variable is read once at startup with zero overhead when disabled.

const std = @import("std");

/// Whether debug output is enabled. Set once at startup.
var enabled: bool = false;
/// Comma-separated category filter (e.g. "gc,eval"). Empty means all categories.
var categories: std.ArrayListUnmanaged([]const u8) = .empty;

/// Initialize debug module from environment. Call once at startup.
pub fn init(environ: std.process.Environ) void {
    var map = std.process.Environ.createMap(environ, std.heap.page_allocator) catch return;
    defer map.deinit();
    const val = map.get("CLJVM_DEBUG") orelse return;

    if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "all")) {
        enabled = true;
        return;
    }
    if (val.len == 0) return;

    enabled = true;
    // Parse comma-separated categories
    var it = std.mem.splitScalar(u8, val, ',');
    while (it.next()) |cat| {
        const trimmed = std.mem.trim(u8, cat, " \t");
        if (trimmed.len > 0) {
            _ = categories.append(std.heap.page_allocator, trimmed) catch {};
        }
    }
}

/// Check if a category is enabled.
fn isCategoryEnabled(category: []const u8) bool {
    if (!enabled) return false;
    if (categories.items.len == 0) return true; // "all" mode
    for (categories.items) |cat| {
        if (std.mem.eql(u8, cat, category)) return true;
    }
    return false;
}

/// Print a debug message if the category is enabled.
/// Has zero overhead when the category is disabled (no format string evaluation).
pub fn log(category: []const u8, comptime format: []const u8, args: anytype) void {
    if (isCategoryEnabled(category)) {
        std.debug.print(format, args);
    }
}

/// Simple debug print (no category filtering).
pub fn dbg(comptime format: []const u8, args: anytype) void {
    if (enabled) {
        std.debug.print(format, args);
    }
}
