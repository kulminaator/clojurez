// Quasiquote processing: `form, unquote (~), unquote-splicing (~@)
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const vec = @import("vector.zig");
const Env = vm.Env;
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

// Quasiquote processing
pub fn unquoteProcess(allocator: Allocator, form: Value, env: *Env, depth: usize) anyerror!Value {
    switch (std.meta.activeTag(form)) {
        .list => {
            if (form.list.items.items.len == 0) return try vm.listValue(allocator, list.empty());
            const first = form.list.items.items[0];
            if (std.meta.activeTag(first) == .symbol) {
                if (std.mem.eql(u8, first.symbol, "unquote")) {
                    if (form.list.items.items.len != 2) return error.ArityError;
                    const ptr = try eval.evalRec(allocator, &form.list.items.items[1], env, depth);
                    const result = ptr.*;
                    return result;
                }
                if (std.mem.eql(u8, first.symbol, "unquote-splicing")) {
                    if (form.list.items.items.len != 2) return error.ArityError;
                    const result_ptr = try eval.evalRec(allocator, &form.list.items.items[1], env, depth);
                    if (std.meta.activeTag(result_ptr.*) == .list) return result_ptr.*;
                    return error.TypeError;
                }
            }
            // Process each element
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            for (form.list.items.items) |item| {
                // Check for unquote-splicing: splice elements directly into result
                if (std.meta.activeTag(item) == .list and item.list.items.items.len == 2) {
                    const uq_first = item.list.items.items[0];
                    if (std.meta.activeTag(uq_first) == .symbol and std.mem.eql(u8, uq_first.symbol, "unquote-splicing")) {
                        const splice_ptr = try eval.evalRec(allocator, &item.list.items.items[1], env, depth);
                        if (std.meta.activeTag(splice_ptr.*) == .list) {
                            for (splice_ptr.*.list.items.items) |elem| {
                                try result.append(allocator, try vm.clone(&elem, allocator));
                            }
                        }
                        vm.valueDeinit(&splice_ptr.*, allocator);
                        continue;
                    }
                }
                const processed = try unquoteProcess(allocator, item, env, depth);
                try result.append(allocator, processed);
            }
            return try vm.listValue(allocator, result);
        },
        .vector => {
            var result: vec.Vector = .empty;
            errdefer result.deinit(allocator);
            for (form.vector.items.items) |item| {
                try result.append(allocator, try unquoteProcess(allocator, item, env, depth));
            }
            return try vm.vectorValue(allocator, result);
        },
        else => return try vm.clone(&form, allocator),
    }
}
