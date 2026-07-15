// Bytecode tests — compiled into bytecode.zig via the _tests import.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const eval_mod = @import("../eval.zig");
const gc_mod = @import("../gc.zig");
const phm = @import("../persistent_hash_map.zig");
const BI = @import("../big_int.zig");
const arithmetic = @import("../namespaces/core/arithmetic.zig");
const bc = @import("instructions.zig");
const vmt = @import("vm_types.zig");
const vm_mod = @import("vm.zig");
const compiler = @import("compiler.zig");
const ch = @import("compiler_helpers.zig");

const OpCode = bc.OpCode;
const BytecodeProgram = bc.BytecodeProgram;
const VMResult = vmt.VMResult;
const compile = compiler.compile;
const execute = vm_mod.execute;
const containsRealFunctionCallsInList = ch.containsRealFunctionCallsInList;
const containsUnhandledSpecialFormInList = ch.containsUnhandledSpecialFormInList;
const isBytecodeSpecialForm = ch.isBytecodeSpecialForm;

const Allocator = std.mem.Allocator;

const TestGC = struct {
    gc: gc_mod.GC,

    pub fn init() TestGC {
        return .{
            .gc = gc_mod.GC.init(std.testing.allocator),
        };
    }

    pub fn allocator(self: *TestGC) Allocator {
        return self.gc.allocator();
    }

    pub fn deinit(self: *TestGC) void {
        self.gc.freeAllBlocks();
    }
};

fn createTestEnv(allocator: Allocator) vm.Env {
    return .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = null,
        .ns_manager = null,
        .referred_names = .empty,
    };
}

fn createTestEnvWithArithmetic(allocator: Allocator) vm.Env {
    var env = createTestEnv(allocator);
    env.put("+", vm.builtinFnValue(arithmetic.core_plus)) catch unreachable;
    env.put("-", vm.builtinFnValue(arithmetic.core_minus)) catch unreachable;
    env.put("*", vm.builtinFnValue(arithmetic.core_mult)) catch unreachable;
    env.put("/", vm.builtinFnValue(arithmetic.core_div)) catch unreachable;
    env.put("rem", vm.builtinFnValue(arithmetic.core_rem)) catch unreachable;
    return env;
}

test "bytecode::opCodeName: returns string for each opcode" {
    _ = BytecodeProgram.opcodeName(.push_nil);
    _ = BytecodeProgram.opcodeName(.call_n);
    _ = BytecodeProgram.opcodeName(.ret);
    _ = BytecodeProgram.opcodeName(.nop);
}

test "bytecode::program: init and deinit" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit0(allocator, .push_nil);
    _ = try program.emit0(allocator, .ret);
}

test "bytecode::vm: push and return" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    _ = try program.emit(allocator, .push_int, 42);
    _ = try program.emit0(allocator, .ret);

    var env: vm.Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = null,
        .ns_manager = null,
        .referred_names = .empty,
    };
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 42);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: literal nil" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit0(allocator, .push_nil);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .nil);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: literal integer" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit(allocator, .push_int, 123);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 123);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: literal boolean" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit0(allocator, .push_true);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .bool);
            try std.testing.expect(v.*.bool == true);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: variable reference" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    const sym_idx = try program.addSymbol(allocator, "x");
    _ = try program.emit(allocator, .load_var, sym_idx);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    try env.put("x", vm.intValue(99));

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 99);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: if true branch" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    _ = try program.emit0(allocator, .push_true);
    const jump_nil_pc = try program.emit(allocator, .jump_if_nil, 0);
    const one_idx = try program.addConstant(allocator, vm.intValue(1));
    _ = try program.emit(allocator, .push_const, one_idx);
    const jump_end_pc = try program.emit(allocator, .jump, 0);
    const else_pc = program.instructions.items.len;
    program.instructions.items[jump_nil_pc].operand = else_pc;
    const two_idx = try program.addConstant(allocator, vm.intValue(2));
    _ = try program.emit(allocator, .push_const, two_idx);
    const end_pc = program.instructions.items.len;
    program.instructions.items[jump_end_pc].operand = end_pc;
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 1);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: if nil branch" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    _ = try program.emit0(allocator, .push_nil);
    const jump_nil_pc = try program.emit(allocator, .jump_if_nil, 0);
    const one_idx = try program.addConstant(allocator, vm.intValue(1));
    _ = try program.emit(allocator, .push_const, one_idx);
    const jump_end_pc = try program.emit(allocator, .jump, 0);
    const else_pc = program.instructions.items.len;
    program.instructions.items[jump_nil_pc].operand = else_pc;
    const two_idx = try program.addConstant(allocator, vm.intValue(2));
    _ = try program.emit(allocator, .push_const, two_idx);
    const end_pc = program.instructions.items.len;
    program.instructions.items[jump_end_pc].operand = end_pc;
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 2);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: store and load variable" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const sym_idx = try program.addSymbol(allocator, "x");
    const val_idx = try program.addConstant(allocator, vm.intValue(42));
    _ = try program.emit(allocator, .push_const, val_idx);
    _ = try program.emit(allocator, .store_var, sym_idx);
    _ = try program.emit(allocator, .load_var, sym_idx);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 42);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::arithmetic: bigint add" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const bi1 = try BI.bigIntFromString(allocator, "9223372036854775807");
    const bi1_val = try vm.bigIntValue(allocator, bi1);
    const bi2 = try BI.bigIntFromString(allocator, "9223372036854775807");
    const bi2_val = try vm.bigIntValue(allocator, bi2);
    const idx1 = try program.addConstant(allocator, bi1_val);
    const idx2 = try program.addConstant(allocator, bi2_val);
    _ = try program.emit(allocator, .push_const, idx1);
    _ = try program.emit(allocator, .push_const, idx2);
    _ = try program.emit0(allocator, .add);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnvWithArithmetic(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .bigint);
            const result_str = try v.*.bigint.toString(allocator);
            defer allocator.free(result_str);
            try std.testing.expectEqualStrings("18446744073709551614", result_str);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::arithmetic: bigint sub" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const bi1 = try BI.bigIntFromString(allocator, "10000000000000000000");
    const bi1_val = try vm.bigIntValue(allocator, bi1);
    const bi2 = try BI.bigIntFromString(allocator, "42");
    const bi2_val = try vm.bigIntValue(allocator, bi2);
    const idx1 = try program.addConstant(allocator, bi1_val);
    const idx2 = try program.addConstant(allocator, bi2_val);
    _ = try program.emit(allocator, .push_const, idx1);
    _ = try program.emit(allocator, .push_const, idx2);
    _ = try program.emit0(allocator, .sub);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnvWithArithmetic(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .bigint);
            const result_str = try v.*.bigint.toString(allocator);
            defer allocator.free(result_str);
            try std.testing.expectEqualStrings("9999999999999999958", result_str);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::arithmetic: bigint mul" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const bi1 = try BI.bigIntFromString(allocator, "1000000000000000000");
    const bi1_val = try vm.bigIntValue(allocator, bi1);
    const bi2 = try BI.bigIntFromString(allocator, "1000000000000000000");
    const bi2_val = try vm.bigIntValue(allocator, bi2);
    const idx1 = try program.addConstant(allocator, bi1_val);
    const idx2 = try program.addConstant(allocator, bi2_val);
    _ = try program.emit(allocator, .push_const, idx1);
    _ = try program.emit(allocator, .push_const, idx2);
    _ = try program.emit0(allocator, .mul);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnvWithArithmetic(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .bigint);
            const result_str = try v.*.bigint.toString(allocator);
            defer allocator.free(result_str);
            try std.testing.expectEqualStrings("1000000000000000000000000000000000000", result_str);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::arithmetic: mixed int+bigint add" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const int_val = vm.intValue(42);
    const bi = try BI.bigIntFromString(allocator, "12345678901234567890");
    const bi_val = try vm.bigIntValue(allocator, bi);
    const idx1 = try program.addConstant(allocator, int_val);
    const idx2 = try program.addConstant(allocator, bi_val);
    _ = try program.emit(allocator, .push_const, idx1);
    _ = try program.emit(allocator, .push_const, idx2);
    _ = try program.emit0(allocator, .add);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnvWithArithmetic(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .bigint);
            const result_str = try v.*.bigint.toString(allocator);
            defer allocator.free(result_str);
            try std.testing.expectEqualStrings("12345678901234567932", result_str);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::arithmetic: int+float add" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const int_val = vm.intValue(3);
    const float_val = vm.floatValue(1.5);
    const idx1 = try program.addConstant(allocator, int_val);
    const idx2 = try program.addConstant(allocator, float_val);
    _ = try program.emit(allocator, .push_const, idx1);
    _ = try program.emit(allocator, .push_const, idx2);
    _ = try program.emit0(allocator, .add);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .float);
            try std.testing.expect(v.*.float == 4.5);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::negate: integer" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const val_idx = try program.addConstant(allocator, vm.intValue(42));
    _ = try program.emit(allocator, .push_const, val_idx);
    _ = try program.emit0(allocator, .neg);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == -42);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::negate: float" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const val_idx = try program.addConstant(allocator, vm.floatValue(3.14));
    _ = try program.emit(allocator, .push_const, val_idx);
    _ = try program.emit0(allocator, .neg);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .float);
            try std.testing.expect(v.*.float == -3.14);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::negate: bigint" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const bi = BI.bigIntFromI64(allocator, 123456789012345678);
    const bi_val = try vm.bigIntValue(allocator, bi);
    const idx = try program.addConstant(allocator, bi_val);
    _ = try program.emit(allocator, .push_const, idx);
    _ = try program.emit0(allocator, .neg);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .bigint);
            const result_str = try v.*.bigint.toString(allocator);
            defer allocator.free(result_str);
            try std.testing.expectEqualStrings("-123456789012345678", result_str);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::loop_recur: simple counter" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const sym_i = try program.addSymbol(allocator, "i");

    const zero_idx = try program.addConstant(allocator, vm.intValue(0));
    _ = try program.emit(allocator, .push_const, zero_idx);
    _ = try program.emit(allocator, .store_var, sym_i);

    const sym_indices = try allocator.alloc(usize, 1);
    sym_indices[0] = sym_i;
    const loop_idx = try program.addLoopInfo(allocator, program.instructions.items.len + 1, sym_indices);
    _ = try program.emit(allocator, .loop_start, loop_idx);

    _ = try program.emit(allocator, .load_var, sym_i);
    const five_idx = try program.addConstant(allocator, vm.intValue(5));
    _ = try program.emit(allocator, .push_const, five_idx);
    _ = try program.emit0(allocator, .ge);
    const jump_nil_pc = try program.emit(allocator, .jump_if_nil, 0);
    _ = try program.emit(allocator, .load_var, sym_i);
    const jump_end_pc = try program.emit(allocator, .jump, 0);

    const recur_pc = program.instructions.items.len;
    program.instructions.items[jump_nil_pc].operand = recur_pc;
    _ = try program.emit(allocator, .load_var, sym_i);
    const one_idx = try program.addConstant(allocator, vm.intValue(1));
    _ = try program.emit(allocator, .push_const, one_idx);
    _ = try program.emit0(allocator, .add);
    _ = try program.emit0(allocator, .recur);

    const end_pc = program.instructions.items.len;
    program.instructions.items[jump_end_pc].operand = end_pc;
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 5);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::loop_recur: accumulator" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const sym_i = try program.addSymbol(allocator, "i");
    const sym_s = try program.addSymbol(allocator, "s");

    const three_idx = try program.addConstant(allocator, vm.intValue(3));
    _ = try program.emit(allocator, .push_const, three_idx);
    _ = try program.emit(allocator, .store_var, sym_i);
    const zero_idx = try program.addConstant(allocator, vm.intValue(0));
    _ = try program.emit(allocator, .push_const, zero_idx);
    _ = try program.emit(allocator, .store_var, sym_s);

    const sym_indices = try allocator.alloc(usize, 2);
    sym_indices[0] = sym_i;
    sym_indices[1] = sym_s;
    const loop_idx = try program.addLoopInfo(allocator, program.instructions.items.len + 1, sym_indices);
    _ = try program.emit(allocator, .loop_start, loop_idx);

    _ = try program.emit(allocator, .load_var, sym_i);
    _ = try program.emit(allocator, .push_const, zero_idx);
    _ = try program.emit0(allocator, .le);
    const jump_nil_pc = try program.emit(allocator, .jump_if_nil, 0);
    _ = try program.emit(allocator, .load_var, sym_s);
    const jump_end_pc = try program.emit(allocator, .jump, 0);

    const recur_pc = program.instructions.items.len;
    program.instructions.items[jump_nil_pc].operand = recur_pc;
    const one_idx = try program.addConstant(allocator, vm.intValue(1));
    _ = try program.emit(allocator, .load_var, sym_s);
    _ = try program.emit(allocator, .load_var, sym_i);
    _ = try program.emit0(allocator, .add);
    _ = try program.emit(allocator, .load_var, sym_i);
    _ = try program.emit(allocator, .push_const, one_idx);
    _ = try program.emit0(allocator, .sub);
    _ = try program.emit0(allocator, .recur);

    const end_pc = program.instructions.items.len;
    program.instructions.items[jump_end_pc].operand = end_pc;
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 6);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: add opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "+"));
    try body.append(allocator, vm.intValue(3));
    try body.append(allocator, vm.intValue(4));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);

    try std.testing.expect(program.instructions.items.len == 4);
    try std.testing.expect(program.instructions.items[2].opcode == .add);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 7);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: sub opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "-"));
    try body.append(allocator, vm.intValue(10));
    try body.append(allocator, vm.intValue(3));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items[2].opcode == .sub);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.integer == 7);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: mul opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "*"));
    try body.append(allocator, vm.intValue(6));
    try body.append(allocator, vm.intValue(7));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items[2].opcode == .mul);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.integer == 42);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: div opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "/"));
    try body.append(allocator, vm.intValue(20));
    try body.append(allocator, vm.intValue(4));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items[2].opcode == .div);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.integer == 5);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: rem opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "rem"));
    try body.append(allocator, vm.intValue(17));
    try body.append(allocator, vm.intValue(5));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items[2].opcode == .rem);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.integer == 2);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: neg single arg" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "-"));
    try body.append(allocator, vm.intValue(42));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items.len == 3);
    try std.testing.expect(program.instructions.items[1].opcode == .neg);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.integer == -42);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: eq opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "="));
    try body.append(allocator, vm.intValue(5));
    try body.append(allocator, vm.intValue(5));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items[2].opcode == .eq);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .bool);
            try std.testing.expect(v.*.bool == true);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: not opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    {
        var body: list.List = .empty;
        defer body.deinit(allocator);
        try body.append(allocator, try vm.symValue(allocator, "not"));
        try body.append(allocator, vm.boolValue(true));
        var ast: list.List = .empty;
        defer ast.deinit(allocator);
        try ast.append(allocator, try vm.symValue(allocator, "do"));
        try ast.append(allocator, try vm.listValue(allocator, body));
        var program = try compile(allocator, ast, "<test>", null);
        defer program.deinit(allocator);
        try std.testing.expect(program.instructions.items[1].opcode == .not);
        const result = try execute(allocator, &program, &env);
        switch (result) {
            .value => |v| {
                try std.testing.expect(v.*.bool == false);
                vm.valueDeinit(v, allocator);
                allocator.destroy(v);
            },
            .trampoline => unreachable,
        }
    }

    {
        var body: list.List = .empty;
        defer body.deinit(allocator);
        try body.append(allocator, try vm.symValue(allocator, "not"));
        try body.append(allocator, vm.nilValue());
        var ast: list.List = .empty;
        defer ast.deinit(allocator);
        try ast.append(allocator, try vm.symValue(allocator, "do"));
        try ast.append(allocator, try vm.listValue(allocator, body));
        var program = try compile(allocator, ast, "<test>", null);
        defer program.deinit(allocator);
        try std.testing.expect(program.instructions.items[1].opcode == .not);
        const result = try execute(allocator, &program, &env);
        switch (result) {
            .value => |v| {
                try std.testing.expect(v.*.bool == true);
                vm.valueDeinit(v, allocator);
                allocator.destroy(v);
            },
            .trampoline => unreachable,
        }
    }

    {
        var body: list.List = .empty;
        defer body.deinit(allocator);
        try body.append(allocator, try vm.symValue(allocator, "not"));
        try body.append(allocator, vm.intValue(42));
        var ast: list.List = .empty;
        defer ast.deinit(allocator);
        try ast.append(allocator, try vm.symValue(allocator, "do"));
        try ast.append(allocator, try vm.listValue(allocator, body));
        var program = try compile(allocator, ast, "<test>", null);
        defer program.deinit(allocator);
        const result = try execute(allocator, &program, &env);
        switch (result) {
            .value => |v| {
                try std.testing.expect(v.*.bool == false);
                vm.valueDeinit(v, allocator);
                allocator.destroy(v);
            },
            .trampoline => unreachable,
        }
    }
}

test "bytecode::compile: multi-arg arithmetic" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "+"));
    try body.append(allocator, vm.intValue(1));
    try body.append(allocator, vm.intValue(2));
    try body.append(allocator, vm.intValue(3));
    try body.append(allocator, vm.intValue(4));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items.len == 8);
    try std.testing.expect(program.instructions.items[2].opcode == .add);
    try std.testing.expect(program.instructions.items[4].opcode == .add);
    try std.testing.expect(program.instructions.items[6].opcode == .add);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.integer == 10);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: multi-arg sub" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "-"));
    try body.append(allocator, vm.intValue(10));
    try body.append(allocator, vm.intValue(3));
    try body.append(allocator, vm.intValue(2));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items.len == 6);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.integer == 5);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: 2-arg eq" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "="));
    try body.append(allocator, vm.intValue(3));
    try body.append(allocator, vm.intValue(3));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);
    try std.testing.expect(program.instructions.items[2].opcode == .eq);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(v.*.bool == true);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: ne/not= opcode emission" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    {
        var body: list.List = .empty;
        defer body.deinit(allocator);
        try body.append(allocator, try vm.symValue(allocator, "!="));
        try body.append(allocator, vm.intValue(3));
        try body.append(allocator, vm.intValue(5));
        var ast: list.List = .empty;
        defer ast.deinit(allocator);
        try ast.append(allocator, try vm.symValue(allocator, "do"));
        try ast.append(allocator, try vm.listValue(allocator, body));
        var program = try compile(allocator, ast, "<test>", null);
        defer program.deinit(allocator);
        try std.testing.expect(program.instructions.items[2].opcode == .ne);
        const result = try execute(allocator, &program, &env);
        switch (result) {
            .value => |v| {
                try std.testing.expect(v.*.bool == true);
                vm.valueDeinit(v, allocator);
                allocator.destroy(v);
            },
            .trampoline => unreachable,
        }
    }

    {
        var body: list.List = .empty;
        defer body.deinit(allocator);
        try body.append(allocator, try vm.symValue(allocator, "not="));
        try body.append(allocator, vm.intValue(3));
        try body.append(allocator, vm.intValue(3));
        var ast: list.List = .empty;
        defer ast.deinit(allocator);
        try ast.append(allocator, try vm.symValue(allocator, "do"));
        try ast.append(allocator, try vm.listValue(allocator, body));
        var program = try compile(allocator, ast, "<test>", null);
        defer program.deinit(allocator);
        try std.testing.expect(program.instructions.items[2].opcode == .ne);
        const result = try execute(allocator, &program, &env);
        switch (result) {
            .value => |v| {
                try std.testing.expect(v.*.bool == false);
                vm.valueDeinit(v, allocator);
                allocator.destroy(v);
            },
            .trampoline => unreachable,
        }
    }
}

test "bytecode::containsRealFunctionCalls: arithmetic is safe" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    defer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "+"));
    try body.append(allocator, try vm.symValue(allocator, "a"));
    try body.append(allocator, try vm.symValue(allocator, "b"));
    try std.testing.expect(!containsRealFunctionCallsInList(body));

    var body2: list.List = .empty;
    defer body2.deinit(allocator);
    try body2.append(allocator, try vm.symValue(allocator, "="));
    try body2.append(allocator, try vm.symValue(allocator, "a"));
    try body2.append(allocator, try vm.symValue(allocator, "b"));
    try std.testing.expect(!containsRealFunctionCallsInList(body2));

    var body3: list.List = .empty;
    defer body3.deinit(allocator);
    try body3.append(allocator, try vm.symValue(allocator, "not"));
    try body3.append(allocator, try vm.symValue(allocator, "x"));
    try std.testing.expect(!containsRealFunctionCallsInList(body3));

    var call4: list.List = .empty;
    defer call4.deinit(allocator);
    try call4.append(allocator, try vm.symValue(allocator, "foo"));
    try call4.append(allocator, try vm.symValue(allocator, "a"));
    const call4_val = try vm.listValue(allocator, call4);
    var body4: list.List = .empty;
    defer body4.deinit(allocator);
    try body4.append(allocator, call4_val);
    try std.testing.expect(containsRealFunctionCallsInList(body4));
}

test "bytecode::containsRealFunctionCalls: nested arithmetic is safe" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var inner: list.List = .empty;
    defer inner.deinit(allocator);
    try inner.append(allocator, try vm.symValue(allocator, "*"));
    try inner.append(allocator, try vm.symValue(allocator, "a"));
    try inner.append(allocator, try vm.symValue(allocator, "b"));
    const inner_val = try vm.listValue(allocator, inner);

    var body: list.List = .empty;
    defer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "+"));
    try body.append(allocator, inner_val);
    try body.append(allocator, try vm.symValue(allocator, "c"));
    try std.testing.expect(!containsRealFunctionCallsInList(body));

    var inner2: list.List = .empty;
    defer inner2.deinit(allocator);
    try inner2.append(allocator, try vm.symValue(allocator, "foo"));
    try inner2.append(allocator, try vm.symValue(allocator, "a"));
    const inner2_val = try vm.listValue(allocator, inner2);

    var body2: list.List = .empty;
    defer body2.deinit(allocator);
    try body2.append(allocator, try vm.symValue(allocator, "+"));
    try body2.append(allocator, inner2_val);
    try body2.append(allocator, try vm.symValue(allocator, "b"));
    try std.testing.expect(containsRealFunctionCallsInList(body2));
}

test "bytecode::compile: case match first" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "case"));
    try body.append(allocator, vm.intValue(1));
    try body.append(allocator, vm.intValue(1));
    try body.append(allocator, try vm.stringValue(allocator, "one"));
    try body.append(allocator, vm.intValue(2));
    try body.append(allocator, try vm.stringValue(allocator, "two"));
    try body.append(allocator, try vm.keywordValue(allocator, "else"));
    try body.append(allocator, try vm.stringValue(allocator, "default"));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .string);
            try std.testing.expectEqualStrings("one", v.*.string);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: case match second" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "case"));
    try body.append(allocator, vm.intValue(2));
    try body.append(allocator, vm.intValue(1));
    try body.append(allocator, try vm.stringValue(allocator, "one"));
    try body.append(allocator, vm.intValue(2));
    try body.append(allocator, try vm.stringValue(allocator, "two"));
    try body.append(allocator, try vm.keywordValue(allocator, "else"));
    try body.append(allocator, try vm.stringValue(allocator, "default"));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .string);
            try std.testing.expectEqualStrings("two", v.*.string);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: case default" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "case"));
    try body.append(allocator, vm.intValue(3));
    try body.append(allocator, vm.intValue(1));
    try body.append(allocator, try vm.stringValue(allocator, "one"));
    try body.append(allocator, vm.intValue(2));
    try body.append(allocator, try vm.stringValue(allocator, "two"));
    try body.append(allocator, try vm.keywordValue(allocator, "else"));
    try body.append(allocator, try vm.stringValue(allocator, "default"));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .string);
            try std.testing.expectEqualStrings("default", v.*.string);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: case no match no default" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "case"));
    try body.append(allocator, vm.intValue(3));
    try body.append(allocator, vm.intValue(1));
    try body.append(allocator, try vm.stringValue(allocator, "one"));
    try body.append(allocator, vm.intValue(2));
    try body.append(allocator, try vm.stringValue(allocator, "two"));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .nil);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: case string match" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "case"));
    try body.append(allocator, try vm.stringValue(allocator, "a"));
    try body.append(allocator, try vm.stringValue(allocator, "a"));
    try body.append(allocator, try vm.keywordValue(allocator, "yes"));
    try body.append(allocator, try vm.stringValue(allocator, "b"));
    try body.append(allocator, try vm.keywordValue(allocator, "no"));
    try body.append(allocator, try vm.keywordValue(allocator, "else"));
    try body.append(allocator, try vm.keywordValue(allocator, "default"));
    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .keyword);
            try std.testing.expectEqualStrings("yes", v.*.keyword);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::compile: letfn compiles without crash" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var body: list.List = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, try vm.symValue(allocator, "letfn"));

    var arity_form: list.List = .empty;
    errdefer arity_form.deinit(allocator);
    var params_vec: vec.Vector = .empty;
    errdefer params_vec.deinit(allocator);
    try params_vec.append(allocator, try vm.symValue(allocator, "n"));
    try arity_form.append(allocator, try vm.vectorValue(allocator, params_vec));
    try arity_form.append(allocator, try vm.symValue(allocator, "n"));

    var fn_def: list.List = .empty;
    errdefer fn_def.deinit(allocator);
    try fn_def.append(allocator, try vm.symValue(allocator, "f"));
    try fn_def.append(allocator, try vm.listValue(allocator, arity_form));

    try body.append(allocator, try vm.listValue(allocator, fn_def));
    try body.append(allocator, vm.intValue(42));

    var ast: list.List = .empty;
    errdefer ast.deinit(allocator);
    try ast.append(allocator, try vm.symValue(allocator, "do"));
    try ast.append(allocator, try vm.listValue(allocator, body));

    var program = try compile(allocator, ast, "<test>", null);
    defer program.deinit(allocator);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    const result = try execute(allocator, &program, &env);
    switch (result) {
        .value => |v| {
            try std.testing.expect(std.meta.activeTag(v.*) == .integer);
            try std.testing.expect(v.*.integer == 42);
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
        .trampoline => unreachable,
    }
}

test "bytecode::isBytecodeSpecialForm: case and letfn" {
    try std.testing.expect(isBytecodeSpecialForm("case"));
    try std.testing.expect(isBytecodeSpecialForm("letfn"));
    try std.testing.expect(!isBytecodeSpecialForm("foo"));
}

test "bytecode::containsUnhandledSpecialForm: case and letfn not unhandled" {
    var test_gc = TestGC.init();
    defer test_gc.deinit();
    const allocator = test_gc.allocator();
    var case_body: list.List = .empty;
    defer case_body.deinit(allocator);
    try case_body.append(allocator, try vm.symValue(allocator, "case"));
    try case_body.append(allocator, vm.intValue(1));
    try case_body.append(allocator, vm.intValue(1));
    try case_body.append(allocator, vm.intValue(42));
    try std.testing.expect(!containsUnhandledSpecialFormInList(case_body));

    var letfn_body: list.List = .empty;
    defer letfn_body.deinit(allocator);
    try letfn_body.append(allocator, try vm.symValue(allocator, "letfn"));
    try letfn_body.append(allocator, try vm.listValue(allocator, list.empty()));
    try letfn_body.append(allocator, try vm.symValue(allocator, "f"));
    try std.testing.expect(!containsUnhandledSpecialFormInList(letfn_body));
}
