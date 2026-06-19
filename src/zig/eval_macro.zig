// Quasiquote processing: `form, unquote (~), unquote-splicing (~@)
const std = @import("std");
const Value = @import("value.zig");
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = Value.Env;
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

// Quasiquote processing
pub fn unquoteProcess(allocator: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    switch (form.type) {
        .list => {
            if (form.list_val.items.len == 0) return Value.listValue(list.empty());
            const first = form.list_val.items[0];
            if (first.type == .symbol) {
                if (std.mem.eql(u8, first.sym_val, "unquote")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    const ptr = try eval.evalRec(allocator, form.list_val.items[1], env, depth);
                    const result = ptr.*;
                    return result;
                }
                if (std.mem.eql(u8, first.sym_val, "unquote-splicing")) {
                    if (form.list_val.items.len != 2) return error.ArityError;
                    const result_ptr = try eval.evalRec(allocator, form.list_val.items[1], env, depth);
                    if (result_ptr.type == .list) return result_ptr.*;
                    return error.TypeError;
                }
            }
            // Process each element
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            for (form.list_val.items) |item| {
                // Check for unquote-splicing: splice elements directly into result
                if (item.type == .list and item.list_val.items.len == 2) {
                    const uq_first = item.list_val.items[0];
                    if (uq_first.type == .symbol and std.mem.eql(u8, uq_first.sym_val, "unquote-splicing")) {
                        const splice_ptr = try eval.evalRec(allocator, item.list_val.items[1], env, depth);
                        if (splice_ptr.type == .list) {
                            for (splice_ptr.list_val.items) |elem| {
                                try result.append(allocator, try elem.clone(allocator));
                            }
                        }
                        splice_ptr.*.deinit(allocator);
                        continue;
                    }
                }
                const processed = try unquoteProcess(allocator, item, env, depth);
                try result.append(allocator, processed);
            }
            return Value.listValue(result);
        },
        .vector => {
            var result: vec.Vector = .empty;
            errdefer result.deinit(allocator);
            for (form.vec_val.items) |item| {
                try result.append(allocator, try unquoteProcess(allocator, item, env, depth));
            }
            return Value.vectorValue(result);
        },
        else => return try form.clone(allocator),
    }
}
