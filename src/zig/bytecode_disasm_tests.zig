// Tests for bytecode_disasm module.
const std = @import("std");
const testing = std.testing;
const bc = @import("bytecode.zig");
const vm = @import("value.zig");
const disasm = @import("bytecode_disasm.zig");

const Allocator = std.mem.Allocator;
const BytecodeProgram = bc.BytecodeProgram;

test "bytecode_disasm: empty program disassembles" {
    var program = BytecodeProgram.init(testing.allocator);
    defer program.deinit(testing.allocator);

    // Add a STOP instruction
    _ = try program.emit(testing.allocator, .stop, 0);

    // We can't easily redirect stdout in Zig tests, so just verify
    // the function doesn't crash with a minimal program.
    // The output goes to stdout which is acceptable for this test.
    try disasm.disassemble(testing.allocator, &program, "test");
}

test "bytecode_disasm: program with constants and symbols" {
    var program = BytecodeProgram.init(testing.allocator);
    defer program.deinit(testing.allocator);

    // Add a constant (string)
    const str_val = try vm.stringValue(testing.allocator, "hello");
    defer vm.valueDeinit(&str_val, testing.allocator);
    _ = try program.addConstant(testing.allocator, str_val);

    // Add an integer constant
    const int_val = vm.intValue(42);
    _ = try program.addConstant(testing.allocator, int_val);

    // Add symbols
    _ = try program.addSymbol(testing.allocator, "x");
    _ = try program.addSymbol(testing.allocator, "y");

    // Add instructions: PUSH_INT 42, LOAD_VAR 'x', ADD, RET, STOP
    const operand_bits: usize = @as(usize, @bitCast(@as(u64, 42)));
    _ = try program.emit(testing.allocator, .push_int, operand_bits);
    _ = try program.emit(testing.allocator, .load_var, 0);
    _ = try program.emit0(testing.allocator, .add);
    _ = try program.emit0(testing.allocator, .ret);
    _ = try program.emit0(testing.allocator, .stop);

    try disasm.disassemble(testing.allocator, &program, "test-fn");
}

test "bytecode_disasm: jump instructions" {
    var program = BytecodeProgram.init(testing.allocator);
    defer program.deinit(testing.allocator);

    // PUSH_NIL, JUMP_IF_NIL -> 3, PUSH_INT 1, RET, STOP
    _ = try program.emit0(testing.allocator, .push_nil);
    _ = try program.emit(testing.allocator, .jump_if_nil, 3);
    const operand_bits: usize = @as(usize, @bitCast(@as(u64, 1)));
    _ = try program.emit(testing.allocator, .push_int, operand_bits);
    _ = try program.emit0(testing.allocator, .ret);
    _ = try program.emit0(testing.allocator, .stop);

    try disasm.disassemble(testing.allocator, &program, "jump-test");
}

test "bytecode_disasm: source markers" {
    var program = BytecodeProgram.init(testing.allocator);
    defer program.deinit(testing.allocator);

    // Add a source marker
    var markers = program.source_markers;
    try markers.append(testing.allocator, .{
        .file = try testing.allocator.dupe(u8, "test.clj"),
        .line = 10,
        .col = 5,
    });
    program.source_markers = markers;

    // SOURCE_MARKER 0, PUSH_NIL, STOP
    _ = try program.emit(testing.allocator, .source_marker, 0);
    _ = try program.emit0(testing.allocator, .push_nil);
    _ = try program.emit0(testing.allocator, .stop);

    try disasm.disassemble(testing.allocator, &program, "marker-test");
}

test "bytecode_disasm: resolved values pool" {
    var program = BytecodeProgram.init(testing.allocator);
    defer program.deinit(testing.allocator);

    // Add a resolved value
    const resolved = vm.intValue(100);
    _ = try program.addResolvedValue(testing.allocator, resolved);

    // LOAD_CACHED 0, RET, STOP
    _ = try program.emit(testing.allocator, .load_cached, 0);
    _ = try program.emit0(testing.allocator, .ret);
    _ = try program.emit0(testing.allocator, .stop);

    try disasm.disassemble(testing.allocator, &program, "cached-test");
}

test "bytecode_disasm: printValuePretty helper" {
    const allocator = testing.allocator;

    // Test integer
    const int_val = vm.intValue(42);
    const int_str = try disasm.printValuePretty(allocator, int_val);
    defer allocator.free(int_str);
    try testing.expectEqualStrings("42", int_str);

    // Test nil
    const nil_str = try disasm.printValuePretty(allocator, vm.nilValue());
    defer allocator.free(nil_str);
    try testing.expectEqualStrings("nil", nil_str);

    // Test boolean
    const bool_str = try disasm.printValuePretty(allocator, vm.boolValue(true));
    defer allocator.free(bool_str);
    try testing.expectEqualStrings("true", bool_str);
}
