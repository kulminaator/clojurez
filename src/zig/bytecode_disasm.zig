// Bytecode disassembly module for ClojureZ.
// Provides human-friendly bytecode disassembly output to stdout.
// Used by --generate-bytecode CLI option.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bc = @import("bytecode.zig");
const vm = @import("value.zig");

const OpCode = bc.OpCode;
const Instruction = bc.Instruction;
const BytecodeProgram = bc.BytecodeProgram;
const SourceMarker = bc.SourceMarker;
const Value = vm.Value;

// ============================================================
// Helper: write string to stdout
// ============================================================

fn writeOut(data: []const u8) anyerror!void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Options.debug_io, &buf);
    try writer.interface.writeAll(data);
    writer.flush() catch {};
}

fn writeFmtStr(allocator: Allocator, s: []const u8) anyerror!void {
    const msg = try std.fmt.allocPrint(allocator, "{s}", .{s});
    defer allocator.free(msg);
    try writeOut(msg);
}

// ============================================================
// Public API
// ============================================================

/// Disassemble a BytecodeProgram and write to stdout.
/// Prints a structured output with header, constant pool, symbol pool,
/// resolved values pool, and instruction listing.
pub fn disassemble(allocator: Allocator, program: *const BytecodeProgram, label: []const u8) anyerror!void {
    try printHeader(allocator, label, program);
    try printConstantPool(allocator, program);
    try printSymbolPool(allocator, program);
    try printResolvedValues(allocator, program);
    try printInstructions(allocator, program);
    try writeOut("\n");
}

// ============================================================
// Header
// ============================================================

fn printHeader(allocator: Allocator, label: []const u8, program: *const BytecodeProgram) anyerror!void {
    const msg = try std.fmt.allocPrint(allocator, "=== {s} ===\nConstants: {d}, Symbols: {d}, Instructions: {d}\n", .{
        label,
        program.constants.items.len,
        program.symbols.items.len,
        program.instructions.items.len,
    });
    defer allocator.free(msg);
    try writeOut(msg);
}

// ============================================================
// Constant Pool
// ============================================================

fn printConstantPool(allocator: Allocator, program: *const BytecodeProgram) anyerror!void {
    const pool = program.constants.items;
    if (pool.len == 0) {
        try writeOut("Constant Pool: (empty)\n");
        return;
    }

    try writeOut("Constant Pool:\n");
    var i: usize = 0;
    while (i < pool.len) : (i += 1) {
        const formatted = try vm.fmt(pool[i], allocator);
        defer allocator.free(formatted);
        const msg = try std.fmt.allocPrint(allocator, "{d}: {s}\n", .{ i, formatted });
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

// ============================================================
// Symbol Pool
// ============================================================

fn printSymbolPool(allocator: Allocator, program: *const BytecodeProgram) anyerror!void {
    const pool = program.symbols.items;
    if (pool.len == 0) {
        try writeOut("Symbol Pool: (empty)\n");
        return;
    }

    try writeOut("Symbol Pool:\n");
    var i: usize = 0;
    while (i < pool.len) : (i += 1) {
        const msg = try std.fmt.allocPrint(allocator, "{d}: {s}\n", .{ i, pool[i] });
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

// ============================================================
// Resolved Values Pool
// ============================================================

fn printResolvedValues(allocator: Allocator, program: *const BytecodeProgram) anyerror!void {
    const pool = program.resolved_values.items;
    if (pool.len == 0) return;

    try writeOut("Resolved Values:\n");
    var i: usize = 0;
    while (i < pool.len) : (i += 1) {
        const formatted = try vm.fmt(pool[i], allocator);
        defer allocator.free(formatted);
        const msg = try std.fmt.allocPrint(allocator, "{d}: {s}\n", .{ i, formatted });
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

// ============================================================
// Instruction Listing
// ============================================================

fn printInstructions(allocator: Allocator, program: *const BytecodeProgram) anyerror!void {
    const instructions = program.instructions.items;
    try writeOut("Disassembly:\n");

    var pc: usize = 0;
    while (pc < instructions.len) : (pc += 1) {
        const inst = instructions[pc];
        try printInstruction(allocator, program, pc, inst);
    }
}

/// Print a single instruction with PC, opcode name, and decoded operand.
fn printInstruction(allocator: Allocator, program: *const BytecodeProgram, pc: usize, inst: Instruction) anyerror!void {
    const name = bc.BytecodeProgram.opcodeName(inst.opcode);
    const header = try std.fmt.allocPrint(allocator, "{d:04}: {s}\t", .{ pc, name });
    defer allocator.free(header);
    try writeOut(header);

    switch (inst.opcode) {
        .push_int => try printPushInt(allocator, inst.operand),
        .push_float => try printPushFloat(allocator, inst.operand),
        .push_const => try printPushConst(allocator, program, inst.operand),
        .quote => try printQuote(allocator, program, inst.operand),
        .load_var => try printLoadVar(allocator, program, inst.operand),
        .store_var => try printStoreVar(allocator, program, inst.operand),
        .load_cached => try printLoadCached(allocator, program, inst.operand),
        .call_n, .call_self => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "args={d}", .{inst.operand})),
        .list_n, .vector_n => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "n={d}", .{inst.operand})),
        .map_n => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "pairs={d}", .{inst.operand})),
        .str_n => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "n={d}", .{inst.operand})),
        .concat_n => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "n={d}", .{inst.operand})),
        .range => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "args={d}", .{inst.operand})),
        .reduce_fn => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "args={d}", .{inst.operand})),
        .jump, .jump_if_nil, .jump_if_not_nil => try printJump(allocator, inst.operand),
        .source_marker => try printSourceMarker(allocator, program, inst.operand),
        .loop_start => try printLoopStart(allocator, program, inst.operand),
        .recur => {},
        .make_fn => try printMakeFn(allocator, program, inst.operand),
        .make_lazy_seq => try writeFmtStr(allocator, try std.fmt.allocPrint(allocator, "bc[{d}]", .{inst.operand})),
        .nop, .push_nil, .push_true, .push_false, .ret, .stop => {},
        // Two-operand ops (no operand in instruction)
        .eq, .ne, .lt, .gt, .le, .ge, .compare,
        .add, .sub, .mul, .div, .rem, .quot, .mod, .neg,
        .is_nil, .is_truthy, .not,
        .is_number, .is_int, .is_float, .is_string, .is_boolean,
        .is_list, .is_vector, .is_map, .is_set, .is_symbol, .is_keyword,
        .cons, .get, .assoc, .conj, .count, .first, .rest, .nth, .seq,
        .is_empty, .is_not_empty, .make_empty, .contains,
        .peek, .pop, .make_reduced, .is_reduced, .unreduced,
        .get_meta, .set_meta, .make_keyword, .make_symbol,
        .vec, .sort, .sort_by, .merge,
        .map_fn, .apply_fn, .deref => {},
    }
    try writeOut("\n");
}

// ============================================================
// Operand formatters
// ============================================================

fn printPushInt(allocator: Allocator, operand: usize) anyerror!void {
    const i: i64 = @as(i64, @bitCast(@as(u64, @intCast(operand))));
    const msg = try std.fmt.allocPrint(allocator, "{d}", .{i});
    defer allocator.free(msg);
    try writeOut(msg);
}

fn printPushFloat(allocator: Allocator, operand: usize) anyerror!void {
    const bits: u64 = @intCast(operand);
    const f: f64 = @bitCast(bits);
    const msg = try std.fmt.allocPrint(allocator, "{d} (0x{x})", .{ f, bits });
    defer allocator.free(msg);
    try writeOut(msg);
}

fn printPushConst(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    const msg = try std.fmt.allocPrint(allocator, "{d} (", .{operand});
    defer allocator.free(msg);
    try writeOut(msg);
    if (operand < program.constants.items.len) {
        const formatted = try vm.fmt(program.constants.items[operand], allocator);
        defer allocator.free(formatted);
        const s = try std.fmt.allocPrint(allocator, "{s})", .{formatted});
        defer allocator.free(s);
        try writeOut(s);
    } else {
        try writeOut("?))");
    }
}

fn printQuote(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    const msg = try std.fmt.allocPrint(allocator, "{d} (", .{operand});
    defer allocator.free(msg);
    try writeOut(msg);
    if (operand < program.constants.items.len) {
        const formatted = try vm.fmt(program.constants.items[operand], allocator);
        defer allocator.free(formatted);
        const s = try std.fmt.allocPrint(allocator, "{s})", .{formatted});
        defer allocator.free(s);
        try writeOut(s);
    } else {
        try writeOut("?))");
    }
}

fn printLoadVar(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    if (operand < program.symbols.items.len) {
        const msg = try std.fmt.allocPrint(allocator, "'{s}'", .{program.symbols.items[operand]});
        defer allocator.free(msg);
        try writeOut(msg);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "sym[{d}]", .{operand});
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

fn printStoreVar(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    if (operand < program.symbols.items.len) {
        const msg = try std.fmt.allocPrint(allocator, "'{s}'", .{program.symbols.items[operand]});
        defer allocator.free(msg);
        try writeOut(msg);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "sym[{d}]", .{operand});
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

fn printLoadCached(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    if (operand < program.resolved_values.items.len) {
        const formatted = try vm.fmt(program.resolved_values.items[operand], allocator);
        defer allocator.free(formatted);
        const msg = try std.fmt.allocPrint(allocator, "{d} ({s})", .{ operand, formatted });
        defer allocator.free(msg);
        try writeOut(msg);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "resolved[{d}]", .{operand});
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

fn printJump(allocator: Allocator, target: usize) anyerror!void {
    const msg = try std.fmt.allocPrint(allocator, "-> {d:04}", .{target});
    defer allocator.free(msg);
    try writeOut(msg);
}

fn printSourceMarker(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    if (operand < program.source_markers.items.len) {
        const m = program.source_markers.items[operand];
        const msg = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{ m.file, m.line, m.col });
        defer allocator.free(msg);
        try writeOut(msg);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "[{d}]", .{operand});
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

fn printLoopStart(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    if (operand < program.loop_infos.items.len) {
        const info = program.loop_infos.items[operand];
        const msg = try std.fmt.allocPrint(allocator, "target={d}, bindings={d}", .{ info.body_pc, info.binding_sym_indices.len });
        defer allocator.free(msg);
        try writeOut(msg);
        var i: usize = 0;
        while (i < info.binding_sym_indices.len) : (i += 1) {
            const sym_idx = info.binding_sym_indices[i];
            if (sym_idx < program.symbols.items.len) {
                const s = try std.fmt.allocPrint(allocator, " '{s}'", .{program.symbols.items[sym_idx]});
                defer allocator.free(s);
                try writeOut(s);
            } else {
                const s = try std.fmt.allocPrint(allocator, " sym[{d}]", .{sym_idx});
                defer allocator.free(s);
                try writeOut(s);
            }
        }
    } else {
        const msg = try std.fmt.allocPrint(allocator, "target={d}", .{operand});
        defer allocator.free(msg);
        try writeOut(msg);
    }
}

fn printMakeFn(allocator: Allocator, program: *const BytecodeProgram, operand: usize) anyerror!void {
    if (program.fn_pool) |pool| {
        if (operand < pool.len) {
            const meta = pool[operand];
            const name = meta.name orelse "anonymous";
            const msg = try std.fmt.allocPrint(allocator, "{d} ({s}, arities={d})", .{ operand, name, meta.arities.items.len });
            defer allocator.free(msg);
            try writeOut(msg);
            return;
        }
    }
    const msg = try std.fmt.allocPrint(allocator, "{d}", .{operand});
    defer allocator.free(msg);
    try writeOut(msg);
}

// ============================================================
// Pretty-print helper for values
// ============================================================

/// Format any Value for display using the standard Value formatting.
/// The returned string is GC-allocated and must be freed by the caller.
pub fn printValuePretty(allocator: Allocator, val: Value) anyerror![]const u8 {
    return vm.fmt(val, allocator);
}

// ============================================================
// Tests
// ============================================================

const _tests = @import("bytecode_disasm_tests.zig");
