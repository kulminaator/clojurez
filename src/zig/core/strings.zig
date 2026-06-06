// String built-in functions: str, utf8-valid?
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const Env = Value.Env;

pub fn core_str(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(env_env.allocator);

    for (args.items) |arg| {
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

pub fn registerStringFunctions(env: *Env) anyerror!void {
    try env.put("str", Value.builtinFnValue(core_str));
    try env.put("utf8-valid?", Value.builtinFnValue(core_utf8_valid_q));
}

// ===== Unit Tests =====

fn testEnv() Value.Env {
    return Value.Env.init(std.heap.page_allocator);
}

fn makeArgs(args: []const Value) list.List {
    var result: list.List = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        _ = result.append(std.heap.page_allocator, args[i]) catch unreachable;
    }
    return result;
}

var _testSelf: Value = Value.nilValue();
fn testSelf() *Value {
    return &_testSelf;
}

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

