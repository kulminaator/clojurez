// Quasiquote processing: `form, unquote (~), unquote-splicing (~@)
const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = Value.Env;
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

// Quasiquote processing
pub fn unquoteProcess(allocator: Allocator, arena_alloc: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    switch (form.type) {
        .list => {
            if (form.list_val.items.len == 0) return Value.listValue(list.empty());
            const first = form.list_val.items[0];
            if (first.type == .symbol) {
                if (std.mem.eql(u8, first.sym_val, "unquote")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    return try eval.evalRec(allocator, arena_alloc, form.list_val.items[1], env, depth);
                }
                if (std.mem.eql(u8, first.sym_val, "unquote-splicing")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    const result = try eval.evalRec(allocator, arena_alloc, form.list_val.items[1], env, depth);
                    if (result.type == .list) return result;
                    return error.TypeError;
                }
            }
            // Process each element
            var result: list.List = .empty;
            errdefer result.deinit(arena_alloc);
            for (form.list_val.items) |item| {
                // Check for unquote-splicing: splice elements directly into result
                if (item.type == .list and item.list_val.items.len == 2) {
                    const uq_first = item.list_val.items[0];
                    if (uq_first.type == .symbol and std.mem.eql(u8, uq_first.sym_val, "unquote-splicing")) {
                        var splice_result = try eval.evalRec(allocator, arena_alloc, item.list_val.items[1], env, depth);
                        if (splice_result.type == .list) {
                            for (splice_result.list_val.items) |elem| {
                                try result.append(arena_alloc, try elem.clone(arena_alloc));
                            }
                        }
                        splice_result.deinit(arena_alloc);
                        continue;
                    }
                }
                const processed = try unquoteProcess(allocator, arena_alloc, item, env, depth);
                try result.append(arena_alloc, processed);
            }
            return Value.listValue(result);
        },
        .vector => {
            var result: vec.Vector = .empty;
            errdefer result.deinit(arena_alloc);
            for (form.vec_val.items) |item| {
                try result.append(arena_alloc, try unquoteProcess(allocator, arena_alloc, item, env, depth));
            }
            return Value.vectorValue(result);
        },
        else => return try form.clone(arena_alloc),
    }
}
