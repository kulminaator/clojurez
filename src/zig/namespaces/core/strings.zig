// String built-in functions: str, utf8-valid?
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const Env = Value.Env;
const helpers = @import("helpers.zig");
const test_utils = @import("test_utils.zig");

pub fn core_str(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(env_env.allocator);

    for (args.items) |arg| {
        // Handle character type: convert code point to UTF-8 string
        if (arg.type == .character) {
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(arg.char_val, &utf8_buf) catch return error.InvalidUnicode;
            try buf.appendSlice(env_env.allocator, utf8_buf[0..utf8_len]);
            continue;
        }
        const s = try arg.fmt(env_env.allocator);
        defer env_env.allocator.free(s);
        // Strip quotes from string values
        if (arg.type == .string and s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            try buf.appendSlice(env_env.allocator, s[1 .. s.len - 1]);
        } else {
            try buf.appendSlice(env_env.allocator, s);
        }
    }
    return Value.stringValue(env_env.allocator, try buf.toOwnedSlice(env_env.allocator));
}

pub fn core_utf8_valid_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    if (args.items[0].type != .string) return error.TypeError;
    return Value.boolValue(std.unicode.utf8ValidateSlice(args.items[0].str_val));
}

/// subs - returns the substring of s beginning at start inclusive, and ending
/// at end (defaults to length of string), exclusive.
/// Uses UTF-8 code point indices (consistent with nth on strings).
pub fn core_subs(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    if (args.items[0].type != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = args.items[0].str_val;
    const start = try helpers.toInt(args.items[1]);
    if (start < 0) return error.IndexOutOfBounds;

    const codepoint_count = Value.utf8CodepointCount(s);
    var end: i64 = @as(i64, @intCast(codepoint_count));
    if (args.items.len == 3) {
        end = try helpers.toInt(args.items[2]);
    }
    if (end < start) return error.IndexOutOfBounds;
    if (end > @as(i64, @intCast(codepoint_count))) end = @as(i64, @intCast(codepoint_count));

    // Find the byte offset for start code point
    var byte_start: usize = 0;
    var i: i64 = 0;
    while (i < start) : (i += 1) {
        const cp_bytes = Value.utf8CodepointAt(s, @as(usize, @intCast(i))) orelse break;
        byte_start += cp_bytes.len;
    }
    // Find the byte offset for end code point
    var byte_end: usize = byte_start;
    i = start;
    while (i < end) : (i += 1) {
        const cp_bytes = Value.utf8CodepointAt(s, @as(usize, @intCast(i))) orelse break;
        byte_end += cp_bytes.len;
    }

    return Value.stringValue(allocator, s[byte_start..byte_end]);
}

pub fn registerStringFunctions(env: *Env) anyerror!void {
    try env.put("str", Value.builtinFnValue(core_str));
    try env.put("utf8-valid?", Value.builtinFnValue(core_utf8_valid_q));
    try env.put("subs", Value.builtinFnValue(core_subs));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "strings::str: single string strips quotes" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try Value.stringValue(std.heap.page_allocator, "hello");
    defer s.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_str(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .string);
    try std.testing.expect(std.mem.eql(u8, result.str_val, "hello"));
}

test "strings::str: concatenates multiple values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s1 = try Value.stringValue(std.heap.page_allocator, "hello");
    defer s1.deinit(std.heap.page_allocator);
    var s2 = try Value.stringValue(std.heap.page_allocator, "world");
    defer s2.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s1, s2 });
    var result = core_str(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.str_val, "helloworld"));
}

test "strings::str: integer converted to string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_str(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.str_val, "42"));
}

test "strings::str: no args returns empty string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_str(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.str_val, ""));
}

test "strings::utf8_valid_q: valid string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try Value.stringValue(std.heap.page_allocator, "hello");
    defer s.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_utf8_valid_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "strings::utf8_valid_q: non-string returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1) });
    try std.testing.expectError(error.TypeError, core_utf8_valid_q(testSelf(), args, &a));
}

