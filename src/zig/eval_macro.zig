// Quasiquote processing: `form, unquote (~), unquote-splicing (~@)
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const vec = @import("vector.zig");
const eval = @import("eval.zig");

const Allocator = std.mem.Allocator;

// Quasiquote processing — takes *Frame so unquote can resolve local bindings
// (e.g. macro parameters) that live in the Frame overlay, not just root_env.
pub fn unquoteProcess(allocator: Allocator, form: Value, frame: *vm.Frame, depth: usize) anyerror!Value {
    switch (std.meta.activeTag(form)) {
        .list => {
            if (form.list.items.items.len == 0) return try vm.listValue(allocator, list.empty());
            const first = form.list.items.items[0];
            if (std.meta.activeTag(first) == .symbol) {
                if (std.mem.eql(u8, first.symbol, "unquote")) {
                    if (form.list.items.items.len != 2) return error.ArityError;
                    const r = try eval.evalRec(allocator, &form.list.items.items[1], frame, depth);
                    const result = r.value.*;
                    return result;
                }
                if (std.mem.eql(u8, first.symbol, "unquote-splicing")) {
                    if (form.list.items.items.len != 2) return error.ArityError;
                    const result_r = try eval.evalRec(allocator, &form.list.items.items[1], frame, depth);
                    const result_ptr = result_r.value;
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
                        const splice_r = try eval.evalRec(allocator, &item.list.items.items[1], frame, depth);
                        const splice_ptr = splice_r.value;
                        if (std.meta.activeTag(splice_ptr.*) == .list) {
                            for (splice_ptr.*.list.items.items) |elem| {
                                try result.append(allocator, try vm.shallowClone(&elem, allocator));
                            }
                        }
                        vm.valueDeinit(&splice_ptr.*, allocator);
                        continue;
                    }
                }
                const processed = try unquoteProcess(allocator, item, frame, depth);
                try result.append(allocator, processed);
            }
            return try vm.listValue(allocator, result);
        },
        .vector => {
            var result: vec.Vector = .empty;
            errdefer result.deinit(allocator);
            for (form.vector.items.items) |item| {
                try result.append(allocator, try unquoteProcess(allocator, item, frame, depth));
            }
            return try vm.vectorValue(allocator, result);
        },
        else => return try vm.shallowClone(&form, allocator),
    }
}
