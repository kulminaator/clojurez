// VM execution engine — the execute() function.
// Dispatches bytecode opcodes and manages the operand stack.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const eval_mod = @import("../eval.zig");
const bc = @import("instructions.zig");
const vmt = @import("vm_types.zig");
const vmo = @import("vm_ops.zig");

const Allocator = std.mem.Allocator;

// Re-export types
pub const OpCode = bc.OpCode;
pub const BytecodeProgram = bc.BytecodeProgram;
pub const SourceMarker = bc.SourceMarker;
pub const VMResult = vmt.VMResult;
pub const StackEntry = vmt.StackEntry;
pub const OperandStack = vmt.OperandStack;
pub const LoopFrame = vmt.LoopFrame;

/// Find the nearest source marker at or before the given PC.
/// Scans instructions backwards from pc to find the last source_marker.
fn findSourceMarkerAtPC(program: *const BytecodeProgram, pc: usize) ?SourceMarker {
    const instrs = program.instructions.items;
    var i: usize = if (pc == 0) 0 else pc - 1;
    while (true) {
        if (instrs[i].opcode == .source_marker) {
            const idx = instrs[i].operand;
            if (idx < program.source_markers.items.len) {
                return program.source_markers.items[idx];
            }
        }
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

/// Print a detailed error message with both CLJ source location and Zig bytecode PC.
pub fn reportBytecodeError(program: *const BytecodeProgram, pc: usize, err: anyerror) void {
    const instrs = program.instructions.items;
    const fail_pc: usize = if (pc == 0) 0 else pc - 1;
    const opcode_name = if (fail_pc < instrs.len) bc.OpCode.opcodeName(instrs[fail_pc].opcode) else "?";

    if (findSourceMarkerAtPC(program, fail_pc)) |marker| {
        std.debug.print(
            "\nBytecode error at {s}:{d} (col {d})\n  Zig PC={d} opcode={s}\n  Error: {s}\n",
            .{ marker.file, marker.line, marker.col, fail_pc, opcode_name, @errorName(err) },
        );
    } else {
        std.debug.print(
            "\nBytecode error at PC={d} opcode={s}\n  Error: {s}\n",
            .{ fail_pc, opcode_name, @errorName(err) },
        );
    }
}

/// Execute a BytecodeProgram with the given environment.
/// The VM is stack-based: values are pushed and popped from the operand stack.
/// Returns VMResult.value with the result, or VMResult.trampoline if a
/// user-defined function call pushed a trampoline frame.
pub fn execute(
    allocator: Allocator,
    program: *const BytecodeProgram,
    env: *vm.Env,
) anyerror!VMResult {
    var stack = OperandStack.init(allocator);
    errdefer stack.deinit();

    var loop_stack: std.ArrayListUnmanaged(*LoopFrame) = .empty;
    defer {
        vmt.cleanupLoopStack(allocator, &loop_stack);
    }

    const fn_pool = program.fn_pool;

    var pc: usize = 0;
    const instrs = program.instructions.items;

    while (pc < instrs.len) {
        const inst = instrs[pc];
        pc += 1;

        switch (inst.opcode) {
            .push_nil => {
                const nil_val = try eval_mod.allocValue(allocator, vm.nilValue());
                try stack.pushPtr(nil_val);
            },
            .push_true => {
                const val = try eval_mod.allocValue(allocator, vm.boolValue(true));
                try stack.pushPtr(val);
            },
            .push_false => {
                const val = try eval_mod.allocValue(allocator, vm.boolValue(false));
                try stack.pushPtr(val);
            },
            .push_int => {
                try stack.pushInt(@as(i64, @intCast(inst.operand)));
            },
            .push_float => {
                const f = @as(f64, @bitCast(inst.operand));
                try stack.pushFloat(f);
            },
            .push_const => {
                const idx = inst.operand;
                if (idx >= program.constants.items.len) return error.BytecodeError;
                const val = try vm.cloneGC(&program.constants.items[idx], allocator);
                try stack.pushPtr(val);
            },

            .load_var => {
                const sym_idx = inst.operand;
                if (sym_idx >= program.symbols.items.len) return error.BytecodeError;
                const sym_name = program.symbols.items[sym_idx];
                const loop_val: ?StackEntry = blk: {
                    var li: usize = loop_stack.items.len;
                    while (li > 0) : (li -= 1) {
                        const lf = loop_stack.items[li - 1];
                        var bi: usize = 0;
                        while (bi < lf.binding_count) : (bi += 1) {
                            const loop_sym = program.symbols.items[lf.binding_sym_indices[bi]];
                            if (std.mem.eql(u8, sym_name, loop_sym)) {
                                break :blk lf.binding_values[bi];
                            }
                        }
                    }
                    break :blk null;
                };
                if (loop_val) |entry| {
                    switch (entry) {
                        .integer => try stack.pushInt(entry.integer),
                        .float => try stack.pushFloat(entry.float),
                        .pointer => {
                            const cloned = try vm.cloneGC(entry.pointer, allocator);
                            try stack.pushPtr(cloned);
                        },
                    }
                } else {
                    const val = try vmo.resolveSymbol(env, sym_name);
                    switch (val) {
                        .integer => try stack.pushInt(val.integer),
                        .float => try stack.pushFloat(val.float),
                        else => {
                            const cloned = try vm.cloneGC(&val, allocator);
                            try stack.pushPtr(cloned);
                        },
                    }
                }
            },
            .load_cached => {
                const idx = inst.operand;
                if (idx >= program.resolved_values.items.len) return error.BytecodeError;
                const val = program.resolved_values.items[idx];
                switch (val) {
                    .integer => try stack.pushInt(val.integer),
                    .float => try stack.pushFloat(val.float),
                    else => {
                        const cloned = try vm.cloneGC(&val, allocator);
                        try stack.pushPtr(cloned);
                    },
                }
            },
            .store_var => {
                const sym_idx = inst.operand;
                if (sym_idx >= program.symbols.items.len) return error.BytecodeError;
                const sym_name = program.symbols.items[sym_idx];
                const entry = stack.pop() orelse return error.BytecodeError;
                const val = entry.toValueConst();
                try env.put(sym_name, try vm.shallowClone(&val, allocator));
            },

            .call_n => {
                const n = inst.operand;
                const fn_entry = stack.pop() orelse return error.BytecodeError;

                var temp_args: std.ArrayListUnmanaged(StackEntry) = .empty;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const arg_entry = stack.pop() orelse {
                        for (temp_args.items) |ae| vmt.freeEntry(ae, allocator);
                        allocator.free(temp_args.items);
                        vmt.freeEntry(fn_entry, allocator);
                        return error.BytecodeError;
                    };
                    try temp_args.append(allocator, arg_entry);
                }

                // Convert StackEntry args to Value slice (reversed to original order).
                // Scoped block: temp_args is freed before exit, so its errdefer
                // doesn't escape into the rest of this handler.
                {
                    var arg_vals: std.ArrayListUnmanaged(Value) = .empty;
                    errdefer {
                        for (arg_vals.items) |*v| vm.valueDeinit(v, allocator);
                        allocator.free(arg_vals.items);
                    }
                    var j: usize = temp_args.items.len;
                    while (j > 0) : (j -= 1) {
                        const arg_entry = temp_args.items[j - 1];
                        const arg_val = arg_entry.toValueConst();
                        try arg_vals.append(allocator, try vm.shallowClone(&arg_val, allocator));
                    }
                    // Free temp_args before leaving scope — arg_vals now owns the values
                    for (temp_args.items) |ae| vmt.freeEntry(ae, allocator);
                    allocator.free(temp_args.items);

                    // --- After this point: fn_entry + arg_vals must be cleaned up ---
                    var arg_vals_freed = false;
                    errdefer {
                        if (arg_vals_freed) {}
                        for (arg_vals.items) |*v| vm.valueDeinit(v, allocator);
                        allocator.free(arg_vals.items);
                    }
                    var fn_entry_freed = false;
                    errdefer {
                        if (fn_entry_freed) {}
                        switch (fn_entry) {
                            .pointer => |v| {
                                vm.valueDeinit(v, allocator);
                                allocator.destroy(v);
                            },
                            .integer, .float => {},
                        }
                    }

                    const fn_val = fn_entry.toValueConst();

                    // Phase 11: Try direct bytecode-to-bytecode call first.
                    // This skips the evaluator layer for bytecode targets.
                    if (try eval_mod.tryExecuteBytecodeCall(
                        allocator, &fn_val, arg_vals.items, env,
                    )) |result_ptr| {
                        // Direct bytecode call succeeded — manually clean up
                        for (arg_vals.items) |*v| vm.valueDeinit(v, allocator);
                        allocator.free(arg_vals.items);
                        arg_vals_freed = true;
                        arg_vals = .empty;
                        switch (fn_entry) {
                            .pointer => |v| {
                                vm.valueDeinit(v, allocator);
                                allocator.destroy(v);
                            },
                            .integer, .float => {},
                        }
                        fn_entry_freed = true;
                        const result_ptr2 = try eval_mod.allocValue(allocator, result_ptr.*);
                        try stack.pushPtr(result_ptr2);
                        continue;
                    }

                    // Fall back to evaluator for non-bytecode functions
                    // Build list.List from arg_vals for callWithEnvV
                    var args: list.List = .empty;
                    errdefer args.deinit(allocator);
                    for (arg_vals.items) |arg_val| {
                        try args.append(allocator, try vm.shallowClone(&arg_val, allocator));
                    }
                    // Manually clean up arg_vals and fn_entry before calling
                    for (arg_vals.items) |*v| vm.valueDeinit(v, allocator);
                    allocator.free(arg_vals.items);
                    arg_vals_freed = true;
                    arg_vals = .empty;
                    switch (fn_entry) {
                        .pointer => |v| {
                            vm.valueDeinit(v, allocator);
                            allocator.destroy(v);
                        },
                        .integer, .float => {},
                    }
                    fn_entry_freed = true;

                    const result_ptr = try eval_mod.callWithEnvV(allocator, &fn_val, &args, env, 0);
                    {
                        var result_val = try vm.shallowClone(result_ptr, allocator);
                        errdefer vm.valueDeinit(&result_val, allocator);
                        allocator.destroy(result_ptr);
                        const result_ptr2 = try eval_mod.allocValue(allocator, result_val);
                        try stack.pushPtr(result_ptr2);
                    }
                }
            },

            .call_self => {
                const n = inst.operand;
                const self_fn_val = program.self_fn orelse return error.BytecodeError;

                // Pop args from stack (reversed order due to LIFO)
                var temp_args: std.ArrayListUnmanaged(StackEntry) = .empty;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const arg_entry = stack.pop() orelse return error.BytecodeError;
                    try temp_args.append(allocator, arg_entry);
                }

                // Build args list in correct order (reverse of stack order)
                var args: list.List = .empty;
                var j: usize = temp_args.items.len;
                while (j > 0) : (j -= 1) {
                    const arg_entry = temp_args.items[j - 1];
                    const arg_val = arg_entry.toValueConst();
                    try args.append(allocator, try vm.shallowClone(&arg_val, allocator));
                }
                // GC handles cleanup of temp_args and args — no manual freeing needed

                const call_result = try eval_mod.callWithEnv(allocator, &self_fn_val, &args, env, 0);

                switch (call_result) {
                    .value => |v| {
                        const ptr = try eval_mod.allocValue(allocator, v);
                        try stack.pushPtr(ptr);
                    },
                    .trampoline => return .trampoline,
                }
            },

            .jump => {
                pc = inst.operand;
            },
            .jump_if_nil => {
                const entry = stack.pop() orelse return error.BytecodeError;
                if (!entry.isTruthy()) {
                    pc = inst.operand;
                }
                vmt.freeEntry(entry, allocator);
            },
            .jump_if_not_nil => {
                const entry = stack.pop() orelse return error.BytecodeError;
                if (entry.isTruthy()) {
                    pc = inst.operand;
                }
                vmt.freeEntry(entry, allocator);
            },

            .eq, .ne, .lt, .gt, .le, .ge, .compare => {
                const b_entry = stack.pop() orelse return error.BytecodeError;
                const a_entry = stack.pop() orelse return error.BytecodeError;
                const a_val = a_entry.toValueConst();
                const b_val = b_entry.toValueConst();
                const result = try vmo.compareOp(inst.opcode, a_val, b_val);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                for ([_]StackEntry{ a_entry, b_entry }) |entry| {
                    vmt.freeEntry(entry, allocator);
                }
                try stack.pushPtr(result_ptr);
            },

            .add, .sub, .mul, .div, .rem, .quot, .mod => {
                const b_entry = stack.pop() orelse return error.BytecodeError;
                const a_entry = stack.pop() orelse return error.BytecodeError;

                if (a_entry.numericTag() == .integer and b_entry.numericTag() == .integer) {
                    const ai = try a_entry.toInteger();
                    const bi = try b_entry.toInteger();
                    const result: i64 = switch (inst.opcode) {
                        .add => ai + bi,
                        .sub => ai - bi,
                        .mul => ai * bi,
                        .div => if (bi == 0) return error.DivisionByZero else @divTrunc(ai, bi),
                        .rem => if (bi == 0) return error.DivisionByZero else ai - @divTrunc(ai, bi) * bi,
                        .quot => if (bi == 0) return error.DivisionByZero else @divTrunc(ai, bi),
                        .mod => if (bi == 0) return error.DivisionByZero else blk: {
                            const q = @divTrunc(ai, bi);
                            const r = ai - q * bi;
                            if ((r != 0) and ((r > 0) != (bi > 0))) {
                                break :blk r + bi;
                            }
                            break :blk r;
                        },
                        else => unreachable,
                    };
                    try stack.pushInt(result);
                } else if (a_entry.numericTag() == .float or b_entry.numericTag() == .float) {
                    const af = try a_entry.toFloat();
                    const bf = try b_entry.toFloat();
                    const result: f64 = switch (inst.opcode) {
                        .add => af + bf,
                        .sub => af - bf,
                        .mul => af * bf,
                        .div => if (bf == 0) return error.DivisionByZero else af / bf,
                        .rem => if (bf == 0) return error.DivisionByZero else @rem(af, bf),
                        .quot => if (bf == 0) return error.DivisionByZero else @trunc(af / bf),
                        .mod => if (bf == 0) return error.DivisionByZero else blk: {
                            const q = @floor(af / bf);
                            const r = af - q * bf;
                            break :blk r;
                        },
                        else => unreachable,
                    };
                    try stack.pushFloat(result);
                } else {
                    const a_val = a_entry.toValueConst();
                    const b_val = b_entry.toValueConst();
                    const result = try vmo.arithmeticOp(inst.opcode, a_val, b_val, allocator, env);
                    const result_ptr = try eval_mod.allocValue(allocator, result);
                    for ([_]StackEntry{ a_entry, b_entry }) |entry| {
                        vmt.freeEntry(entry, allocator);
                    }
                    try stack.pushPtr(result_ptr);
                }
            },

            .neg => {
                const entry = stack.pop() orelse return error.BytecodeError;
                if (entry.numericTag() == .integer) {
                    const v = try entry.toInteger();
                    try stack.pushInt(-v);
                } else if (entry.numericTag() == .float) {
                    const v = try entry.toFloat();
                    try stack.pushFloat(-v);
                } else {
                    const val = entry.toValueConst();
                    const result = try vmo.negateOp(val, allocator);
                    const result_ptr = try eval_mod.allocValue(allocator, result);
                    vmt.freeEntry(entry, allocator);
                    try stack.pushPtr(result_ptr);
                }
            },

            .is_nil => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const is_nil = entry.isNil();
                const result = try eval_mod.allocValue(allocator, vm.boolValue(is_nil));
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result);
            },
            .is_truthy => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const truthy = entry.isTruthy();
                const result = try eval_mod.allocValue(allocator, vm.boolValue(truthy));
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result);
            },
            .not => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const truthy = entry.isTruthy();
                const result = try eval_mod.allocValue(allocator, vm.boolValue(!truthy));
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result);
            },

            .is_number, .is_int, .is_float, .is_string, .is_boolean,
            .is_list, .is_vector, .is_map, .is_set, .is_symbol, .is_keyword => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const val = entry.toValueConst();
                const result = vmo.vmTypeCheck(inst.opcode, val);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .cons => {
                const head_entry = stack.pop() orelse return error.BytecodeError;
                const tail_entry = stack.pop() orelse return error.BytecodeError;
                const head_val = head_entry.toValueConst();
                const tail_val = tail_entry.toValueConst();
                const cons_val = try vm.consValue(allocator, head_val, tail_val);
                const cons_ptr = try eval_mod.allocValue(allocator, cons_val);
                vmt.freeEntry(head_entry, allocator);
                vmt.freeEntry(tail_entry, allocator);
                try stack.pushPtr(cons_ptr);
            },

            .list_n => {
                const n = inst.operand;
                var temp_items: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_items.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_items.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const item_entry = stack.pop() orelse return error.BytecodeError;
                    try temp_items.append(allocator, item_entry);
                }
                var l: list.List = .empty;
                errdefer l.deinit(allocator);
                var j: usize = temp_items.items.len;
                while (j > 0) : (j -= 1) {
                    const item_entry = temp_items.items[j - 1];
                    const item_val = item_entry.toValueConst();
                    try l.append(allocator, try vm.shallowClone(&item_val, allocator));
                }
                for (temp_items.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_items.items);
                const list_val = try vm.listValue(allocator, l);
                const list_ptr = try eval_mod.allocValue(allocator, list_val);
                try stack.pushPtr(list_ptr);
            },

            .vector_n => {
                const n = inst.operand;
                var temp_items: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_items.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_items.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const item_entry = stack.pop() orelse return error.BytecodeError;
                    try temp_items.append(allocator, item_entry);
                }
                var v: vec.Vector = .empty;
                errdefer v.deinit(allocator);
                var j: usize = temp_items.items.len;
                while (j > 0) : (j -= 1) {
                    const item_entry = temp_items.items[j - 1];
                    const item_val = item_entry.toValueConst();
                    try v.append(allocator, try vm.shallowClone(&item_val, allocator));
                }
                for (temp_items.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_items.items);
                const vec_val = try vm.vectorValue(allocator, v);
                const vec_ptr = try eval_mod.allocValue(allocator, vec_val);
                try stack.pushPtr(vec_ptr);
            },

            .ret => {
                const entry = stack.pop() orelse return error.BytecodeError;
                stack.deinit();
                const result = try entry.toValue(allocator);
                return .{ .value = result };
            },
            .stop => {
                const entry = stack.pop() orelse {
                    stack.deinit();
                    return .{ .value = try eval_mod.allocValue(allocator, vm.nilValue()) };
                };
                stack.deinit();
                const result = try entry.toValue(allocator);
                return .{ .value = result };
            },

            .source_marker, .nop => {},

            .first => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmFirst(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },
            .rest => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmRest(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },
            .count => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmCount(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .map_n => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_entries.items); }
                var i: usize = 0;
                while (i < n * 2) : (i += 1) {
                    const entry_val = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_val);
                }
                var m: vm.Map = .empty;
                errdefer {
                    for (m.items) |*me| {
                        vm.valueDeinit(&me.key, allocator);
                        vm.valueDeinit(&me.value, allocator);
                    }
                    allocator.free(m.items);
                }
                var j: usize = temp_entries.items.len;
                while (j > 1) : (j -= 2) {
                    const key_entry = temp_entries.items[j - 1];
                    const val_entry = temp_entries.items[j - 2];
                    const key_val = key_entry.toValueConst();
                    const val_val = val_entry.toValueConst();
                    try m.append(allocator, .{
                        .key = try vm.shallowClone(&key_val, allocator),
                        .value = try vm.shallowClone(&val_val, allocator),
                    });
                }
                for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_entries.items);
                const map_val = try vm.mapValue(allocator, m);
                const map_ptr = try eval_mod.allocValue(allocator, map_val);
                try stack.pushPtr(map_ptr);
            },

            .get => {
                const key_entry = stack.pop() orelse return error.BytecodeError;
                const coll_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmGet(allocator, coll_entry.toValueConst(), key_entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(key_entry, allocator);
                vmt.freeEntry(coll_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .assoc => {
                const val_entry = stack.pop() orelse return error.BytecodeError;
                const key_entry = stack.pop() orelse return error.BytecodeError;
                const map_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmAssoc(allocator, map_entry.toValueConst(), key_entry.toValueConst(), val_entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(val_entry, allocator);
                vmt.freeEntry(key_entry, allocator);
                vmt.freeEntry(map_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .conj => {
                const item_entry = stack.pop() orelse return error.BytecodeError;
                const coll_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmConj(allocator, coll_entry.toValueConst(), item_entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(item_entry, allocator);
                vmt.freeEntry(coll_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .nth => {
                const idx_entry = stack.pop() orelse return error.BytecodeError;
                const coll_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmNth(allocator, coll_entry.toValueConst(), idx_entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(idx_entry, allocator);
                vmt.freeEntry(coll_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .seq => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmSeq(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .is_empty => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmIsEmpty(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .is_not_empty => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmIsNotEmpty(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .make_empty => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmMakeEmpty(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .contains => {
                const key_entry = stack.pop() orelse return error.BytecodeError;
                const coll_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmContains(allocator, coll_entry.toValueConst(), key_entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(key_entry, allocator);
                vmt.freeEntry(coll_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .str_n => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_entries.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const entry_val = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_val);
                }
                // Reverse to get original argument order
                var values: std.ArrayListUnmanaged(Value) = .empty;
                errdefer { for (values.items) |*v| vm.valueDeinit(v, allocator); allocator.free(values.items); }
                var j: usize = temp_entries.items.len;
                while (j > 0) : (j -= 1) {
                    const entry = temp_entries.items[j - 1];
                    const val = entry.toValueConst();
                    try values.append(allocator, try vm.shallowClone(&val, allocator));
                }
                for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_entries.items);
                const result = try vmo.vmStrN(allocator, values.items);
                for (values.items) |*v| vm.valueDeinit(v, allocator);
                allocator.free(values.items);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                try stack.pushPtr(result_ptr);
            },

            .deref => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmDeref(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            .quote => {
                const idx = inst.operand;
                if (idx >= program.constants.items.len) return error.BytecodeError;
                const val = try vm.cloneGC(&program.constants.items[idx], allocator);
                try stack.pushPtr(val);
            },

            .loop_start => {
                const loop_info_idx = inst.operand;
                if (loop_info_idx >= program.loop_infos.items.len) return error.BytecodeError;
                const info = program.loop_infos.items[loop_info_idx];
                const binding_count = info.binding_sym_indices.len;
                const frame = try allocator.create(LoopFrame);
                const bvals = try allocator.alloc(StackEntry, binding_count);
                var bi: usize = 0;
                while (bi < binding_count) : (bi += 1) {
                    const sym_name = program.symbols.items[info.binding_sym_indices[bi]];
                    const val = try vmo.resolveSymbol(env, sym_name);
                    bvals[bi] = switch (val) {
                        .integer => StackEntry{ .integer = val.integer },
                        .float => StackEntry{ .float = val.float },
                        else => StackEntry{ .pointer = try vm.cloneGC(&val, allocator) },
                    };
                }
                frame.* = .{
                    .loop_pc = pc - 1,
                    .body_pc = info.body_pc,
                    .binding_count = binding_count,
                    .binding_sym_indices = info.binding_sym_indices,
                    .binding_values = bvals,
                };
                try loop_stack.append(allocator, frame);
            },

            .recur => {
                if (loop_stack.items.len == 0) return error.BytecodeError;
                const frame = loop_stack.items[loop_stack.items.len - 1];
                const count = frame.binding_count;
                var temp_vals: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_vals.items) |ae| vmt.freeEntry(ae, allocator); temp_vals.deinit(allocator); }
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const val_entry = stack.pop() orelse return error.BytecodeError;
                    try temp_vals.append(allocator, val_entry);
                }
                var j: usize = temp_vals.items.len;
                while (j > 0) : (j -= 1) {
                    const val_entry = temp_vals.items[j - 1];
                    const old_entry = frame.binding_values[j - 1];
                    vmt.freeEntry(old_entry, allocator);
                    frame.binding_values[j - 1] = val_entry;
                }
                // IMPORTANT: Do NOT call freeEntry on temp_vals entries here.
                // The StackEntry values were MOVED (copied by value) to frame.binding_values.
                // For pointer entries, both temp_vals and binding_values share the same *Value.
                // Calling freeEntry would null out the *Value, corrupting the binding.
                // The GC allocator's free is a no-op anyway, but valueDeinit would still
                // null out the Value, breaking the shared pointer.
                // Just zero out the StackEntry slots and free the buffer.
                for (temp_vals.items) |*ae| ae.* = StackEntry{ .integer = 0 };
                temp_vals.deinit(allocator);
                pc = frame.body_pc;
            },

            .make_fn => {
                const idx = inst.operand;
                const fn_meta = fn_pool.?[idx];
                const fn_val = try vmo.vmMakeFn(allocator, fn_meta, env);
                const fn_ptr = try eval_mod.allocValue(allocator, fn_val);
                try stack.pushPtr(fn_ptr);
            },

            // Phase 12: peek/pop
            .peek => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmPeek(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },
            .pop => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmPop(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 13: reduced ops
            .make_reduced => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmMakeReduced(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },
            .is_reduced => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmIsReduced(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },
            .unreduced => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmUnreduced(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 14: meta ops
            .get_meta => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmGetMeta(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },
            .set_meta => {
                const meta_entry = stack.pop() orelse return error.BytecodeError;
                const val_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmSetMeta(allocator, val_entry.toValueConst(), meta_entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(meta_entry, allocator);
                vmt.freeEntry(val_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 15: keyword/symbol constructors
            .make_keyword => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_entries.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const entry_val = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_val);
                }
                var parts: std.ArrayListUnmanaged(Value) = .empty;
                errdefer { for (parts.items) |*v| vm.valueDeinit(v, allocator); allocator.free(parts.items); }
                var j: usize = temp_entries.items.len;
                while (j > 0) : (j -= 1) {
                    const entry = temp_entries.items[j - 1];
                    const val = entry.toValueConst();
                    try parts.append(allocator, try vm.shallowClone(&val, allocator));
                }
                for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_entries.items);
                const result = try vmo.vmMakeKeyword(allocator, parts.items);
                for (parts.items) |*v| vm.valueDeinit(v, allocator);
                allocator.free(parts.items);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                try stack.pushPtr(result_ptr);
            },
            .make_symbol => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_entries.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const entry_val = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_val);
                }
                var parts: std.ArrayListUnmanaged(Value) = .empty;
                errdefer { for (parts.items) |*v| vm.valueDeinit(v, allocator); allocator.free(parts.items); }
                var j: usize = temp_entries.items.len;
                while (j > 0) : (j -= 1) {
                    const entry = temp_entries.items[j - 1];
                    const val = entry.toValueConst();
                    try parts.append(allocator, try vm.shallowClone(&val, allocator));
                }
                for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_entries.items);
                const result = try vmo.vmMakeSymbol(allocator, parts.items);
                for (parts.items) |*v| vm.valueDeinit(v, allocator);
                allocator.free(parts.items);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                try stack.pushPtr(result_ptr);
            },

            // Phase 4: range
            .range => {
                const n = inst.operand;
                var temp_args: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_args.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_args.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const arg_entry = stack.pop() orelse return error.BytecodeError;
                    try temp_args.append(allocator, arg_entry);
                }
                var vals: std.ArrayListUnmanaged(Value) = .empty;
                errdefer { for (vals.items) |*v| vm.valueDeinit(v, allocator); allocator.free(vals.items); }
                var j: usize = temp_args.items.len;
                while (j > 0) : (j -= 1) {
                    const arg_entry = temp_args.items[j - 1];
                    const val = arg_entry.toValueConst();
                    try vals.append(allocator, try vm.shallowClone(&val, allocator));
                }
                for (temp_args.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_args.items);
                const result = try vmo.vmRange(allocator, vals.items, env);
                for (vals.items) |*v| vm.valueDeinit(v, allocator);
                allocator.free(vals.items);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                try stack.pushPtr(result_ptr);
            },

            // Phase 4: vec
            .vec => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmVec(allocator, entry.toValueConst());
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 5: sort
            .sort => {
                const entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmSort(allocator, entry.toValueConst(), env);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 5: sort_by
            .sort_by => {
                const coll_entry = stack.pop() orelse return error.BytecodeError;
                const fn_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmSortBy(allocator, fn_entry.toValueConst(), coll_entry.toValueConst(), env);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(fn_entry, allocator);
                vmt.freeEntry(coll_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 5: merge
            .merge => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_entries.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const entry_val = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_val);
                }
                var vals: std.ArrayListUnmanaged(Value) = .empty;
                errdefer { for (vals.items) |*v| vm.valueDeinit(v, allocator); allocator.free(vals.items); }
                var j: usize = temp_entries.items.len;
                while (j > 0) : (j -= 1) {
                    const entry = temp_entries.items[j - 1];
                    const val = entry.toValueConst();
                    try vals.append(allocator, try vm.shallowClone(&val, allocator));
                }
                for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_entries.items);
                const result = try vmo.vmMerge(allocator, vals.items);
                for (vals.items) |*v| vm.valueDeinit(v, allocator);
                allocator.free(vals.items);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                try stack.pushPtr(result_ptr);
            },

            // Phase 6: map_fn
            .map_fn => {
                const coll_entry = stack.pop() orelse return error.BytecodeError;
                const fn_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmMapFn(allocator, fn_entry.toValueConst(), coll_entry.toValueConst(), env);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(fn_entry, allocator);
                vmt.freeEntry(coll_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 6: reduce_fn
            .reduce_fn => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_entries.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const entry_val = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_val);
                }
                var vals: std.ArrayListUnmanaged(Value) = .empty;
                errdefer { for (vals.items) |*v| vm.valueDeinit(v, allocator); allocator.free(vals.items); }
                var j: usize = temp_entries.items.len;
                while (j > 0) : (j -= 1) {
                    const entry = temp_entries.items[j - 1];
                    const val = entry.toValueConst();
                    try vals.append(allocator, try vm.shallowClone(&val, allocator));
                }
                for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_entries.items);
                const result = try vmo.vmReduceFn(allocator, vals.items, env);
                for (vals.items) |*v| vm.valueDeinit(v, allocator);
                allocator.free(vals.items);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                try stack.pushPtr(result_ptr);
            },

            // Phase 7: apply_fn
            .apply_fn => {
                const coll_entry = stack.pop() orelse return error.BytecodeError;
                const fn_entry = stack.pop() orelse return error.BytecodeError;
                const result = try vmo.vmApplyFn(allocator, fn_entry.toValueConst(), coll_entry.toValueConst(), env);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vmt.freeEntry(fn_entry, allocator);
                vmt.freeEntry(coll_entry, allocator);
                try stack.pushPtr(result_ptr);
            },

            // Phase 9: concat_n
            .concat_n => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(StackEntry) = .empty;
                errdefer { for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator); allocator.free(temp_entries.items); }
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const entry_val = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_val);
                }
                var vals: std.ArrayListUnmanaged(Value) = .empty;
                errdefer { for (vals.items) |*v| vm.valueDeinit(v, allocator); allocator.free(vals.items); }
                var j: usize = temp_entries.items.len;
                while (j > 0) : (j -= 1) {
                    const entry = temp_entries.items[j - 1];
                    const val = entry.toValueConst();
                    try vals.append(allocator, try vm.shallowClone(&val, allocator));
                }
                for (temp_entries.items) |ae| vmt.freeEntry(ae, allocator);
                allocator.free(temp_entries.items);
                const result = try vmo.vmConcat(allocator, vals.items, env);
                for (vals.items) |*v| vm.valueDeinit(v, allocator);
                allocator.free(vals.items);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                try stack.pushPtr(result_ptr);
            },

            // Phase 10: make_lazy_seq
            .make_lazy_seq => {
                const bc_idx = inst.operand;
                if (bc_idx >= program.lazy_seq_bytecodes.items.len) return error.BytecodeError;
                const bc_prog = program.lazy_seq_bytecodes.items[bc_idx];
                const lazy_val = try vmo.vmMakeLazySeq(allocator, bc_prog, env);
                const lazy_ptr = try eval_mod.allocValue(allocator, lazy_val);
                try stack.pushPtr(lazy_ptr);
            },
        }
    }

    // Fell off the end — return nil
    stack.deinit();
    return .{ .value = try eval_mod.allocValue(allocator, vm.nilValue()) };
}
