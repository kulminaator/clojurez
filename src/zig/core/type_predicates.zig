// Type checking predicates and type constructors
// nil?, number?, string?, list?, symbol?, keyword?, true?, false?, fn?,
// vector?, map?, queue?, coll?, sequential?, keyword
const std = @import("std");
const Value = @import("../value.zig");
const list = @import("../list.zig");
const Env = Value.Env;

// Type predicates
pub fn core_nil_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .nil);
}

pub fn core_number_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .integer or args.items[0].type == .float);
}

pub fn core_string_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .string);
}

pub fn core_list_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .list);
}

pub fn core_symbol_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .symbol);
}

pub fn core_keyword_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .keyword);
}

pub fn core_true_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .bool and args.items[0].bool_val);
}

pub fn core_false_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .bool and !args.items[0].bool_val);
}

pub fn core_fn_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .function or args.items[0].type == .builtin_fn);
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

// Type constructor
pub fn core_keyword(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len == 1) {
        const arg = args.items[0];
        if (arg.type == .keyword) return try arg.clone(allocator);
        if (arg.type == .symbol) {
            return Value.keywordValue(allocator, arg.sym_val);
        }
        if (arg.type == .string) {
            return Value.keywordValue(allocator, arg.str_val);
        }
    } else if (args.items.len == 2) {
        const ns = args.items[0];
        const name = args.items[1];
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        switch (ns.type) {
            .string => try buf.appendSlice(allocator, ns.str_val),
            .symbol => try buf.appendSlice(allocator, ns.sym_val),
            .keyword => try buf.appendSlice(allocator, ns.kw_val),
            else => return error.TypeError,
        }
        try buf.appendSlice(allocator, "/");
        switch (name.type) {
            .string => try buf.appendSlice(allocator, name.str_val),
            .symbol => try buf.appendSlice(allocator, name.sym_val),
            .keyword => try buf.appendSlice(allocator, name.kw_val),
            else => return error.TypeError,
        }
        return Value.keywordValue(allocator, buf.items);
    }
    return error.ArityError;
}

pub fn registerTypePredicateFunctions(env: *Env) anyerror!void {
    const allocator = env.allocator;
    try env.put(allocator, "nil?", Value.builtinFnValue(core_nil_q));
    try env.put(allocator, "number?", Value.builtinFnValue(core_number_q));
    try env.put(allocator, "string?", Value.builtinFnValue(core_string_q));
    try env.put(allocator, "list?", Value.builtinFnValue(core_list_q));
    try env.put(allocator, "symbol?", Value.builtinFnValue(core_symbol_q));
    try env.put(allocator, "keyword?", Value.builtinFnValue(core_keyword_q));
    try env.put(allocator, "true?", Value.builtinFnValue(core_true_q));
    try env.put(allocator, "false?", Value.builtinFnValue(core_false_q));
    try env.put(allocator, "fn?", Value.builtinFnValue(core_fn_q));
    try env.put(allocator, "vector?", Value.builtinFnValue(core_vector_q));
    try env.put(allocator, "map?", Value.builtinFnValue(core_map_q));
    try env.put(allocator, "queue?", Value.builtinFnValue(core_queue_q));
    try env.put(allocator, "coll?", Value.builtinFnValue(core_coll_q));
    try env.put(allocator, "sequential?", Value.builtinFnValue(core_sequential_q));
    // Type constructors
    try env.put(allocator, "keyword", Value.builtinFnValue(core_keyword));
}

