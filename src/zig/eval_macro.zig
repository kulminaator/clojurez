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
    // Disable trampolining — unquote evaluation is synchronous (macro-time context).
    const saved = eval.trampoline_allowed;
    eval.trampoline_allowed = false;
    defer eval.trampoline_allowed = saved;

    switch (std.meta.activeTag(form)) {
        .list => {
            if (form.list.items.items.len == 0) return try vm.listValue(allocator, list.empty());
            const first = form.list.items.items[0];
            if (std.meta.activeTag(first) == .symbol) {
                if (std.mem.eql(u8, first.symbol.slice(), "unquote")) {
                    if (form.list.items.items.len != 2) return error.ArityError;
                    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
                    return eval.evalRecDirect(allocator, &form.list.items.items[1], frame, depth);
                }
                if (std.mem.eql(u8, first.symbol.slice(), "unquote-splicing")) {
                    if (form.list.items.items.len != 2) return error.ArityError;
                    // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
                    const result_val = try eval.evalRecDirect(allocator, &form.list.items.items[1], frame, depth);
                    if (std.meta.activeTag(result_val) == .list) return result_val;
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
                    if (std.meta.activeTag(uq_first) == .symbol and std.mem.eql(u8, uq_first.symbol.slice(), "unquote-splicing")) {
                        // Phase 3: Use evalRecDirect — Value by copy, no *Value allocation
                        const splice_val = try eval.evalRecDirect(allocator, &item.list.items.items[1], frame, depth);
                        if (std.meta.activeTag(splice_val) == .list) {
                            for (splice_val.list.items.items) |elem| {
                                try result.append(allocator, try vm.shallowClone(&elem, allocator));
                            }
                        }
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
