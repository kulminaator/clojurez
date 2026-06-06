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
    try env.put("nil?", Value.builtinFnValue(core_nil_q));
    try env.put("number?", Value.builtinFnValue(core_number_q));
    try env.put("string?", Value.builtinFnValue(core_string_q));
    try env.put("list?", Value.builtinFnValue(core_list_q));
    try env.put("symbol?", Value.builtinFnValue(core_symbol_q));
    try env.put("keyword?", Value.builtinFnValue(core_keyword_q));
    try env.put("true?", Value.builtinFnValue(core_true_q));
    try env.put("false?", Value.builtinFnValue(core_false_q));
    try env.put("fn?", Value.builtinFnValue(core_fn_q));
    try env.put("vector?", Value.builtinFnValue(core_vector_q));
    try env.put("map?", Value.builtinFnValue(core_map_q));
    try env.put("queue?", Value.builtinFnValue(core_queue_q));
    try env.put("coll?", Value.builtinFnValue(core_coll_q));
    try env.put("sequential?", Value.builtinFnValue(core_sequential_q));
    // Type constructors
    try env.put("keyword", Value.builtinFnValue(core_keyword));
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

test "type_predicates::nil_q: nil is nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_nil_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::nil_q: int is not nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1) });
    var result = core_nil_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::number_q: integer is number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_number_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::number_q: float is number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(3.14) });
    var result = core_number_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::number_q: nil is not number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_number_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::true_q: true is true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.boolValue(true) });
    var result = core_true_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::true_q: false is not true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.boolValue(false) });
    var result = core_true_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::false_q: false is false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.boolValue(false) });
    var result = core_false_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::coll_q: list is coll" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_coll_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::coll_q: nil is not coll" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_coll_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::sequential_q: list is sequential" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_sequential_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::sequential_q: set is not sequential" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.setValue(.empty) });
    var result = core_sequential_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

