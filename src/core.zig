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

pub fn core_inc(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const n = try toInt(args.items[0]);
    return Value.intValue(n + 1);
}

pub fn core_dec(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const n = try toInt(args.items[0]);
    return Value.intValue(n - 1);
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

pub fn core_count(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    // env used for allocator
    if (args.items.len != 1) return error.ArityError;
    switch (args.items[0].type) {
        .list => return Value.intValue(@as(i64, @intCast(args.items[0].list_val.items.len))),
        .vector => return Value.intValue(@as(i64, @intCast(args.items[0].vec_val.items.len))),
        .string => return Value.intValue(@as(i64, @intCast(args.items[0].str_val.len))),
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
            if (idx < 0 or @as(usize, @intCast(idx)) >= args.items[0].str_val.len) return Value.nilValue();
            return Value.stringValue(env_env.allocator, args.items[0].str_val[@as(usize, @intCast(idx))..][0..1]);
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

// Register all core functions in the environment
pub fn registerCoreFunctions(env: *Env) anyerror!void {
    const allocator = env.allocator;

    // Arithmetic
    try env.put(allocator, "plus", Value.builtinFnValue(core_plus));
    try env.put(allocator, "minus", Value.builtinFnValue(core_minus));
    try env.put(allocator, "mult", Value.builtinFnValue(core_mult));
    try env.put(allocator, "div", Value.builtinFnValue(core_div));
    try env.put(allocator, "mod", Value.builtinFnValue(core_mod));
    try env.put(allocator, "inc", Value.builtinFnValue(core_inc));
    try env.put(allocator, "dec", Value.builtinFnValue(core_dec));

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

    // Maps
    try env.put(allocator, "get", Value.builtinFnValue(core_get));
    try env.put(allocator, "assoc", Value.builtinFnValue(core_assoc));

    // Collection operations
    try env.put(allocator, "conj", Value.builtinFnValue(core_conj));
    try env.put(allocator, "pop", Value.builtinFnValue(core_pop));
    try env.put(allocator, "last", Value.builtinFnValue(core_last));
    try env.put(allocator, "reverse", Value.builtinFnValue(core_reverse));
    try env.put(allocator, "range", Value.builtinFnValue(core_range));

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
