const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = Value.Env;

const Allocator = std.mem.Allocator;
const stdout_file = std.Io.File.stdout();
const stdin_file = std.Io.File.stdin();

// Arithmetic functions
pub fn core_plus(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    var sum: f64 = 0;
    for (args.items) |arg| {
        switch (arg.type) {
            .integer => sum += @as(f64, @floatFromInt(arg.int_val)),
            .float => sum += arg.float_val,
            else => return error.TypeError,
        }
    }
    if (isIntF64(sum)) {
        return Value.intValue(@as(i64, @intFromFloat(sum)));
    }
    return Value.floatValue(sum);
}

pub fn core_minus(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len == 0) return error.ArityError;
    var result: f64 = undefined;
    switch (args.items[0].type) {
        .integer => result = @as(f64, @floatFromInt(args.items[0].int_val)),
        .float => result = args.items[0].float_val,
        else => return error.TypeError,
    }
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        var sub: f64 = undefined;
        switch (args.items[i].type) {
            .integer => sub = @as(f64, @floatFromInt(args.items[i].int_val)),
            .float => sub = args.items[i].float_val,
            else => return error.TypeError,
        }
        result -= sub;
    }
    if (isIntF64(result)) {
        return Value.intValue(@as(i64, @intFromFloat(result)));
    }
    return Value.floatValue(result);
}

pub fn core_mult(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    var product: f64 = 1;
    for (args.items) |arg| {
        switch (arg.type) {
            .integer => product *= @as(f64, @floatFromInt(arg.int_val)),
            .float => product *= arg.float_val,
            else => return error.TypeError,
        }
    }
    if (isIntF64(product)) {
        return Value.intValue(@as(i64, @intFromFloat(product)));
    }
    return Value.floatValue(product);
}

pub fn core_div(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len == 0) return error.ArityError;
    var result: f64 = undefined;
    switch (args.items[0].type) {
        .integer => result = @as(f64, @floatFromInt(args.items[0].int_val)),
        .float => result = args.items[0].float_val,
        else => return error.TypeError,
    }
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        var divisor: f64 = undefined;
        switch (args.items[i].type) {
            .integer => divisor = @as(f64, @floatFromInt(args.items[i].int_val)),
            .float => divisor = args.items[i].float_val,
            else => return error.TypeError,
        }
        if (divisor == 0) return error.DivisionByZero;
        result /= divisor;
    }
    if (isIntF64(result)) {
        return Value.intValue(@as(i64, @intFromFloat(result)));
    }
    return Value.floatValue(result);
}

pub fn core_mod(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 2) return error.ArityError;
    const a = try toInt(args.items[0]);
    const b = try toInt(args.items[1]);
    if (b == 0) return error.DivisionByZero;
    return Value.intValue(@rem(a, b));
}

// Comparison functions
pub fn core_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (!args.items[0].equals(args.items[i])) {
            return Value.boolValue(false);
        }
    }
    return Value.boolValue(true);
}

pub fn core_not_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (args.items[0].equals(args.items[i])) {
            return Value.boolValue(false);
        }
    }
    return Value.boolValue(true);
}

pub fn core_less(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a >= b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_greater(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a <= b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_less_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a > b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_greater_eq(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len < 2) return error.ArityError;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = toNum(args.items[i - 1]);
        const b = toNum(args.items[i]);
        if (a < b) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

// Boolean functions
pub fn core_not(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(!args.items[0].isTruthy());
}

// Type checking
pub fn core_nil_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .nil);
}

pub fn core_number_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .integer or args.items[0].type == .float);
}

pub fn core_string_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .string);
}

pub fn core_list_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .list);
}

pub fn core_symbol_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .symbol);
}

pub fn core_keyword_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .keyword);
}

pub fn core_true_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .bool and args.items[0].bool_val);
}

pub fn core_false_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .bool and !args.items[0].bool_val);
}

// String functions
pub fn core_str(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
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

// UTF-8 validation
pub fn core_utf8_valid_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    if (args.items[0].type != .string) return error.TypeError;
    return Value.boolValue(std.unicode.utf8ValidateSlice(args.items[0].str_val));
}

pub fn core_count
(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    switch (args.items[0].type) {
        .list => return Value.intValue(@as(i64, @intCast(args.items[0].list_val.items.len))),
        .vector => return Value.intValue(@as(i64, @intCast(args.items[0].vec_val.items.len))),
        .map => return Value.intValue(@as(i64, @intCast(args.items[0].map_val.items.len))),
        .set => return Value.intValue(@as(i64, @intCast(args.items[0].set_val.items.len))),
        .queue => return Value.intValue(@as(i64, @intCast(args.items[0].queue_val.items.len))),
        .string => return Value.intValue(@as(i64, @intCast(Value.utf8CodepointCount(args.items[0].str_val)))),
        else => return error.TypeError,
    }
}

// List/sequence functions
pub fn core_first(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    switch (args.items[0].type) {
        .list => {
            if (args.items[0].list_val.items.len == 0) return Value.nilValue();
            return try args.items[0].list_val.items[0].clone(env_env.allocator);
        },
        .vector => {
            if (args.items[0].vec_val.items.len == 0) return Value.nilValue();
            return try args.items[0].vec_val.items[0].clone(env_env.allocator);
        },
        else => return Value.nilValue(),
    }
}

pub fn core_rest(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    switch (args.items[0].type) {
        .list => {
            if (args.items[0].list_val.items.len <= 1) return Value.listValue(list.empty());
            const rest = args.items[0].list_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            for (rest) |item| {
                try new_list.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        .vector => {
            if (args.items[0].vec_val.items.len <= 1) return Value.listValue(list.empty());
            const rest = args.items[0].vec_val.items[1..];
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            for (rest) |item| {
                try new_list.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        else => return Value.listValue(list.empty()),
    }
}

pub fn core_nth(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len < 2) return error.ArityError;
    const idx = try toInt(args.items[1]);
    switch (args.items[0].type) {
        .list => {
            if (idx < 0 or @as(usize, @intCast(idx)) >= args.items[0].list_val.items.len) return Value.nilValue();
            return try args.items[0].list_val.items[@as(usize, @intCast(idx))].clone(env_env.allocator);
        },
        .vector => {
            if (idx < 0 or @as(usize, @intCast(idx)) >= args.items[0].vec_val.items.len) return Value.nilValue();
            return try args.items[0].vec_val.items[@as(usize, @intCast(idx))].clone(env_env.allocator);
        },
        .string => {
            const s = args.items[0].str_val;
            const codepoint_count = Value.utf8CodepointCount(s);
            if (idx < 0 or @as(usize, @intCast(idx)) >= codepoint_count) return Value.nilValue();
            const cp = Value.utf8CodepointAt(s, @as(usize, @intCast(idx))) orelse return Value.nilValue();
            return Value.stringValue(env_env.allocator, cp);
        },
        else => return error.TypeError,
    }
}

pub fn core_concat(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);

    for (args.items) |arg| {
        switch (arg.type) {
            .list => {
                for (arg.list_val.items) |item| {
                    try result.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            .vector => {
                for (arg.vec_val.items) |item| {
                    try result.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            else => try result.append(env_env.allocator, try arg.clone(env_env.allocator)),
        }
    }
    return Value.listValue(result);
}

pub fn core_list(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    var new_list: list.List = .empty;
    errdefer new_list.deinit(env_env.allocator);
    for (args.items) |arg| {
        try new_list.append(env_env.allocator, try arg.clone(env_env.allocator));
    }
    return Value.listValue(new_list);
}

pub fn core_vec(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    var new_vec: vec.Vector = .empty;
    errdefer new_vec.deinit(env_env.allocator);
    for (args.items) |arg| {
        switch (arg.type) {
            .list => {
                for (arg.list_val.items) |item| {
                    try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            .vector => {
                for (arg.vec_val.items) |item| {
                    try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            },
            else => try new_vec.append(env_env.allocator, try arg.clone(env_env.allocator)),
        }
    }
    return Value.vectorValue(new_vec);
}

// I/O functions
pub fn core_print(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    var buf: [256]u8 = undefined;
    var writer = stdout_file.writer(std.Options.debug_io, &buf);
    for (args.items) |arg| {
        const s = try arg.fmt(env_env.allocator);
        defer env_env.allocator.free(s);
        // Print string values without quotes
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
    _ = args;
    var buf: [1024]u8 = undefined;
    var reader = stdin_file.reader(std.Options.debug_io, &buf);
    // Read until newline or EOF
    var len: usize = 0;
    while (len < buf.len) {
        var slices = [_][]u8{buf[len..]};
        const bytes = reader.interface.readVec(&slices) catch break;
        if (bytes == 0) break;
        len += bytes;
        // Check if we got a newline
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
    // Strip trailing newline/CR
    var end = len;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) {
        end -= 1;
    }
    return Value.stringValue(env_env.allocator, buf[0..end]);
}

// slurp - read entire file contents as a string
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

// spit - write content to a file
pub fn core_spit(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const filename = args.items[0];
    if (filename.type != .string) return error.TypeError;

    // Build the content string from all remaining args
    var content_buf: std.ArrayList(u8) = .empty;
    errdefer content_buf.deinit(env_env.allocator);

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        // Skip option keywords like :append
        if (arg.type == .keyword) continue;
        const s = try arg.fmt(env_env.allocator);
        defer env_env.allocator.free(s);
        // Strip quotes from string values
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

// Map functions
pub fn core_get(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;
    if (args.items.len == 1) return Value.nilValue();
    const key = args.items[1];
    for (map_val.map_val.items) |entry| {
        if (entry.key.equals(key)) {
            return try entry.value.clone(env_env.allocator);
        }
    }
    return Value.nilValue();
}

pub fn core_assoc(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;

    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(env_env.allocator);
            entry.value.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_map.items);
    }

    // Copy existing entries
    for (map_val.map_val.items) |entry| {
        try new_map.append(env_env.allocator, .{
            .key = try entry.key.clone(env_env.allocator),
            .value = try entry.value.clone(env_env.allocator),
        });
    }

    // Apply key-value pairs
    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const key = args.items[i];
        const value = args.items[i + 1];
        // Update existing key or append new
        var found = false;
        var j: usize = 0;
        while (j < new_map.items.len) : (j += 1) {
            if (new_map.items[j].key.equals(key)) {
                new_map.items[j].value.deinit(env_env.allocator);
                new_map.items[j].value = try value.clone(env_env.allocator);
                found = true;
                break;
            }
        }
        if (!found) {
            try new_map.append(env_env.allocator, .{
                .key = try key.clone(env_env.allocator),
                .value = try value.clone(env_env.allocator),
            });
        }
    }

    return Value.mapValue(new_map);
}

// Collection functions
pub fn core_conj(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            for (coll.vec_val.items) |item| {
                try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            for (args.items[1..]) |item| {
                try new_vec.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.vectorValue(new_vec);
        },
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            // For lists, conj prepends (like Clojure)
            var i: usize = args.items.len - 1;
            while (true) {
                try new_list.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
                if (i == 1) break;
                i -= 1;
            }
            for (coll.list_val.items) |item| {
                try new_list.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        .set => {
            var new_set: Value.Set = .empty;
            errdefer {
                for (new_set.items) |*item| {
                    item.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_set.items);
            }
            // Copy existing items
            for (coll.set_val.items) |item| {
                try new_set.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            // Add new items (skip duplicates)
            for (args.items[1..]) |item| {
                var found = false;
                for (new_set.items) |existing| {
                    if (existing.equals(item)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try new_set.append(env_env.allocator, try item.clone(env_env.allocator));
                }
            }
            return Value.setValue(new_set);
        },
        .queue => {
            var new_queue: Value.Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    item.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_queue.items);
            }
            // Copy existing items
            for (coll.queue_val.items) |item| {
                try new_queue.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            // Add new items to the back
            for (args.items[1..]) |item| {
                try new_queue.append(env_env.allocator, try item.clone(env_env.allocator));
            }
            return Value.queueValue(new_queue);
        },
        .map => {
            // conj on a map accepts a map entry (a 2-element vector/list)
            var new_map: Value.Map = .empty;
            errdefer {
                for (new_map.items) |*entry| {
                    entry.key.deinit(env_env.allocator);
                    entry.value.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_map.items);
            }
            // Copy existing entries
            for (coll.map_val.items) |entry| {
                try new_map.append(env_env.allocator, .{
                    .key = try entry.key.clone(env_env.allocator),
                    .value = try entry.value.clone(env_env.allocator),
                });
            }
            // Add new entries
            for (args.items[1..]) |item| {
                var entry_items: []const Value = undefined;
                switch (item.type) {
                    .vector => entry_items = item.vec_val.items,
                    .list => entry_items = item.list_val.items,
                    else => { new_map.deinit(env_env.allocator); return error.TypeError; },
                }
                if (entry_items.len != 2) { new_map.deinit(env_env.allocator); return error.ArityError; }
                // Update or add
                var found = false;
                var j: usize = 0;
                while (j < new_map.items.len) : (j += 1) {
                    if (new_map.items[j].key.equals(entry_items[0])) {
                        new_map.items[j].value.deinit(env_env.allocator);
                        new_map.items[j].value = try entry_items[1].clone(env_env.allocator);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try new_map.append(env_env.allocator, .{
                        .key = try entry_items[0].clone(env_env.allocator),
                        .value = try entry_items[1].clone(env_env.allocator),
                    });
                }
            }
            return Value.mapValue(new_map);
        },
        else => return error.TypeError,
    }
}

pub fn core_pop(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .vector => {
            if (coll.vec_val.items.len == 0) return Value.vectorValue(.empty);
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            const len = coll.vec_val.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_vec.append(env_env.allocator, try coll.vec_val.items[i].clone(env_env.allocator));
            }
            return Value.vectorValue(new_vec);
        },
        .list => {
            if (coll.list_val.items.len == 0) return Value.listValue(.empty);
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            const len = coll.list_val.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_list.append(env_env.allocator, try coll.list_val.items[i].clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        .queue => {
            if (coll.queue_val.items.len == 0) return Value.queueValue(.empty);
            var new_queue: Value.Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    item.deinit(env_env.allocator);
                }
                env_env.allocator.free(new_queue.items);
            }
            // Pop removes from the front
            var i: usize = 1;
            while (i < coll.queue_val.items.len) : (i += 1) {
                try new_queue.append(env_env.allocator, try coll.queue_val.items[i].clone(env_env.allocator));
            }
            return Value.queueValue(new_queue);
        },
        else => return error.TypeError,
    }
}

pub fn core_last(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .vector => {
            if (coll.vec_val.items.len == 0) return Value.nilValue();
            return try coll.vec_val.items[coll.vec_val.items.len - 1].clone(env_env.allocator);
        },
        .list => {
            if (coll.list_val.items.len == 0) return Value.nilValue();
            return try coll.list_val.items[coll.list_val.items.len - 1].clone(env_env.allocator);
        },
        else => return error.TypeError,
    }
}

pub fn core_reverse(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(env_env.allocator);
            var i: usize = coll.vec_val.items.len;
            while (i > 0) {
                i -= 1;
                try new_vec.append(env_env.allocator, try coll.vec_val.items[i].clone(env_env.allocator));
            }
            return Value.vectorValue(new_vec);
        },
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(env_env.allocator);
            var i: usize = coll.list_val.items.len;
            while (i > 0) {
                i -= 1;
                try new_list.append(env_env.allocator, try coll.list_val.items[i].clone(env_env.allocator));
            }
            return Value.listValue(new_list);
        },
        else => return error.TypeError,
    }
}

pub fn core_range(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1 or args.items.len > 2) return error.ArityError;
    const end = try toInt(args.items[args.items.len - 1]);
    const start: i64 = if (args.items.len == 2) try toInt(args.items[0]) else 0;

    var new_list: list.List = .empty;
    errdefer new_list.deinit(env_env.allocator);

    var i: i64 = start;
    while (i < end) : (i += 1) {
        try new_list.append(env_env.allocator, Value.intValue(i));
    }
    return Value.listValue(new_list);
}

// Set functions
pub fn core_set(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    if (coll.type == .set) return try coll.clone(env_env.allocator);

    var new_set: Value.Set = .empty;
    errdefer {
        for (new_set.items) |*item| {
            item.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_set.items);
    }

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var found = false;
        for (new_set.items) |existing| {
            if (existing.equals(item)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try new_set.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.setValue(new_set);
}

pub fn core_set_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .set);
}

pub fn core_disj(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const set_val = args.items[0];
    if (set_val.type != .set) return error.TypeError;

    var new_set: Value.Set = .empty;
    errdefer {
        for (new_set.items) |*item| {
            item.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_set.items);
    }

    for (set_val.set_val.items) |item| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (item.equals(args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_set.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.setValue(new_set);
}

// Map functions
pub fn core_keys(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    for (map_val.map_val.items) |entry| {
        try result.append(env_env.allocator, try entry.key.clone(env_env.allocator));
    }
    return Value.listValue(result);
}

pub fn core_vals(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    for (map_val.map_val.items) |entry| {
        try result.append(env_env.allocator, try entry.value.clone(env_env.allocator));
    }
    return Value.listValue(result);
}

pub fn core_dissoc(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const map_val = args.items[0];
    if (map_val.type != .map) return error.TypeError;

    var new_map: Value.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            entry.key.deinit(env_env.allocator);
            entry.value.deinit(env_env.allocator);
        }
        env_env.allocator.free(new_map.items);
    }

    for (map_val.map_val.items) |entry| {
        var should_keep = true;
        var i: usize = 1;
        while (i < args.items.len) : (i += 1) {
            if (entry.key.equals(args.items[i])) {
                should_keep = false;
                break;
            }
        }
        if (should_keep) {
            try new_map.append(env_env.allocator, .{
                .key = try entry.key.clone(env_env.allocator),
                .value = try entry.value.clone(env_env.allocator),
            });
        }
    }
    return Value.mapValue(new_map);
}

pub fn core_merge(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len == 0) return Value.mapValue(.empty);

    var result: Value.Map = .empty;
    errdefer {
        for (result.items) |*entry| {
            entry.key.deinit(env_env.allocator);
            entry.value.deinit(env_env.allocator);
        }
        env_env.allocator.free(result.items);
    }

    for (args.items) |arg| {
        if (arg.type != .map) continue;
        for (arg.map_val.items) |entry| {
            // Check if key already exists
            var found = false;
            var j: usize = 0;
            while (j < result.items.len) : (j += 1) {
                if (result.items[j].key.equals(entry.key)) {
                    result.items[j].value.deinit(env_env.allocator);
                    result.items[j].value = try entry.value.clone(env_env.allocator);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try result.append(env_env.allocator, .{
                    .key = try entry.key.clone(env_env.allocator),
                    .value = try entry.value.clone(env_env.allocator),
                });
            }
        }
    }
    return Value.mapValue(result);
}

pub fn core_contains_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const coll = args.items[0];
    const key = args.items[1];

    switch (coll.type) {
        .map => {
            for (coll.map_val.items) |entry| {
                if (entry.key.equals(key)) return Value.boolValue(true);
            }
            return Value.boolValue(false);
        },
        .set => {
            for (coll.set_val.items) |item| {
                if (item.equals(key)) return Value.boolValue(true);
            }
            return Value.boolValue(false);
        },
        .vector, .list => {
            // For vectors/lists, contains? checks index range
            if (key.type != .integer) return Value.boolValue(false);
            const idx = key.int_val;
            if (idx < 0) return Value.boolValue(false);
            const len: usize = switch (coll.type) {
                .vector => coll.vec_val.items.len,
                .list => coll.list_val.items.len,
                else => unreachable,
            };
            return Value.boolValue(@as(usize, @intCast(idx)) < len);
        },
        else => return error.TypeError,
    }
}

pub fn core_empty_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (coll.type) {
        .list => coll.list_val.items.len,
        .vector => coll.vec_val.items.len,
        .map => coll.map_val.items.len,
        .set => coll.set_val.items.len,
        .queue => coll.queue_val.items.len,
        .string => coll.str_val.len,
        else => return error.TypeError,
    };
    return Value.boolValue(len == 0);
}

pub fn core_not_empty(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (coll.type) {
        .list => coll.list_val.items.len,
        .vector => coll.vec_val.items.len,
        .map => coll.map_val.items.len,
        .set => coll.set_val.items.len,
        .queue => coll.queue_val.items.len,
        else => return Value.nilValue(),
    };
    if (len == 0) return Value.nilValue();
    return try coll.clone(env_env.allocator);
}

pub fn core_seq(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    const len: usize = switch (coll.type) {
        .list => coll.list_val.items.len,
        .vector => coll.vec_val.items.len,
        .map => coll.map_val.items.len,
        .set => coll.set_val.items.len,
        .queue => coll.queue_val.items.len,
        else => return Value.nilValue(),
    };
    if (len == 0) return Value.nilValue();
    return try coll.clone(env_env.allocator);
}

pub fn core_coll_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    return Value.boolValue(switch (coll.type) {
        .list, .vector, .map, .set, .queue => true,
        else => false,
    });
}

pub fn core_sequential_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    return Value.boolValue(coll.type == .list or coll.type == .vector);
}

pub fn core_reduce(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;

    const f = args.items[0];
    var coll: Value = undefined;
    var init_val: ?Value = null;

    if (args.items.len == 3) {
        coll = args.items[2];
        init_val = args.items[1];
    } else {
        coll = args.items[1];
    }

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        .set => items = coll.set_val.items,
        .queue => items = coll.queue_val.items,
        else => return error.TypeError,
    }

    if (items.len == 0) {
        if (init_val) |iv| return try iv.clone(env_env.allocator);
        return Value.nilValue();
    }

    var acc: Value = undefined;
    if (init_val) |iv| {
        acc = try iv.clone(env_env.allocator);
    } else if (items.len == 1) {
        return try items[0].clone(env_env.allocator);
    } else {
        acc = try items[0].clone(env_env.allocator);
    }

    var start: usize = 0;
    if (init_val == null and items.len > 1) start = 1;

    var i = start;
    while (i < items.len) : (i += 1) {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try acc.clone(env_env.allocator));
        try arg_list.append(env_env.allocator, try items[i].clone(env_env.allocator));

        const new_acc = try callBuiltin(env_env.allocator, f, arg_list, env_env);
        acc.deinit(env_env.allocator);
        acc = new_acc;
    }
    return acc;
}

pub fn core_flatten(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return doFlatten(env_env.allocator, args.items[0], env_env);
}

fn doFlatten(allocator: Allocator, val: Value, env: *Env) anyerror!Value {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);

    switch (val.type) {
        .list => {
            for (val.list_val.items) |item| {
                var flattened = try doFlatten(allocator, item, env);
                if (flattened.type == .list) {
                    for (flattened.list_val.items) |elem| {
                        try result.append(allocator, try elem.clone(allocator));
                    }
                    flattened.deinit(allocator);
                } else {
                    try result.append(allocator, flattened);
                }
            }
        },
        .vector => {
            for (val.vec_val.items) |item| {
                var flattened = try doFlatten(allocator, item, env);
                if (flattened.type == .list) {
                    for (flattened.list_val.items) |elem| {
                        try result.append(allocator, try elem.clone(allocator));
                    }
                    flattened.deinit(allocator);
                } else {
                    try result.append(allocator, flattened);
                }
            }
        },
        else => {
            try result.append(allocator, try val.clone(allocator));
        },
    }
    return Value.listValue(result);
}

pub fn core_next(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    var rest = try core_rest(self, args, env_env);
    if (rest.type == .list and rest.list_val.items.len == 0) {
        rest.deinit(env_env.allocator);
        return Value.nilValue();
    }
    return rest;
}

pub fn core_nthnext(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    if (args.items.len != 2) return error.ArityError;
    const n = try toInt(args.items[0]);
    if (n <= 0) return try core_seq(self, args, env_env);

    const coll = args.items[1];
    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    if (@as(usize, @intCast(n)) >= items.len) return Value.nilValue();

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);
    var i: usize = @as(usize, @intCast(n));
    while (i < items.len) : (i += 1) {
        try result.append(env_env.allocator, try items[i].clone(env_env.allocator));
    }
    return Value.listValue(result);
}

pub fn core_filter(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var pred_result = try callBuiltin(env_env.allocator, f, arg_list, env_env);
        defer pred_result.deinit(env_env.allocator);
        if (pred_result.isTruthy()) {
            try result.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.listValue(result);
}

pub fn core_remove(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    var result: list.List = .empty;
    errdefer result.deinit(env_env.allocator);

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var pred_result = try callBuiltin(env_env.allocator, f, arg_list, env_env);
        defer pred_result.deinit(env_env.allocator);
        if (!pred_result.isTruthy()) {
            try result.append(env_env.allocator, try item.clone(env_env.allocator));
        }
    }
    return Value.listValue(result);
}

pub fn core_every_q(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        .set => items = coll.set_val.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var pred_result = try callBuiltin(env_env.allocator, f, arg_list, env_env);
        defer pred_result.deinit(env_env.allocator);
        if (!pred_result.isTruthy()) return Value.boolValue(false);
    }
    return Value.boolValue(true);
}

pub fn core_some(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const f = args.items[0];
    const coll = args.items[1];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        .set => items = coll.set_val.items,
        else => return error.TypeError,
    }

    for (items) |item| {
        var arg_list: list.List = .empty;
        defer arg_list.deinit(env_env.allocator);
        try arg_list.append(env_env.allocator, try item.clone(env_env.allocator));
        var result = try callBuiltin(env_env.allocator, f, arg_list, env_env);
        if (result.isTruthy()) return result;
        result.deinit(env_env.allocator);
    }
    return Value.nilValue();
}

pub fn core_distinct_q(_: *Value, args: list.List, _: *Env) anyerror!Value {
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];

    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }

    for (items, 0..) |item, i| {
        var j: usize = i + 1;
        while (j < items.len) : (j += 1) {
            if (item.equals(items[j])) return Value.boolValue(false);
        }
    }
    return Value.boolValue(true);
}

pub fn core_peek(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    switch (coll.type) {
        .queue => {
            if (coll.queue_val.items.len == 0) return Value.nilValue();
            return try coll.queue_val.items[0].clone(env_env.allocator);
        },
        .vector => {
            if (coll.vec_val.items.len == 0) return Value.nilValue();
            return try coll.vec_val.items[coll.vec_val.items.len - 1].clone(env_env.allocator);
        },
        .list => {
            if (coll.list_val.items.len == 0) return Value.nilValue();
            return try coll.list_val.items[coll.list_val.items.len - 1].clone(env_env.allocator);
        },
        else => return error.TypeError,
    }
}

pub fn core_vector_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .vector);
}

pub fn core_map_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .map);
}

pub fn core_queue_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .queue);
}

// Helper to call a builtin or user function
fn callBuiltin(allocator: Allocator, f: Value, args_list: list.List, env: *Env) anyerror!Value {
    switch (f.type) {
        .function => {
            const fn_data = f.fn_val;
            var new_env = try fn_data.env.clone(allocator);
            defer new_env.deinit(allocator);

            if (args_list.items.len != fn_data.params.items.len) {
                return error.ArityError;
            }
            var i: usize = 0;
            while (i < fn_data.params.items.len) : (i += 1) {
                const param = fn_data.params.items[i];
                if (param.type == .symbol) {
                    try new_env.put(allocator, param.sym_val, try args_list.items[i].clone(allocator));
                }
            }
            return try evalBody(allocator, fn_data.body, &new_env);
        },
        .builtin_fn => {
            var f_mut = f;
            return f_mut.builtin_fn_val(&f_mut, args_list, env);
        },
        else => return error.NotCallable,
    }
}

fn evalBody(allocator: Allocator, body: list.List, env: *Env) anyerror!Value {
    // The body is a list like (do form1 form2 ...)
    // Evaluate it as a single list expression
    if (body.items.len == 0) return Value.nilValue();
    // Clone the body since we need to pass ownership to Value.listValue
    var cloned_body: list.List = .empty;
    errdefer cloned_body.deinit(allocator);
    try cloned_body.ensureTotalCapacity(allocator, body.items.len);
    for (body.items) |item| {
        try cloned_body.append(allocator, try item.clone(allocator));
    }
    return try evalForm(allocator, Value.listValue(cloned_body), env);
}

fn evalForm(allocator: Allocator, form: Value, env: *Env) anyerror!Value {
    switch (form.type) {
        .nil, .bool, .integer, .float, .string, .keyword => return try form.clone(allocator),
        .symbol => {
            if (env.get(form.sym_val)) |v| return try v.clone(allocator);
            return error.UndefinedSymbol;
        },
        .list => {
            if (form.list_val.items.len == 0) return Value.listValue(list.empty());
            const first = form.list_val.items[0];
            if (first.type == .symbol) {
                if (std.mem.eql(u8, first.sym_val, "quote")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    return try form.list_val.items[1].clone(allocator);
                }
                if (std.mem.eql(u8, first.sym_val, "do")) {
                    // Evaluate all forms, return last
                    var result: Value = Value.nilValue();
                    errdefer result.deinit(allocator);
                    for (form.list_val.items[1..]) |arg| {
                        result.deinit(allocator);
                        result = try evalForm(allocator, arg, env);
                    }
                    return result;
                }
            }
            // Evaluate operator
            const op = try evalForm(allocator, first, env);
            var args: list.List = .empty;
            errdefer args.deinit(allocator);
            for (form.list_val.items[1..]) |arg| {
                try args.append(allocator, try evalForm(allocator, arg, env));
            }
            return try callBuiltin(allocator, op, args, env);
        },
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            for (form.vec_val.items) |item| {
                try new_vec.append(allocator, try evalForm(allocator, item, env));
            }
            return Value.vectorValue(new_vec);
        },
        else => return try form.clone(allocator),
    }
}

fn listFromSlice(allocator: Allocator, items: []const Value) anyerror!list.List {
    var result: list.List = .empty;
    errdefer result.deinit(allocator);
    for (items) |item| {
        try result.append(allocator, try item.clone(allocator));
    }
    return result;
}

// Helper functions
fn isIntF64(f: f64) bool {
    if (std.math.isNan(f) or std.math.isInf(f)) return false;
    const min_f: f64 = @as(f64, @floatFromInt(std.math.minInt(i64)));
    const max_f: f64 = @as(f64, @floatFromInt(std.math.maxInt(i64)));
    if (f < min_f or f > max_f) return false;
    const i = @as(i64, @intFromFloat(f));
    return f == @as(f64, @floatFromInt(i));
}

fn toInt(v: Value) anyerror!i64 {
    return switch (v.type) {
        .integer => v.int_val,
        .float => @as(i64, @intFromFloat(v.float_val)),
        else => return error.TypeError,
    };
}

fn toNum(v: Value) f64 {
    return switch (v.type) {
        .integer => @as(f64, @floatFromInt(v.int_val)),
        .float => v.float_val,
        else => 0,
    };
}

// drop - drop first n elements from a collection
pub fn core_drop(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const n = try toInt(args.items[0]);
    const coll = args.items[1];

    var items: []const Value = undefined;
    var is_list: bool = false;
    switch (coll.type) {
        .list => { items = coll.list_val.items; is_list = true; },
        .vector => { items = coll.vec_val.items; is_list = false; },
        else => return error.TypeError,
    }

    if (n <= 0) return try coll.clone(env_env.allocator);
    if (@as(usize, @intCast(n)) >= items.len) {
        if (is_list) return Value.listValue(list.empty());
        return Value.vectorValue(vec.Vector.empty);
    }

    const start: usize = @as(usize, @intCast(n));
    if (is_list) {
        var result: list.List = .empty;
        errdefer result.deinit(env_env.allocator);
        var i: usize = start;
        while (i < items.len) : (i += 1) {
            try result.append(env_env.allocator, try items[i].clone(env_env.allocator));
        }
        return Value.listValue(result);
    } else {
        var result: vec.Vector = .empty;
        errdefer result.deinit(env_env.allocator);
        var i: usize = start;
        while (i < items.len) : (i += 1) {
            try result.append(env_env.allocator, try items[i].clone(env_env.allocator));
        }
        return Value.vectorValue(result);
    }
}

// apply - apply function to a collection of arguments
pub fn core_apply(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];

    // Build the argument list from all args, with the last one being a collection to spread
    var call_args: list.List = .empty;
    errdefer call_args.deinit(env_env.allocator);

    // Add all args except the last as-is
    var i: usize = 1;
    while (i < args.items.len - 1) : (i += 1) {
        try call_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }

    // Spread the last argument (collection)
    const coll = args.items[args.items.len - 1];
    var items: []const Value = undefined;
    switch (coll.type) {
        .list => items = coll.list_val.items,
        .vector => items = coll.vec_val.items,
        else => return error.TypeError,
    }
    for (items) |item| {
        try call_args.append(env_env.allocator, try item.clone(env_env.allocator));
    }

    return try callBuiltin(env_env.allocator, f, call_args, env_env);
}

// if-not - if test is false, evaluate then, else evaluate else (if provided)
pub fn core_if_not(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    // This is a builtin that evaluates its args, but since it's called from
    // the general call path, args are already evaluated. We need a special form
    // for proper lazy evaluation. For now, handle the evaluated version.
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    const cond = args.items[0];
    if (!cond.isTruthy()) {
        return try args.items[1].clone(env_env.allocator);
    }
    if (args.items.len == 3) {
        return try args.items[2].clone(env_env.allocator);
    }
    return Value.nilValue();
}

// partial - return a function that is a partial application of f
pub fn core_partial(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];

    // Create a closure that captures f and the partial args
    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    // We'll create a fn with params that combine partial args + remaining args
    // Since we can't do true varargs, create a body that uses apply
    // For simplicity, store partial args in the env and create a fn that takes remaining args

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    // Store the function and partial args in the environment
    try fn_env.put(env_env.allocator, "__partial_fn", try f.clone(env_env.allocator));
    var partial_args: list.List = .empty;
    errdefer partial_args.deinit(env_env.allocator);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        try partial_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }
    try fn_env.put(env_env.allocator, "__partial_args", Value.listValue(partial_args));

    // Create a fn that takes one arg (the rest will be handled by the caller)
    // Actually, we need to create a fn that when called, calls apply with f + partial_args + new_args
    // Since we can't do varargs, we'll use a special approach:
    // Create a fn [args] (apply __partial_fn (concat __partial_args args))
    // But args needs to be a list. Let's create: (fn [args] (apply __partial_fn (concat __partial_args (list args))))
    // This only works for single additional arg. For full varargs we'd need more.

    // Simpler approach: create a fn that takes remaining args as a list
    var params_list: list.List = .empty;
    errdefer params_list.deinit(env_env.allocator);
    try params_list.append(env_env.allocator, try Value.symValue(env_env.allocator, "args"));

    // Body: (apply __partial_fn (concat __partial_args args))
    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "apply"));
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "__partial_fn"));
    // (concat __partial_args args)
    var concat_call: list.List = .empty;
    errdefer concat_call.deinit(env_env.allocator);
    try concat_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "concat"));
    try concat_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "__partial_args"));
    try concat_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "args"));
    try body.append(env_env.allocator, Value.listValue(concat_call));

    const cloned_params = try params_list.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    var final_env = try env_env.clone(env_env.allocator);
    try final_env.put(env_env.allocator, "__partial_fn", try f.clone(env_env.allocator));
    var stored_args: list.List = .empty;
    errdefer stored_args.deinit(env_env.allocator);
    i = 1;
    while (i < args.items.len) : (i += 1) {
        try stored_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }
    try final_env.put(env_env.allocator, "__partial_args", Value.listValue(stored_args));

    return Value.fnValue(cloned_params, cloned_body, final_env);
}

// comp - compose functions (right to left)
pub fn core_comp(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;

    if (args.items.len == 1) return try args.items[0].clone(env_env.allocator);

    // Create a fn that applies functions right to left
    // (comp f g h) => (fn [x] (f (g (h x))))
    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    // Store functions in the env
    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__comp_fn_{d}", .{i});
        try fn_env.put(env_env.allocator, key, try args.items[i].clone(env_env.allocator));
    }

    // Create params: [x]
    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    try params.append(env_env.allocator, try Value.symValue(env_env.allocator, "x"));

    // Build nested body: (do (f0 (f1 (f2 ... x))))
    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "do"));

    // Start from the last function and work backwards
    var current: Value = try Value.symValue(env_env.allocator, "x");
    var j: usize = args.items.len;
    while (j > 0) {
        j -= 1;
        const key = try std.fmt.allocPrint(env_env.allocator, "__comp_fn_{d}", .{j});
        var call: list.List = .empty;
        errdefer call.deinit(env_env.allocator);
        try call.append(env_env.allocator, try Value.symValue(env_env.allocator, key));
        try call.append(env_env.allocator, current);
        current = Value.listValue(call);
    }

    try body.append(env_env.allocator, current);

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return Value.fnValue(cloned_params, cloned_body, final_env);
}

// fnil - provide default values for nil arguments
pub fn core_fnil(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const f = args.items[0];
    // Remaining args are the default values for each parameter position
    const defaults_count = args.items.len - 1;

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    try fn_env.put(env_env.allocator, "__fnil_fn", try f.clone(env_env.allocator));

    // Store defaults
    var d: usize = 0;
    while (d < defaults_count) : (d += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__fnil_default_{d}", .{d});
        try fn_env.put(env_env.allocator, key, try args.items[d + 1].clone(env_env.allocator));
    }

    // Create params: [a0 a1 ...]
    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    d = 0;
    while (d < defaults_count) : (d += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "a{d}", .{d});
        try params.append(env_env.allocator, try Value.symValue(env_env.allocator, key));
    }

    // Build body: (apply __fnil_fn (list (if (nil? a0) __fnil_default_0 a0) ...))
    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "apply"));
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "__fnil_fn"));

    // Build (list (if (nil? a0) default0 a0) (if (nil? a1) default1 a1) ...)
    var list_call: list.List = .empty;
    errdefer list_call.deinit(env_env.allocator);
    try list_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "list"));
    d = 0;
    while (d < defaults_count) : (d += 1) {
        const param_key = try std.fmt.allocPrint(env_env.allocator, "a{d}", .{d});
        const default_key = try std.fmt.allocPrint(env_env.allocator, "__fnil_default_{d}", .{d});

        // (if (nil? aN) defaultN aN)
        var if_call: list.List = .empty;
        errdefer if_call.deinit(env_env.allocator);
        try if_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "if"));

        // (nil? aN)
        var nil_q_call: list.List = .empty;
        errdefer nil_q_call.deinit(env_env.allocator);
        try nil_q_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "nil?"));
        try nil_q_call.append(env_env.allocator, try Value.symValue(env_env.allocator, param_key));
        try if_call.append(env_env.allocator, Value.listValue(nil_q_call));
        try if_call.append(env_env.allocator, try Value.symValue(env_env.allocator, default_key));
        try if_call.append(env_env.allocator, try Value.symValue(env_env.allocator, param_key));

        try list_call.append(env_env.allocator, Value.listValue(if_call));
    }
    try body.append(env_env.allocator, Value.listValue(list_call));

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return Value.fnValue(cloned_params, cloned_body, final_env);
}

// juxt - juxtaposition of functions
pub fn core_juxt(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 1) return error.ArityError;

    var fn_env = try env_env.clone(env_env.allocator);
    defer fn_env.deinit(env_env.allocator);

    // Store functions
    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__juxt_fn_{d}", .{i});
        try fn_env.put(env_env.allocator, key, try args.items[i].clone(env_env.allocator));
    }

    // Create params: [x]
    var params: list.List = .empty;
    errdefer params.deinit(env_env.allocator);
    try params.append(env_env.allocator, try Value.symValue(env_env.allocator, "x"));

    // Build body: (do (vec (f0 x) (f1 x) ...))
    var body: list.List = .empty;
    errdefer body.deinit(env_env.allocator);
    try body.append(env_env.allocator, try Value.symValue(env_env.allocator, "do"));

    var vec_call: list.List = .empty;
    errdefer vec_call.deinit(env_env.allocator);
    try vec_call.append(env_env.allocator, try Value.symValue(env_env.allocator, "vec"));
    i = 0;
    while (i < args.items.len) : (i += 1) {
        const key = try std.fmt.allocPrint(env_env.allocator, "__juxt_fn_{d}", .{i});
        var call: list.List = .empty;
        errdefer call.deinit(env_env.allocator);
        try call.append(env_env.allocator, try Value.symValue(env_env.allocator, key));
        try call.append(env_env.allocator, try Value.symValue(env_env.allocator, "x"));
        try vec_call.append(env_env.allocator, Value.listValue(call));
    }
    try body.append(env_env.allocator, Value.listValue(vec_call));

    const cloned_params = try params.clone(env_env.allocator);
    const cloned_body = try body.clone(env_env.allocator);
    const final_env = try fn_env.clone(env_env.allocator);

    return Value.fnValue(cloned_params, cloned_body, final_env);
}

// atom - create a mutable reference
pub fn core_atom(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return try Value.atomValue(env_env.allocator, args.items[0]);
}

// swap! - atomically swap an atom's value
pub fn core_swap_bang(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2) return error.ArityError;
    const atom = args.items[0];
    if (atom.type != .atom) return error.TypeError;
    if (atom.atom_val == null) return error.TypeError;

    const f = args.items[1];

    // Build args for f: current value + extra args
    var call_args: list.List = .empty;
    errdefer call_args.deinit(env_env.allocator);
    try call_args.append(env_env.allocator, try atom.atom_val.?.clone(env_env.allocator));
    var i: usize = 2;
    while (i < args.items.len) : (i += 1) {
        try call_args.append(env_env.allocator, try args.items[i].clone(env_env.allocator));
    }

    const new_val = try callBuiltin(env_env.allocator, f, call_args, env_env);

    // Update the atom's value
    atom.atom_val.?.deinit(env_env.allocator);
    atom.atom_val.?.* = new_val;

    return try new_val.clone(env_env.allocator);
}

// reset! - reset an atom's value
pub fn core_reset_bang(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const atom = args.items[0];
    if (atom.type != .atom) return error.TypeError;
    if (atom.atom_val == null) return error.TypeError;

    const new_val = try args.items[1].clone(env_env.allocator);
    atom.atom_val.?.deinit(env_env.allocator);
    atom.atom_val.?.* = new_val;

    return try new_val.clone(env_env.allocator);
}

// Register all core functions in the environment
pub fn registerCoreFunctions(env: *Env) anyerror!void {
    const allocator = env.allocator;

    // Arithmetic
    try env.put(allocator, "plus", Value.builtinFnValue(core_plus));
    try env.put(allocator, "minus", Value.builtinFnValue(core_minus));
    try env.put(allocator, "mult", Value.builtinFnValue(core_mult));
    try env.put(allocator, "div", Value.builtinFnValue(core_div));
    try env.put(allocator, "mod", Value.builtinFnValue(core_mod));

    // Comparison
    try env.put(allocator, "eq", Value.builtinFnValue(core_eq));
    try env.put(allocator, "not-eq", Value.builtinFnValue(core_not_eq));
    try env.put(allocator, "<", Value.builtinFnValue(core_less));
    try env.put(allocator, ">", Value.builtinFnValue(core_greater));
    try env.put(allocator, "<=", Value.builtinFnValue(core_less_eq));
    try env.put(allocator, ">=", Value.builtinFnValue(core_greater_eq));

    // Boolean
    try env.put(allocator, "not", Value.builtinFnValue(core_not));

    // Type checking
    try env.put(allocator, "nil?", Value.builtinFnValue(core_nil_q));
    try env.put(allocator, "number?", Value.builtinFnValue(core_number_q));
    try env.put(allocator, "string?", Value.builtinFnValue(core_string_q));
    try env.put(allocator, "list?", Value.builtinFnValue(core_list_q));
    try env.put(allocator, "symbol?", Value.builtinFnValue(core_symbol_q));
    try env.put(allocator, "keyword?", Value.builtinFnValue(core_keyword_q));
    try env.put(allocator, "true?", Value.builtinFnValue(core_true_q));
    try env.put(allocator, "false?", Value.builtinFnValue(core_false_q));

    // String
    try env.put(allocator, "str", Value.builtinFnValue(core_str));
    try env.put(allocator, "utf8-valid?", Value.builtinFnValue(core_utf8_valid_q));

    // Sequences
    try env.put(allocator, "count", Value.builtinFnValue(core_count));
    try env.put(allocator, "first", Value.builtinFnValue(core_first));
    try env.put(allocator, "rest", Value.builtinFnValue(core_rest));
    try env.put(allocator, "nth", Value.builtinFnValue(core_nth));
    try env.put(allocator, "concat", Value.builtinFnValue(core_concat));
    try env.put(allocator, "list", Value.builtinFnValue(core_list));
    try env.put(allocator, "vec", Value.builtinFnValue(core_vec));

    // I/O
    try env.put(allocator, "print", Value.builtinFnValue(core_print));
    try env.put(allocator, "println", Value.builtinFnValue(core_println));
    try env.put(allocator, "read-line", Value.builtinFnValue(core_read_line));
    try env.put(allocator, "spit", Value.builtinFnValue(core_spit));
    try env.put(allocator, "slurp", Value.builtinFnValue(core_slurp));

    // Maps
    try env.put(allocator, "get", Value.builtinFnValue(core_get));
    try env.put(allocator, "assoc", Value.builtinFnValue(core_assoc));
    try env.put(allocator, "keys", Value.builtinFnValue(core_keys));
    try env.put(allocator, "vals", Value.builtinFnValue(core_vals));
    try env.put(allocator, "dissoc", Value.builtinFnValue(core_dissoc));
    try env.put(allocator, "merge", Value.builtinFnValue(core_merge));

    // Set functions
    try env.put(allocator, "set", Value.builtinFnValue(core_set));
    try env.put(allocator, "set?", Value.builtinFnValue(core_set_q));
    try env.put(allocator, "disj", Value.builtinFnValue(core_disj));

    // Collection operations
    try env.put(allocator, "conj", Value.builtinFnValue(core_conj));
    try env.put(allocator, "pop", Value.builtinFnValue(core_pop));
    try env.put(allocator, "last", Value.builtinFnValue(core_last));
    try env.put(allocator, "reverse", Value.builtinFnValue(core_reverse));
    try env.put(allocator, "range", Value.builtinFnValue(core_range));
    try env.put(allocator, "peek", Value.builtinFnValue(core_peek));

    // Sequence/collection predicates
    try env.put(allocator, "contains?", Value.builtinFnValue(core_contains_q));
    try env.put(allocator, "empty?", Value.builtinFnValue(core_empty_q));
    try env.put(allocator, "not-empty", Value.builtinFnValue(core_not_empty));
    try env.put(allocator, "seq", Value.builtinFnValue(core_seq));
    try env.put(allocator, "coll?", Value.builtinFnValue(core_coll_q));
    try env.put(allocator, "sequential?", Value.builtinFnValue(core_sequential_q));
    try env.put(allocator, "next", Value.builtinFnValue(core_next));
    try env.put(allocator, "nthnext", Value.builtinFnValue(core_nthnext));

    // Sequence operations
    try env.put(allocator, "reduce", Value.builtinFnValue(core_reduce));
    try env.put(allocator, "flatten", Value.builtinFnValue(core_flatten));
    try env.put(allocator, "filter", Value.builtinFnValue(core_filter));
    try env.put(allocator, "remove", Value.builtinFnValue(core_remove));
    try env.put(allocator, "every?", Value.builtinFnValue(core_every_q));
    try env.put(allocator, "some", Value.builtinFnValue(core_some));
    try env.put(allocator, "distinct?", Value.builtinFnValue(core_distinct_q));

    // Type predicates
    try env.put(allocator, "vector?", Value.builtinFnValue(core_vector_q));
    try env.put(allocator, "map?", Value.builtinFnValue(core_map_q));
    try env.put(allocator, "queue?", Value.builtinFnValue(core_queue_q));

    // New sequence operations
    try env.put(allocator, "drop", Value.builtinFnValue(core_drop));
    try env.put(allocator, "apply", Value.builtinFnValue(core_apply));

    // Functional tools
    try env.put(allocator, "if-not", Value.builtinFnValue(core_if_not));
    try env.put(allocator, "partial", Value.builtinFnValue(core_partial));
    try env.put(allocator, "comp", Value.builtinFnValue(core_comp));
    try env.put(allocator, "fnil", Value.builtinFnValue(core_fnil));
    try env.put(allocator, "juxt", Value.builtinFnValue(core_juxt));

    // Atoms
    try env.put(allocator, "atom", Value.builtinFnValue(core_atom));
    try env.put(allocator, "swap!", Value.builtinFnValue(core_swap_bang));
    try env.put(allocator, "reset!", Value.builtinFnValue(core_reset_bang));

    // Clojure-style aliases
    try env.put(allocator, "+", Value.builtinFnValue(core_plus));
    try env.put(allocator, "-", Value.builtinFnValue(core_minus));
    try env.put(allocator, "*", Value.builtinFnValue(core_mult));
    try env.put(allocator, "/", Value.builtinFnValue(core_div));
    try env.put(allocator, "rem", Value.builtinFnValue(core_mod));
    try env.put(allocator, "=", Value.builtinFnValue(core_eq));
    try env.put(allocator, "!=", Value.builtinFnValue(core_not_eq));
    try env.put(allocator, "not", Value.builtinFnValue(core_not));
    try env.put(allocator, "str", Value.builtinFnValue(core_str));
    try env.put(allocator, "count", Value.builtinFnValue(core_count));
    try env.put(allocator, "first", Value.builtinFnValue(core_first));
    try env.put(allocator, "rest", Value.builtinFnValue(core_rest));
    try env.put(allocator, "nth", Value.builtinFnValue(core_nth));
    try env.put(allocator, "concat", Value.builtinFnValue(core_concat));
    try env.put(allocator, "list", Value.builtinFnValue(core_list));
    try env.put(allocator, "vec", Value.builtinFnValue(core_vec));

    // defn is handled as a special form alias in the evaluator
}
