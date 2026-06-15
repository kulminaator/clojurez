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
    const val = map.get("CLJVM_DEBUG") orelse { map.deinit(); return; };

    // Duplicate val before deiniting the map — slices from splitScalar
    // would otherwise point into the map's freed memory.
    const val_copy = std.heap.page_allocator.dupe(u8, val) catch { map.deinit(); return; };
    map.deinit();

    if (std.mem.eql(u8, val_copy, "1") or std.mem.eql(u8, val_copy, "true") or std.mem.eql(u8, val_copy, "all")) {
        enabled = true;
        return;
    }
    if (val_copy.len == 0) {
        std.heap.page_allocator.free(val_copy);
        return;
    }

    enabled = true;
    // Parse comma-separated categories — dupe each one so the strings
    // survive independently of val_copy.
    var it = std.mem.splitScalar(u8, val_copy, ',');
    while (it.next()) |cat| {
        const trimmed = std.mem.trim(u8, cat, " \t");
        if (trimmed.len > 0) {
            const duped = std.heap.page_allocator.dupe(u8, trimmed) catch break;
            _ = categories.append(std.heap.page_allocator, duped) catch break;
        }
    }
    std.heap.page_allocator.free(val_copy);
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

/// Free all allocated category strings. Call at shutdown or between tests.
pub fn deinit() void {
    const a = std.heap.page_allocator;
    // Free each category string before freeing the backing array
    for (categories.items) |cat| {
        a.free(cat);
    }
    // Free the backing array; safe even when items is an empty slice
    if (categories.capacity > 0) {
        // deinit sets self.* = undefined, so reset to empty after
        categories.deinit(a);
        categories = .empty;
    }
    enabled = false;
}

/// Reset state for testing. Frees category strings and resets enabled flag.
pub fn reset() void {
    deinit();
}

/// Check if debug output is enabled (for testing).
pub fn isEnabled() bool {
    return enabled;
}

/// Get the list of active categories (for testing).
pub fn getCategories() []const []const u8 {
    return categories.items;
}

// ===== Unit Tests =====

/// Helper: manually set categories for testing (bypasses env var parsing).
fn setCategories(cats: []const []const u8) void {
    reset();
    enabled = true;
    for (cats) |cat| {
        _ = categories.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, cat) catch unreachable) catch unreachable;
    }
}

test "debug::disabled: isCategoryEnabled returns false" {
    reset();
    try std.testing.expect(!isEnabled());
    try std.testing.expect(!isCategoryEnabled("gc"));
    try std.testing.expect(!isCategoryEnabled("anything"));
}

test "debug::all mode: isCategoryEnabled matches everything" {
    reset();
    enabled = true;
    defer reset();
    try std.testing.expect(isEnabled());
    try std.testing.expect(getCategories().len == 0);
    try std.testing.expect(isCategoryEnabled("gc"));
    try std.testing.expect(isCategoryEnabled("eval"));
    try std.testing.expect(isCategoryEnabled("startup"));
    try std.testing.expect(isCategoryEnabled("anything"));
}

test "debug::category filter: matching categories return true" {
    setCategories(&.{"gc", "eval"});
    defer reset();
    try std.testing.expect(isCategoryEnabled("gc"));
    try std.testing.expect(isCategoryEnabled("eval"));
    try std.testing.expect(!isCategoryEnabled("startup"));
    try std.testing.expect(!isCategoryEnabled(""));
}

test "debug::category filter: non-matching categories return false" {
    setCategories(&.{"gc"});
    defer reset();
    try std.testing.expect(isCategoryEnabled("gc"));
    try std.testing.expect(!isCategoryEnabled("eval"));
    try std.testing.expect(!isCategoryEnabled("startup"));
}

test "debug::deinit: cleans up state" {
    setCategories(&.{"gc", "eval", "startup"});
    try std.testing.expect(isEnabled());
    try std.testing.expectEqual(@as(usize, 3), getCategories().len);
    reset();
    try std.testing.expect(!isEnabled());
    try std.testing.expect(getCategories().len == 0);
}

test "debug::categories: strings are independently allocated" {
    // Verify that category strings survive independently
    // (regression test for the dangling pointer bug where
    // categories stored slices into freed map memory)
    setCategories(&.{"gc", "eval", "seq"});
    defer reset();
    const cats = getCategories();
    try std.testing.expectEqual(@as(usize, 3), cats.len);
    // These reads would crash before the fix (use-after-free)
    try std.testing.expect(std.mem.eql(u8, cats[0], "gc"));
    try std.testing.expect(std.mem.eql(u8, cats[1], "eval"));
    try std.testing.expect(std.mem.eql(u8, cats[2], "seq"));
}

test "debug::categories: single category" {
    setCategories(&.{"gc"});
    defer reset();
    const cats = getCategories();
    try std.testing.expectEqual(@as(usize, 1), cats.len);
    try std.testing.expect(std.mem.eql(u8, cats[0], "gc"));
}

test "debug::categories: empty after reset" {
    setCategories(&.{"gc"});
    reset();
    try std.testing.expect(getCategories().len == 0);
    // Set again after reset
    setCategories(&.{"eval"});
    defer reset();
    try std.testing.expectEqual(@as(usize, 1), getCategories().len);
    try std.testing.expect(std.mem.eql(u8, getCategories()[0], "eval"));
}
