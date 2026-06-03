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
    const allocator = env.allocator;
    try env.put(allocator, "str", Value.builtinFnValue(core_str));
    try env.put(allocator, "utf8-valid?", Value.builtinFnValue(core_utf8_valid_q));
}

