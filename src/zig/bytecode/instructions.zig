// Bytecode instruction definitions and program structure.
// Contains OpCode enum, Instruction struct, BytecodeProgram, SourceMarker, LoopInfo.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;

const Allocator = std.mem.Allocator;

// Forward declaration — defined in vm_types.zig
const FnMetadata = @import("vm_types.zig").FnMetadata;

// ============================================================
// Instruction set
// ============================================================

/// Single bytecode instruction.
/// opcode: the operation to perform.
/// operand: context-dependent (constant pool index, jump target, arg count, etc.)
pub const Instruction = struct {
    opcode: OpCode,
    operand: usize = 0,
};

/// Bytecode opcodes.
pub const OpCode = enum(u8) {
    // --- Constants (operand = index into constant pool) ---
    push_nil,
    push_true,
    push_false,
    push_int,       // operand = i64 value (not pool index)
    push_float,     // operand = bits of f64 (not pool index)
    push_const,     // operand = index into constant pool (string, symbol, keyword, bigint, ratio, decimal, regex, char)

    // --- Variables ---
    load_var,       // operand = index into symbol pool; pushes env lookup result
    load_cached,    // operand = index into resolved_values; pushes pre-resolved value
    store_var,      // operand = index into symbol pool; pops value, stores in env

    // --- Function calls ---
    call_n,         // operand = n; pops n args then fn, pushes result
    call_self,      // operand = n; pops n args, calls self_fn with them

    // --- Control flow (operand = target PC) ---
    jump,
    jump_if_nil,
    jump_if_not_nil,

    // --- Comparison (pop 2, push result) ---
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    compare,      // pop 2, push -1/0/1

    // --- Arithmetic (pop operands, push result) ---
    add,
    sub,
    mul,
    div,
    rem,
    quot,         // integer division (truncate toward zero)
    mod,          // floor modulus
    neg,

    // --- Type checks (pop 1, push bool) ---
    is_nil,
    is_truthy,
    not,          // pop 1, push bool (true if falsy: nil or false)
    is_number,    // pop 1, push bool (integer, float, bigint, ratio, decimal)
    is_int,       // pop 1, push bool (integer only)
    is_float,     // pop 1, push bool (float only)
    is_string,    // pop 1, push bool (string only)
    is_boolean,   // pop 1, push bool (bool only)
    is_list,      // pop 1, push bool (list only)
    is_vector,    // pop 1, push bool (vector only)
    is_map,       // pop 1, push bool (map or record)
    is_set,       // pop 1, push bool (set only)
    is_symbol,    // pop 1, push bool (symbol only)
    is_keyword,   // pop 1, push bool (keyword only)

    // --- Collections ---
    cons,           // pop 2 (tail, head), push cons cell
    list_n,         // pop n values, push list (operand = n)
    vector_n,       // pop n values, push vector (operand = n)
    map_n,          // pop 2*n values as key-value pairs, push map (operand = n)
    get,            // pop 2 (key, map/coll), push value
    assoc,          // pop 3 (val, key, map), push new map
    conj,           // pop 2 (val, coll), push new coll
    count,
    first,
    rest,
    nth,            // pop 2 (n, coll), push value
    seq,
    is_empty,       // pop 1 (coll), push bool (true if empty)
    is_not_empty,   // pop 1 (coll), push coll if not empty, nil if empty
    make_empty,     // pop 1 (coll), push empty collection of same type

    // --- Special ---
    deref,          // pop 1, push dereferenced value
    quote,          // operand = index into constant pool; push quoted value

    // --- Loop/recursion ---
    loop_start,     // mark loop target (operand = loop PC for recur)
    recur,          // jump to nearest loop_start with values on stack

    // --- Function creation ---
    make_fn,        // operand = index into fn pool; push function value

    // --- Return / halt ---
    ret,            // pop 1, return from VM execution
    stop,           // halt execution (no return value)

    // --- Metadata ---
    source_marker,  // operand = index into source marker table
    nop,
};

// ============================================================
// Bytecode program
// ============================================================

/// Source location for stack traces.
pub const SourceMarker = struct {
    file: []const u8,
    line: usize,
    col: usize,
};

/// Loop binding information for loop/recur support.
pub const LoopInfo = struct {
    body_pc: usize,               // PC of first body instruction (after loop_start)
    binding_sym_indices: []usize, // indices into symbol pool for binding names
};

/// A compiled bytecode program.
pub const BytecodeProgram = struct {
    instructions: std.ArrayListUnmanaged(Instruction),
    constants: std.ArrayListUnmanaged(Value),       // constant pool
    symbols: std.ArrayListUnmanaged([]const u8),     // symbol pool (for load_var/store_var)
    resolved_values: std.ArrayListUnmanaged(Value) = .empty, // pre-resolved symbol values (for load_cached)
    source_markers: std.ArrayListUnmanaged(SourceMarker),
    fn_pool: ?[]*FnMetadata = null,                 // function metadata pool (for make_fn)
    loop_infos: std.ArrayListUnmanaged(LoopInfo) = .empty, // loop binding info (for loop/recur)
    self_fn: ?Value = null,                          // enclosing function value (for call_self)
    source_file: []const u8 = "",

    pub fn init(allocator: Allocator) BytecodeProgram {
        _ = allocator;
        return .{
            .instructions = .empty,
            .constants = .empty,
            .symbols = .empty,
            .source_markers = .empty,
            .source_file = "",
        };
    }

    pub fn deinit(self: *BytecodeProgram, allocator: Allocator) void {
        for (self.constants.items) |*v| {
            vm.valueDeinit(v, allocator);
        }
        self.constants.deinit(allocator);
        for (self.symbols.items) |s| {
            allocator.free(s);
        }
        self.symbols.deinit(allocator);
        for (self.resolved_values.items) |*v| {
            vm.valueDeinit(v, allocator);
        }
        self.resolved_values.deinit(allocator);
        for (self.source_markers.items) |*m| {
            allocator.free(m.file);
        }
        self.source_markers.deinit(allocator);
        for (self.loop_infos.items) |info| {
            allocator.free(info.binding_sym_indices);
        }
        self.loop_infos.deinit(allocator);
        if (self.fn_pool) |pool| {
            for (pool) |meta| {
                meta.deinit();
                allocator.destroy(meta);
            }
            allocator.free(pool);
        }
        self.instructions.deinit(allocator);
    }

    /// Add loop binding info. Returns the index.
    pub fn addLoopInfo(self: *BytecodeProgram, allocator: Allocator, body_pc: usize, binding_sym_indices: []usize) anyerror!usize {
        const idx = self.loop_infos.items.len;
        try self.loop_infos.append(allocator, .{
            .body_pc = body_pc,
            .binding_sym_indices = binding_sym_indices,
        });
        return idx;
    }

    /// Append an instruction. Returns the PC (index) of the appended instruction.
    pub fn emit(self: *BytecodeProgram, allocator: Allocator, opcode: OpCode, operand: usize) anyerror!usize {
        const pc = self.instructions.items.len;
        try self.instructions.append(allocator, .{ .opcode = opcode, .operand = operand });
        return pc;
    }

    /// Append an instruction with no operand.
    pub fn emit0(self: *BytecodeProgram, allocator: Allocator, opcode: OpCode) anyerror!usize {
        return self.emit(allocator, opcode, 0);
    }

    /// Add a value to the constant pool. Returns the index.
    pub fn addConstant(self: *BytecodeProgram, allocator: Allocator, val: Value) anyerror!usize {
        const idx = self.constants.items.len;
        try self.constants.append(allocator, val);
        return idx;
    }

    /// Add a symbol to the symbol pool. Returns the index.
    pub fn addSymbol(self: *BytecodeProgram, allocator: Allocator, name: []const u8) anyerror!usize {
        const idx = self.symbols.items.len;
        try self.symbols.append(allocator, try allocator.dupe(u8, name));
        return idx;
    }

    /// Add a pre-resolved value to the resolved_values pool. Returns the index.
    /// Used by load_cached to avoid runtime symbol lookup.
    pub fn addResolvedValue(self: *BytecodeProgram, allocator: Allocator, val: Value) anyerror!usize {
        const idx = self.resolved_values.items.len;
        try self.resolved_values.append(allocator, try vm.shallowClone(&val, allocator));
        return idx;
    }

    /// Get a human-readable name for an opcode.
    pub fn opcodeName(op: OpCode) []const u8 {
        return switch (op) {
            .push_nil => "PUSH_NIL",
            .push_true => "PUSH_TRUE",
            .push_false => "PUSH_FALSE",
            .push_int => "PUSH_INT",
            .push_float => "PUSH_FLOAT",
            .push_const => "PUSH_CONST",
            .load_var => "LOAD_VAR",
            .load_cached => "LOAD_CACHED",
            .store_var => "STORE_VAR",
            .call_n => "CALL_N",
            .call_self => "CALL_SELF",
            .jump => "JUMP",
            .jump_if_nil => "JUMP_IF_NIL",
            .jump_if_not_nil => "JUMP_IF_NOT_NIL",
            .eq => "EQ",
            .ne => "NE",
            .lt => "LT",
            .gt => "GT",
            .le => "LE",
            .ge => "GE",
            .compare => "COMPARE",
            .add => "ADD",
            .sub => "SUB",
            .mul => "MUL",
            .div => "DIV",
            .rem => "REM",
            .quot => "QUOT",
            .mod => "MOD",
            .neg => "NEG",
            .is_nil => "IS_NIL",
            .is_truthy => "IS_TRUTHY",
            .not => "NOT",
            .is_number => "IS_NUMBER",
            .is_int => "IS_INT",
            .is_float => "IS_FLOAT",
            .is_string => "IS_STRING",
            .is_boolean => "IS_BOOLEAN",
            .is_list => "IS_LIST",
            .is_vector => "IS_VECTOR",
            .is_map => "IS_MAP",
            .is_set => "IS_SET",
            .is_symbol => "IS_SYMBOL",
            .is_keyword => "IS_KEYWORD",
            .cons => "CONS",
            .list_n => "LIST_N",
            .vector_n => "VECTOR_N",
            .map_n => "MAP_N",
            .get => "GET",
            .assoc => "ASSOC",
            .conj => "CONJ",
            .count => "COUNT",
            .first => "FIRST",
            .rest => "REST",
            .nth => "NTH",
            .seq => "SEQ",
            .is_empty => "IS_EMPTY",
            .is_not_empty => "IS_NOT_EMPTY",
            .make_empty => "MAKE_EMPTY",
            .deref => "DEREF",
            .quote => "QUOTE",
            .loop_start => "LOOP_START",
            .recur => "RECUR",
            .make_fn => "MAKE_FN",
            .ret => "RET",
            .stop => "STOP",
            .source_marker => "SOURCE_MARKER",
            .nop => "NOP",
        };
    }

    /// Print the bytecode for debugging.
    pub fn debugPrint(self: *const BytecodeProgram) void {
        std.debug.print("=== Bytecode ({} instructions, {} constants, {} symbols) ===\n", .{
            self.instructions.items.len,
            self.constants.items.len,
            self.symbols.items.len,
        });
        for (self.instructions.items, 0..) |inst, i| {
            std.debug.print("{:04d} {:<16s} ", .{ i, opcodeName(inst.opcode) });
            switch (inst.opcode) {
                .push_int => std.debug.print("{}", .{inst.operand}),
                .push_float => std.debug.print("{} (0x{x})", .{ inst.operand, inst.operand }),
                .push_const, .load_var, .load_cached, .store_var, .quote, .make_fn => {
                    if (inst.opcode == .load_cached) {
                        if (inst.operand < self.resolved_values.items.len) {
                            std.debug.print("resolved[{}] = ", .{inst.operand});
                            printValueShort(self.resolved_values.items[inst.operand]);
                        } else {
                            std.debug.print("resolved[{}]", .{inst.operand});
                        }
                    } else if (inst.operand < self.constants.items.len) {
                        std.debug.print("const[{}] = ", .{inst.operand});
                        printValueShort(self.constants.items[inst.operand]);
                    } else if (inst.opcode == .load_var or inst.opcode == .store_var) {
                        if (inst.operand < self.symbols.items.len) {
                            std.debug.print("'{s}'", .{self.symbols.items[inst.operand]});
                        } else {
                            std.debug.print("sym[{}]", .{inst.operand});
                        }
                    } else {
                        std.debug.print("[{}]", .{inst.operand});
                    }
                },
                .call_n => std.debug.print("args={}", .{inst.operand}),
                .list_n, .vector_n => std.debug.print("n={}", .{inst.operand}),
                .map_n => std.debug.print("pairs={}", .{inst.operand}),
                .jump, .jump_if_nil, .jump_if_not_nil => std.debug.print("-> {}", .{inst.operand}),
                .source_marker => {
                    if (inst.operand < self.source_markers.items.len) {
                        const m = self.source_markers.items[inst.operand];
                        std.debug.print("{s}:{d}:{d}", .{ m.file, m.line, m.col });
                    } else {
                        std.debug.print("[{}]", .{inst.operand});
                    }
                },
                .loop_start => std.debug.print("target={}", .{inst.operand}),
                else => {},
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("=== End Bytecode ===\n", .{});
    }

    fn printValueShort(v: Value) void {
        switch (v) {
            .nil => std.debug.print("nil", .{}),
            .bool => |b| std.debug.print("{}", .{b}),
            .integer => |i| std.debug.print("{}", .{i}),
            .float => |f| std.debug.print("{}", .{f}),
            .string => |s| std.debug.print("\"{s}\"", .{s}),
            .symbol => |s| std.debug.print("'{s}", .{s}),
            .keyword => |s| std.debug.print(":{s}", .{s}),
            .character => |c| std.debug.print("\\{}", .{c}),
            else => std.debug.print("<{}>", .{@tagName(v)}),
        }
    }
};
