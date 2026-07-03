// Bytecode compiler and VM for ClojureZ.
// Compiles Clojure AST (list.List) to bytecode for faster repeated execution.
// Uses a stack-based VM with a constant pool.
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const vec = @import("vector.zig");
const eval_mod = @import("eval.zig");
const gc_mod = @import("gc.zig");
const phm = @import("persistent_hash_map.zig");
const BI = @import("big_int.zig");
const RatioMod = @import("ratio.zig");
const BD = @import("big_decimal.zig");
const arithmetic = @import("namespaces/core/arithmetic.zig");

const Allocator = std.mem.Allocator;

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
    store_var,      // operand = index into symbol pool; pops value, stores in env

    // --- Function calls ---
    call_n,         // operand = n; pops n args then fn, pushes result

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

    // --- Arithmetic (pop operands, push result) ---
    add,
    sub,
    mul,
    div,
    rem,
    neg,

    // --- Type checks (pop 1, push bool) ---
    is_nil,
    is_truthy,

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
    source_markers: std.ArrayListUnmanaged(SourceMarker),
    fn_pool: ?[]*FnMetadata = null,                 // function metadata pool (for make_fn)
    loop_infos: std.ArrayListUnmanaged(LoopInfo) = .empty, // loop binding info (for loop/recur)
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
            .store_var => "STORE_VAR",
            .call_n => "CALL_N",
            .jump => "JUMP",
            .jump_if_nil => "JUMP_IF_NIL",
            .jump_if_not_nil => "JUMP_IF_NOT_NIL",
            .eq => "EQ",
            .ne => "NE",
            .lt => "LT",
            .gt => "GT",
            .le => "LE",
            .ge => "GE",
            .add => "ADD",
            .sub => "SUB",
            .mul => "MUL",
            .div => "DIV",
            .rem => "REM",
            .neg => "NEG",
            .is_nil => "IS_NIL",
            .is_truthy => "IS_TRUTHY",
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
                .push_const, .load_var, .store_var, .quote, .make_fn => {
                    if (inst.operand < self.constants.items.len) {
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

// ============================================================
// VM execution state
// ============================================================

/// The VM operand stack.
const OperandStack = struct {
    items: std.ArrayListUnmanaged(*Value) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) OperandStack {
        return .{ .items = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *OperandStack) void {
        // Don't free the *Value pointers — they're owned by the caller/GC.
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *OperandStack, val: *Value) anyerror!void {
        try self.items.append(self.allocator, val);
    }

    pub fn pop(self: *OperandStack) ?*Value {
        if (self.items.items.len == 0) return null;
        const item = self.items.items[self.items.items.len - 1];
        self.items.items.len -= 1;
        return item;
    }

    pub fn peek(self: *const OperandStack) ?*Value {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1];
    }

    pub fn len(self: *const OperandStack) usize {
        return self.items.items.len;
    }
};

/// Result of VM execution.
pub const VMResult = union(enum) {
    value: *Value,   // normal return
    trampoline,      // function call pushed trampoline frame
};

/// Loop frame for loop/recur support.
pub const LoopFrame = struct {
    loop_pc: usize,       // PC of loop_start instruction
    body_pc: usize,       // PC of first body instruction (after bindings)
    binding_count: usize, // number of loop bindings
    binding_sym_indices: []usize, // indices into symbol pool for binding names
};

/// Function metadata for make_fn support.
pub const FnAridity = struct {
    params: list.List,
    bytecode: ?*BytecodeProgram,
    rest_name: ?[]const u8,
};

pub const FnMetadata = struct {
    arities: std.ArrayListUnmanaged(FnAridity),
    name: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *FnMetadata) void {
        for (self.arities.items) |*a| {
            a.params.deinit(self.allocator);
            if (a.bytecode) |bc| {
                bc.deinit(self.allocator);
                self.allocator.destroy(bc);
            }
            if (a.rest_name) |rn| self.allocator.free(rn);
        }
        self.arities.deinit(self.allocator);
        if (self.name) |n| self.allocator.free(n);
    }
};

// ============================================================
// VM execution
// ============================================================

/// Resolve a symbol name in the environment, handling qualified symbols.
/// Qualified symbols like "zig.core/+" are split on "/" and resolved
/// through the namespace manager, matching the AST evaluator's behavior.
fn resolveSymbol(env: *vm.Env, sym_name: []const u8) anyerror!Value {
    // Check for qualified symbol: alias/name or namespace/name
    if (std.mem.indexOfScalar(u8, sym_name, '/')) |slash_idx| {
        const alias = sym_name[0..slash_idx];
        const name = sym_name[slash_idx + 1 ..];

        // Try to resolve through namespace manager
        const ns_mgr = eval_mod.findNsManager(env) orelse {
            // No namespace manager — fall back to simple lookup
            const val = env.get(sym_name);
            if (val) |v| return v;
            std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
            return error.UndefinedSymbol;
        };

        // Resolve alias to namespace name
        const current_ns = ns_mgr.getCurrentNamespace();
        const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;

        // Get target namespace's env
        const target_env = ns_mgr.getNamespace(target_ns) orelse {
            // Target namespace doesn't exist — fall back to simple lookup
            const val = env.get(sym_name);
            if (val) |v| return v;
            std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
            return error.UndefinedSymbol;
        };

        // Look up name in target namespace
        const val = target_env.get(name);
        if (val) |v| return v;
        std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
        return error.UndefinedSymbol;
    }

    // Unqualified symbol — simple environment lookup (traverses parent chain)
    const val = env.get(sym_name);
    if (val) |v| return v;
    std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
    return error.UndefinedSymbol;
}

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
fn reportBytecodeError(program: *const BytecodeProgram, pc: usize, err: anyerror) void {
    const instrs = program.instructions.items;
    // pc is already past the failing instruction (pc was incremented before the switch)
    const fail_pc: usize = if (pc == 0) 0 else pc - 1;
    const opcode_name = if (fail_pc < instrs.len) OpCode.opcodeName(instrs[fail_pc].opcode) else "?";

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
    ctx: ?*eval_mod.TrampolineStack,
) anyerror!VMResult {
    var stack = OperandStack.init(allocator);
    errdefer stack.deinit();

    var loop_stack: std.ArrayListUnmanaged(*LoopFrame) = .empty;
    errdefer {
        for (loop_stack.items) |frame| {
            allocator.destroy(frame);
        }
        loop_stack.deinit(allocator);
    }

    // fn_pool is passed via program metadata (set by compiler)
    const fn_pool = program.fn_pool;

    var pc: usize = 0;
    const instrs = program.instructions.items;

    while (pc < instrs.len) {
        const inst = instrs[pc];
        pc += 1;

        switch (inst.opcode) {
            .push_nil => {
                const nil_val = try eval_mod.allocValue(allocator, vm.nilValue());
                try stack.push(nil_val);
            },
            .push_true => {
                const val = try eval_mod.allocValue(allocator, vm.boolValue(true));
                try stack.push(val);
            },
            .push_false => {
                const val = try eval_mod.allocValue(allocator, vm.boolValue(false));
                try stack.push(val);
            },
            .push_int => {
                const val = try eval_mod.allocValue(allocator, vm.intValue(@as(i64, @intCast(inst.operand))));
                try stack.push(val);
            },
            .push_float => {
                const f = @as(f64, @bitCast(inst.operand));
                const val = try eval_mod.allocValue(allocator, vm.floatValue(f));
                try stack.push(val);
            },
            .push_const => {
                const idx = inst.operand;
                if (idx >= program.constants.items.len) return error.BytecodeError;
                const val = try vm.cloneGC(&program.constants.items[idx], allocator);
                try stack.push(val);
            },

            .load_var => {
                const sym_idx = inst.operand;
                if (sym_idx >= program.symbols.items.len) return error.BytecodeError;
                const sym_name = program.symbols.items[sym_idx];
                const val = try resolveSymbol(env, sym_name);
                const cloned = try vm.cloneGC(&val, allocator);
                try stack.push(cloned);
            },
            .store_var => {
                const sym_idx = inst.operand;
                if (sym_idx >= program.symbols.items.len) return error.BytecodeError;
                const sym_name = program.symbols.items[sym_idx];
                const val_ptr = stack.pop() orelse return error.BytecodeError;
                const val = try vm.clone(val_ptr, allocator);
                vm.valueDeinit(val_ptr, allocator);
                allocator.destroy(val_ptr);
                try env.put(sym_name, val);
            },

            .call_n => {
                const n = inst.operand;
                // Stack: arg1, arg2, ..., argN, fn  (fn on top)
                // Pop fn, then args in reverse order
                const fn_ptr = stack.pop() orelse return error.BytecodeError;

                // Collect args in reverse, then build list in correct order
                var temp_args: std.ArrayListUnmanaged(*Value) = .empty;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const arg_ptr = stack.pop() orelse {
                        // Clean up any args collected so far
                        for (temp_args.items) |ap| {
                            vm.valueDeinit(ap, allocator);
                            allocator.destroy(ap);
                        }
                        allocator.free(temp_args.items);
                        return error.BytecodeError;
                    };
                    try temp_args.append(allocator, arg_ptr);
                }

                var args: list.List = .empty;
                var remaining_count: usize = temp_args.items.len;
                errdefer {
                    // Clean up args
                    args.deinit(allocator);
                    // Clean up remaining temp_args (those not yet processed)
                    for (temp_args.items[0..remaining_count]) |ap| {
                        vm.valueDeinit(ap, allocator);
                        allocator.destroy(ap);
                    }
                    allocator.free(temp_args.items);
                }
                // temp_args has args in reverse order (argN, argN-1, ..., arg1)
                var j: usize = temp_args.items.len;
                while (j > 0) : (j -= 1) {
                    remaining_count -= 1;
                    const arg_ptr = temp_args.items[j - 1];
                    // Deep clone to avoid sharing internal pointers with the original
                    const cloned = try vm.clone(arg_ptr, allocator);
                    try args.append(allocator, cloned);
                    vm.valueDeinit(arg_ptr, allocator);
                    allocator.destroy(arg_ptr);
                }
                allocator.free(temp_args.items);

                const call_result = try eval_mod.call(allocator, fn_ptr, &args, env, 0, ctx);

                // Clean up fn_ptr
                vm.valueDeinit(fn_ptr, allocator);
                allocator.destroy(fn_ptr);

                switch (call_result) {
                    .value => |v| try stack.push(v),
                    .trampoline => return .trampoline,
                }
            },

            .jump => {
                pc = inst.operand;
            },
            .jump_if_nil => {
                const top = stack.pop() orelse return error.BytecodeError;
                // Both nil and false are falsy in Clojure
                if (std.meta.activeTag(top.*) == .nil or
                    (std.meta.activeTag(top.*) == .bool and top.*.bool == false))
                {
                    pc = inst.operand;
                }
                vm.valueDeinit(top, allocator);
                allocator.destroy(top);
            },
            .jump_if_not_nil => {
                const top = stack.pop() orelse return error.BytecodeError;
                const tag = std.meta.activeTag(top.*);
                // Both nil and false are falsy in Clojure; jump only if truthy
                const is_false = if (tag == .bool) top.*.bool == false else false;
                if (tag != .nil and !is_false) {
                    pc = inst.operand;
                }
                vm.valueDeinit(top, allocator);
                allocator.destroy(top);
            },

            .eq, .ne, .lt, .gt, .le, .ge => {
                const b = stack.pop() orelse return error.BytecodeError;
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try compareOp(inst.opcode, a.*, b.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                vm.valueDeinit(b, allocator);
                allocator.destroy(b);
                try stack.push(result_ptr);
            },

            .add, .sub, .mul, .div, .rem => {
                const b = stack.pop() orelse return error.BytecodeError;
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try arithmeticOp(inst.opcode, a.*, b.*, allocator, env);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                vm.valueDeinit(b, allocator);
                allocator.destroy(b);
                try stack.push(result_ptr);
            },

            .neg => {
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try negateOp(a.*, allocator);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result_ptr);
            },

            .is_nil => {
                const a = stack.pop() orelse return error.BytecodeError;
                const is_nil = std.meta.activeTag(a.*) == .nil;
                const result = try eval_mod.allocValue(allocator, vm.boolValue(is_nil));
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result);
            },
            .is_truthy => {
                const a = stack.pop() orelse return error.BytecodeError;
                const truthy = vm.isTruthy(a.*);
                const result = try eval_mod.allocValue(allocator, vm.boolValue(truthy));
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result);
            },

            .cons => {
                const tail = stack.pop() orelse return error.BytecodeError;
                const head = stack.pop() orelse return error.BytecodeError;
                const cons_val = try vm.consValue(allocator, head.*, tail.*);
                const cons_ptr = try eval_mod.allocValue(allocator, cons_val);
                vm.valueDeinit(head, allocator);
                allocator.destroy(head);
                vm.valueDeinit(tail, allocator);
                allocator.destroy(tail);
                try stack.push(cons_ptr);
            },

            .list_n => {
                const n = inst.operand;
                var temp_items: std.ArrayListUnmanaged(*Value) = .empty;
                errdefer temp_items.deinit(allocator);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const item_ptr = stack.pop() orelse return error.BytecodeError;
                    try temp_items.append(allocator, item_ptr);
                }
                var l: list.List = .empty;
                var j: usize = temp_items.items.len;
                while (j > 0) : (j -= 1) {
                    const item_ptr = temp_items.items[j - 1];
                    try l.append(allocator, try vm.clone(item_ptr, allocator));
                    vm.valueDeinit(item_ptr, allocator);
                    allocator.destroy(item_ptr);
                }
                temp_items.deinit(allocator);
                const list_val = try vm.listValue(allocator, l);
                // l is now owned by list_val's ListData — don't deinit
                const list_ptr = try eval_mod.allocValue(allocator, list_val);
                try stack.push(list_ptr);
            },

            .vector_n => {
                const n = inst.operand;
                var temp_items: std.ArrayListUnmanaged(*Value) = .empty;
                errdefer temp_items.deinit(allocator);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const item_ptr = stack.pop() orelse return error.BytecodeError;
                    try temp_items.append(allocator, item_ptr);
                }
                var v: vec.Vector = .empty;
                var j: usize = temp_items.items.len;
                while (j > 0) : (j -= 1) {
                    const item_ptr = temp_items.items[j - 1];
                    try v.append(allocator, try vm.clone(item_ptr, allocator));
                    vm.valueDeinit(item_ptr, allocator);
                    allocator.destroy(item_ptr);
                }
                temp_items.deinit(allocator);
                const vec_val = try vm.vectorValue(allocator, v);
                // v is now owned by vec_val's VectorData — don't deinit
                const vec_ptr = try eval_mod.allocValue(allocator, vec_val);
                try stack.push(vec_ptr);
            },

            .ret => {
                const result = stack.pop() orelse return error.BytecodeError;
                stack.deinit();
                return .{ .value = result };
            },
            .stop => {
                // Return the top of the stack if available, otherwise nil
                const result = stack.pop() orelse {
                    stack.deinit();
                    return .{ .value = try eval_mod.allocValue(allocator, vm.nilValue()) };
                };
                stack.deinit();
                return .{ .value = result };
            },

            .source_marker, .nop => {
                // No-op for metadata
            },

            .first => {
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try vmFirst(allocator, a.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result_ptr);
            },
            .rest => {
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try vmRest(allocator, a.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result_ptr);
            },
            .count => {
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try vmCount(allocator, a.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result_ptr);
            },

            .map_n => {
                const n = inst.operand;
                var temp_entries: std.ArrayListUnmanaged(*Value) = .empty;
                errdefer temp_entries.deinit(allocator);
                var i: usize = 0;
                while (i < n * 2) : (i += 1) {
                    const entry_ptr = stack.pop() orelse return error.BytecodeError;
                    try temp_entries.append(allocator, entry_ptr);
                }
                var m: vm.Map = .empty;
                errdefer {
                    for (m.items) |*entry| {
                        vm.valueDeinit(&entry.key, allocator);
                        vm.valueDeinit(&entry.value, allocator);
                    }
                    allocator.free(m.items);
                }
                // temp_entries has entries in reverse order: vN, kN, ..., v1, k1
                var j: usize = temp_entries.items.len;
                while (j > 1) : (j -= 2) {
                    const key_ptr = temp_entries.items[j - 1];
                    const val_ptr = temp_entries.items[j - 2];
                    try m.append(allocator, .{
                        .key = try vm.clone(key_ptr, allocator),
                        .value = try vm.clone(val_ptr, allocator),
                    });
                    vm.valueDeinit(key_ptr, allocator);
                    allocator.destroy(key_ptr);
                    vm.valueDeinit(val_ptr, allocator);
                    allocator.destroy(val_ptr);
                }
                temp_entries.deinit(allocator);
                const map_val = try vm.mapValue(allocator, m);
                const map_ptr = try eval_mod.allocValue(allocator, map_val);
                try stack.push(map_ptr);
            },

            .get => {
                const key = stack.pop() orelse return error.BytecodeError;
                const coll = stack.pop() orelse return error.BytecodeError;
                const result = try vmGet(allocator, coll.*, key.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(key, allocator);
                allocator.destroy(key);
                vm.valueDeinit(coll, allocator);
                allocator.destroy(coll);
                try stack.push(result_ptr);
            },

            .assoc => {
                const val = stack.pop() orelse return error.BytecodeError;
                const key = stack.pop() orelse return error.BytecodeError;
                const map = stack.pop() orelse return error.BytecodeError;
                const result = try vmAssoc(allocator, map.*, key.*, val.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(val, allocator);
                allocator.destroy(val);
                vm.valueDeinit(key, allocator);
                allocator.destroy(key);
                vm.valueDeinit(map, allocator);
                allocator.destroy(map);
                try stack.push(result_ptr);
            },

            .conj => {
                const item = stack.pop() orelse return error.BytecodeError;
                const coll = stack.pop() orelse return error.BytecodeError;
                const result = try vmConj(allocator, coll.*, item.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(item, allocator);
                allocator.destroy(item);
                vm.valueDeinit(coll, allocator);
                allocator.destroy(coll);
                try stack.push(result_ptr);
            },

            .nth => {
                const idx = stack.pop() orelse return error.BytecodeError;
                const coll = stack.pop() orelse return error.BytecodeError;
                const result = try vmNth(allocator, coll.*, idx.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(idx, allocator);
                allocator.destroy(idx);
                vm.valueDeinit(coll, allocator);
                allocator.destroy(coll);
                try stack.push(result_ptr);
            },

            .seq => {
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try vmSeq(allocator, a.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result_ptr);
            },

            .deref => {
                const a = stack.pop() orelse return error.BytecodeError;
                const result = try vmDeref(allocator, a.*);
                const result_ptr = try eval_mod.allocValue(allocator, result);
                vm.valueDeinit(a, allocator);
                allocator.destroy(a);
                try stack.push(result_ptr);
            },

            .quote => {
                // Handled by compiler as push_const, but VM supports it for completeness
                const idx = inst.operand;
                if (idx >= program.constants.items.len) return error.BytecodeError;
                const val = try vm.cloneGC(&program.constants.items[idx], allocator);
                try stack.push(val);
            },

            .loop_start => {
                const loop_info_idx = inst.operand;
                if (loop_info_idx >= program.loop_infos.items.len) return error.BytecodeError;
                const info = program.loop_infos.items[loop_info_idx];
                // Push a loop frame onto the loop stack
                const frame = try allocator.create(LoopFrame);
                frame.* = .{
                    .loop_pc = pc - 1,
                    .body_pc = info.body_pc,
                    .binding_count = info.binding_sym_indices.len,
                    .binding_sym_indices = info.binding_sym_indices,
                };
                try loop_stack.append(allocator, frame);
            },

            .recur => {
                if (loop_stack.items.len == 0) return error.BytecodeError;
                const frame = loop_stack.items[loop_stack.items.len - 1];
                const count = frame.binding_count;
                // Pop count values from stack (in reverse order)
                var temp_vals: std.ArrayListUnmanaged(*Value) = .empty;
                errdefer temp_vals.deinit(allocator);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const val_ptr = stack.pop() orelse return error.BytecodeError;
                    try temp_vals.append(allocator, val_ptr);
                }
                // Rebind in reverse order (first binding gets first value)
                var j: usize = temp_vals.items.len;
                while (j > 0) : (j -= 1) {
                    const val_ptr = temp_vals.items[j - 1];
                    const sym_name = program.symbols.items[frame.binding_sym_indices[j - 1]];
                    try env.put(sym_name, val_ptr.*);
                }
                temp_vals.deinit(allocator);
                // Jump to body
                pc = frame.body_pc;
            },

            .make_fn => {
                const idx = inst.operand;
                const fn_meta = fn_pool.?[idx];
                const fn_val = try vmMakeFn(allocator, fn_meta, env);
                const fn_ptr = try eval_mod.allocValue(allocator, fn_val);
                try stack.push(fn_ptr);
            },
        }
    }

    // Fell off the end — return nil
    stack.deinit();
    return .{ .value = try eval_mod.allocValue(allocator, vm.nilValue()) };
}

/// Perform a comparison operation.
fn compareOp(op: OpCode, a: Value, b: Value) anyerror!Value {
    const cmp = vm.compare(a, b);
    return switch (op) {
        .eq => vm.boolValue(cmp == 0),
        .ne => vm.boolValue(cmp != 0),
        .lt => vm.boolValue(cmp < 0),
        .gt => vm.boolValue(cmp > 0),
        .le => vm.boolValue(cmp <= 0),
        .ge => vm.boolValue(cmp >= 0),
        else => unreachable,
    };
}

/// Perform an arithmetic operation.
/// For integer/float operands, computes directly.
/// For bigint/ratio/decimal, delegates to the corresponding zig.core builtin.
fn arithmeticOp(op: OpCode, a: Value, b: Value, allocator: Allocator, env: *vm.Env) anyerror!Value {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);

    // Delegate to zig.core builtin for non-integer/float types
    if (needsDelegation(a_tag) or needsDelegation(b_tag)) {
        return delegateArithmetic(op, a, b, allocator, env);
    }

    // Fast path: integer and float arithmetic
    if (a_tag == .float or b_tag == .float) {
        const af: f64 = switch (a_tag) {
            .float => a.float,
            .integer => @as(f64, @floatFromInt(a.integer)),
            else => unreachable,
        };
        const bf: f64 = switch (b_tag) {
            .float => b.float,
            .integer => @as(f64, @floatFromInt(b.integer)),
            else => unreachable,
        };
        return switch (op) {
            .add => vm.floatValue(af + bf),
            .sub => vm.floatValue(af - bf),
            .mul => vm.floatValue(af * bf),
            .div => if (bf == 0) error.DivisionByZero else vm.floatValue(af / bf),
            .rem => if (bf == 0) error.DivisionByZero else vm.floatValue(@rem(af, bf)),
            else => unreachable,
        };
    }

    // Both integers
    const ai = a.integer;
    const bi = b.integer;
    return switch (op) {
        .add => vm.intValue(ai + bi),
        .sub => vm.intValue(ai - bi),
        .mul => vm.intValue(ai * bi),
        .div => if (bi == 0) error.DivisionByZero else vm.intValue(@divTrunc(ai, bi)),
        .rem => if (bi == 0) error.DivisionByZero else vm.intValue(ai - @divTrunc(ai, bi) * bi),
        else => unreachable,
    };
}

/// Check if a value type needs delegation to zig.core builtins.
fn needsDelegation(tag: std.meta.Tag(Value)) bool {
    return switch (tag) {
        .bigint, .ratio, .decimal => true,
        else => false,
    };
}

/// Delegate arithmetic to the corresponding zig.core builtin.
/// Looks up the builtin (e.g., "+", "-", "*", "/", "rem") and calls it
/// with the two operands as arguments.
fn delegateArithmetic(op: OpCode, a: Value, b: Value, allocator: Allocator, env: *vm.Env) anyerror!Value {
    const op_name = switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "rem",
        else => unreachable,
    };

    // Look up the zig.core builtin in the environment
    const fn_val = try resolveSymbol(env, op_name);

    // Build args list: [a, b]
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    try args.append(allocator, try vm.clone(&a, allocator));
    try args.append(allocator, try vm.clone(&b, allocator));

    // Call the builtin
    const call_result = try eval_mod.call(allocator, &fn_val, &args, env, 0, null);

    switch (call_result) {
        .value => |v| return try vm.clone(v, allocator),
        .trampoline => return error.NotImplemented,
    }
}

/// Perform negation on a numeric value, supporting the full numeric tower.
fn negateOp(val: Value, allocator: Allocator) anyerror!Value {
    return switch (val) {
        .integer => |v| vm.intValue(-v),
        .float => |v| vm.floatValue(-v),
        .bigint => {
            // Clone, negate in-place, then pass to bigIntValue which allocates a new pointer.
            // We must clone the negated result to avoid sharing the limbs array with the original.
            var cloned = try val.bigint.clone(allocator);
            defer cloned.deinit();
            cloned.negate();
            const negated = try cloned.clone(allocator);
            return try vm.bigIntValue(allocator, negated);
        },
        .ratio => {
            var cloned = try val.ratio.clone(allocator);
            defer cloned.deinit();
            const negated = RatioMod.negate(cloned);
            return try vm.ratioValue(allocator, negated);
        },
        .decimal => {
            var cloned = try val.decimal.clone(allocator);
            defer cloned.deinit();
            const negated = BD.negate(cloned);
            return try vm.decimalValue(allocator, negated);
        },
        else => return error.TypeError,
    };
}

/// VM implementation of (first coll) — returns first element or nil.
fn vmFirst(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .list => {
            if (val.list.items.items.len == 0) return vm.nilValue();
            return try vm.clone(&val.list.items.items[0], allocator);
        },
        .vector => {
            if (val.vector.items.items.len == 0) return vm.nilValue();
            return try vm.clone(&val.vector.items.items[0], allocator);
        },
        .cons => {
            return try vm.clone(&val.cons.head, allocator);
        },
        .string => {
            const s = val.string;
            if (s.len == 0) return vm.nilValue();
            const cp_bytes = vm.utf8CodepointAt(s, 0) orelse return vm.nilValue();
            const cp = std.unicode.utf8Decode(cp_bytes) catch return vm.nilValue();
            return vm.charValue(cp);
        },
        else => return vm.nilValue(),
    }
}

/// VM implementation of (rest coll) — returns all but first element.
fn vmRest(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .list => {
            if (val.list.items.items.len <= 1) return try vm.listValue(allocator, list.empty());
            var rest_list: list.List = .empty;
            errdefer rest_list.deinit(allocator);
            for (val.list.items.items[1..]) |item| {
                try rest_list.append(allocator, try vm.clone(&item, allocator));
            }
            return try vm.listValue(allocator, rest_list);
        },
        .vector => {
            if (val.vector.items.items.len <= 1) return try vm.listValue(allocator, list.empty());
            var rest_list: list.List = .empty;
            errdefer rest_list.deinit(allocator);
            for (val.vector.items.items[1..]) |item| {
                try rest_list.append(allocator, try vm.clone(&item, allocator));
            }
            return try vm.listValue(allocator, rest_list);
        },
        .cons => {
            // rest of cons is the tail
            return try vm.clone(&val.cons.tail, allocator);
        },
        else => return try vm.listValue(allocator, list.empty()),
    }
}

/// VM implementation of (count coll) — returns element count as integer.
fn vmCount(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .list => return vm.intValue(@as(i64, @intCast(val.list.items.items.len))),
        .vector => return vm.intValue(@as(i64, @intCast(val.vector.items.items.len))),
        .map => return vm.intValue(@as(i64, @intCast(val.map.entries.items.len))),
        .set => return vm.intValue(@as(i64, @intCast(val.set.items.items.len))),
        .queue => return vm.intValue(@as(i64, @intCast(val.queue.items.items.len))),
        .string => return vm.intValue(@as(i64, @intCast(vm.utf8CodepointCount(val.string)))),
        .cons => {
            // Count cons chain recursively
            var count: i64 = 0;
            var current = try vm.clone(&val, allocator);
            errdefer vm.valueDeinit(&current, allocator);
            while (true) {
                switch (current) {
                    .cons => {
                        count += 1;
                        const tail = try vm.clone(&current.cons.tail, allocator);
                        vm.valueDeinit(&current, allocator);
                        current = tail;
                    },
                    .nil => break,
                    .list => {
                        count += @as(i64, @intCast(current.list.items.items.len));
                        break;
                    },
                    else => {
                        // Improper list tail — count it as 1
                        count += 1;
                        break;
                    },
                }
            }
            return vm.intValue(count);
        },
        .record => {
            const rd = val.record;
            const total: i64 = @as(i64, @intCast(rd.fields.items.len)) + @as(i64, @intCast(rd.extmap.items.len));
            return vm.intValue(total);
        },
        else => return error.TypeError,
    }
}

/// VM implementation of (get map key) — returns value or nil.
fn vmGet(allocator: Allocator, coll: Value, key: Value) anyerror!Value {
    switch (coll) {
        .map => {
            for (coll.map.entries.items) |entry| {
                if (vm.equals(entry.key, key)) return try vm.clone(&entry.value, allocator);
            }
            return vm.nilValue();
        },
        .set => {
            for (coll.set.items.items) |item| {
                if (vm.equals(item, key)) return try vm.clone(&item, allocator);
            }
            return vm.nilValue();
        },
        .record => {
            for (coll.record.fields.items) |entry| {
                if (vm.equals(entry.key, key)) return try vm.clone(&entry.value, allocator);
            }
            for (coll.record.extmap.items) |entry| {
                if (vm.equals(entry.key, key)) return try vm.clone(&entry.value, allocator);
            }
            return vm.nilValue();
        },
        else => return vm.nilValue(),
    }
}

/// VM implementation of (assoc map key val) — returns new map.
fn vmAssoc(allocator: Allocator, map_val: Value, key: Value, val: Value) anyerror!Value {
    if (std.meta.activeTag(map_val) != .map) return error.TypeError;
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_map.items);
    }
    try new_map.ensureTotalCapacity(allocator, map_val.map.entries.items.len + 1);
    for (map_val.map.entries.items) |entry| {
        if (vm.equals(entry.key, key)) {
            try new_map.append(allocator, .{
                .key = try vm.clone(&entry.key, allocator),
                .value = try vm.clone(&val, allocator),
            });
        } else {
            try new_map.append(allocator, .{
                .key = try vm.clone(&entry.key, allocator),
                .value = try vm.clone(&entry.value, allocator),
            });
        }
    }
    // Key not found — add new entry
    if (new_map.items.len == map_val.map.entries.items.len) {
        try new_map.append(allocator, .{
            .key = try vm.clone(&key, allocator),
            .value = try vm.clone(&val, allocator),
        });
    }
    return try vm.mapValue(allocator, new_map);
}

/// VM implementation of (conj coll item) — returns new collection.
fn vmConj(allocator: Allocator, coll: Value, item: Value) anyerror!Value {
    switch (coll) {
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            try new_list.append(allocator, try vm.clone(&item, allocator));
            for (coll.list.items.items) |e| {
                try new_list.append(allocator, try vm.clone(&e, allocator));
            }
            return try vm.listValue(allocator, new_list);
        },
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            for (coll.vector.items.items) |e| {
                try new_vec.append(allocator, try vm.clone(&e, allocator));
            }
            try new_vec.append(allocator, try vm.clone(&item, allocator));
            return try vm.vectorValue(allocator, new_vec);
        },
        .map => {
            if (std.meta.activeTag(item) == .list or std.meta.activeTag(item) == .vector) {
                const items = switch (item) {
                    .list => item.list.items.items,
                    .vector => item.vector.items.items,
                    else => unreachable,
                };
                if (items.len != 2) return error.ArityError;
                return try vmAssoc(allocator, coll, items[0], items[1]);
            }
            return error.TypeError;
        },
        .set => {
            var new_set: vm.Set = .empty;
            errdefer {
                for (new_set.items) |*s| vm.valueDeinit(s, allocator);
                allocator.free(new_set.items);
            }
            for (coll.set.items.items) |e| {
                try new_set.append(allocator, try vm.clone(&e, allocator));
            }
            // Check if already present
            var found = false;
            for (coll.set.items.items) |e| {
                if (vm.equals(e, item)) { found = true; break; }
            }
            if (!found) try new_set.append(allocator, try vm.clone(&item, allocator));
            return try vm.setValue(allocator, new_set);
        },
        else => return error.TypeError,
    }
}

/// VM implementation of (nth coll index) — returns element at index.
fn vmNth(allocator: Allocator, coll: Value, idx_val: Value) anyerror!Value {
    const idx: usize = switch (idx_val) {
        .integer => |i| blk: {
            if (i < 0) return error.IndexOutOfBounds;
            break :blk @as(usize, @intCast(i));
        },
        else => return error.TypeError,
    };
    switch (coll) {
        .list => {
            if (idx >= coll.list.items.items.len) return error.IndexOutOfBounds;
            return try vm.clone(&coll.list.items.items[idx], allocator);
        },
        .vector => {
            if (idx >= coll.vector.items.items.len) return error.IndexOutOfBounds;
            return try vm.clone(&coll.vector.items.items[idx], allocator);
        },
        .string => {
            const cp_bytes = vm.utf8CodepointAt(coll.string, idx) orelse return error.IndexOutOfBounds;
            const cp = std.unicode.utf8Decode(cp_bytes) catch return error.TypeError;
            return vm.charValue(cp);
        },
        .queue => {
            if (idx >= coll.queue.items.items.len) return error.IndexOutOfBounds;
            return try vm.clone(&coll.queue.items.items[idx], allocator);
        },
        else => return error.TypeError,
    }
}

/// VM implementation of (seq coll) — returns seq or nil.
fn vmSeq(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .nil => return vm.nilValue(),
        .list => {
            if (val.list.items.items.len == 0) return vm.nilValue();
            return try vm.clone(&val, allocator);
        },
        .vector => {
            if (val.vector.items.items.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            for (val.vector.items.items) |item| {
                try l.append(allocator, try vm.clone(&item, allocator));
            }
            return try vm.listValue(allocator, l);
        },
        .map => {
            if (val.map.entries.items.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            for (val.map.entries.items) |entry| {
                var pair: list.List = .empty;
                try pair.append(allocator, try vm.clone(&entry.key, allocator));
                try pair.append(allocator, try vm.clone(&entry.value, allocator));
                try l.append(allocator, try vm.listValue(allocator, pair));
            }
            return try vm.listValue(allocator, l);
        },
        .set => {
            if (val.set.items.items.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            for (val.set.items.items) |item| {
                try l.append(allocator, try vm.clone(&item, allocator));
            }
            return try vm.listValue(allocator, l);
        },
        .string => {
            if (val.string.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            var i: usize = 0;
            while (i < val.string.len) {
                const cp_len = std.unicode.utf8ByteSequenceLength(val.string[i]) catch break;
                const cp_bytes = val.string[i .. i + cp_len];
                const cp = std.unicode.utf8Decode(cp_bytes) catch break;
                try l.append(allocator, vm.charValue(cp));
                i += cp_len;
            }
            return try vm.listValue(allocator, l);
        },
        .cons => return try vm.clone(&val, allocator),
        else => return error.TypeError,
    }
}

/// VM implementation of deref — handles atom, reduced, future, promise.
fn vmDeref(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .atom => |data| return try vm.clone(&data.value, allocator),
        .reduced => |data| return try vm.clone(data, allocator),
        .future => {
            // Block until done
            const data = val.future;
            while (data.state.load(.monotonic) == 0) {
                const io = std.Io.Threaded.global_single_threaded.io();
                const duration = std.Io.Duration.fromMilliseconds(1);
                std.Io.sleep(io, duration, std.Io.Clock.awake) catch {};
            }
            if (data.state.load(.monotonic) == 1) {
                if (data.result) |r| return try vm.clone(&r, allocator);
            }
            return vm.nilValue();
        },
        .promise => {
            // Block until delivered
            const data = val.promise;
            while (data.state.load(.monotonic) == 0) {
                const io = std.Io.Threaded.global_single_threaded.io();
                const duration = std.Io.Duration.fromMilliseconds(1);
                std.Io.sleep(io, duration, std.Io.Clock.awake) catch {};
            }
            if (data.value) |*v| return try vm.clone(v, allocator);
            return vm.nilValue();
        },
        else => return error.TypeError,
    }
}

/// Create a function value from FnMetadata, capturing current environment.
fn vmMakeFn(allocator: Allocator, meta: *const FnMetadata, env: *const vm.Env) anyerror!Value {
    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.bytecode) |bc| {
                bc.deinit(allocator);
                allocator.destroy(bc);
            }
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }
    try arities.ensureTotalCapacity(allocator, meta.arities.items.len);
    for (meta.arities.items) |a| {
        const cloned_params = try list.clone(&a.params, allocator);
        const cloned_rest = if (a.rest_name) |rn| try allocator.dupe(u8, rn) else null;
        try arities.append(allocator, vm.Arity{
            .params = cloned_params,
            .body = list.empty(), // empty body for bytecode functions
            .bytecode = a.bytecode, // share the bytecode pointer
            .rest_name = cloned_rest,
        });
    }
    // Create closure environment with a copy of current entries.
    // We can't share the HAMT because the current env may be freed.
    var new_entries = phm.PersistentHashMap.empty();
    var it = env.entries.entryIterator();
    while (it.next()) |entry| {
        new_entries = try new_entries.mapAssoc(allocator, entry.key, entry.val);
    }
    const fn_env: vm.Env = .{
        .allocator = allocator,
        .entries = new_entries,
        .parent = env.parent,
        .ns_manager = env.ns_manager,
    };
    var fn_val = try vm.fnValue(allocator, arities, fn_env, false);
    const persistent_fn = try vm.clone(&fn_val, allocator);
    vm.valueDeinit(&fn_val, allocator);
    return persistent_fn;
}

// ============================================================
// Compiler: AST → Bytecode
// ============================================================

/// Compile a Clojure AST (list.List) to bytecode.
/// The AST is a list where the first element is the operator and the rest are arguments.
/// env is optional — needed for macro expansion.
/// Returns a BytecodeProgram that can be executed by the VM.
pub fn compile(allocator: Allocator, ast: list.List, source_file: []const u8, env: ?*vm.Env) anyerror!BytecodeProgram {
    var program = BytecodeProgram.init(allocator);
    errdefer program.deinit(allocator);
    program.source_file = source_file;

    var compiler = Compiler{
        .allocator = allocator,
        .program = &program,
        .env = env,
    };

    // Compile each form in the body list.
    // If the body is wrapped in (do ...), skip the 'do' symbol and compile the rest.
    // This handles bodies from parseArityForms which wrap in (do body...).
    var forms = ast.items;
    if (forms.len > 0 and std.meta.activeTag(forms[0]) == .symbol and
        std.mem.eql(u8, forms[0].symbol, "do"))
    {
        forms = forms[1..];
    }
    for (forms) |form| {
        try compiler.compileForm(form);
    }
    _ = try program.emit0(allocator, .stop);

    return program;
}

const Compiler = struct {
    allocator: Allocator,
    program: *BytecodeProgram,
    env: ?*vm.Env, // for macro expansion

    /// Compile a form (any Clojure expression).
    fn compileForm(self: *Compiler, form: Value) anyerror!void {
        switch (form) {
            .nil => _ = try self.program.emit0(self.allocator, .push_nil),
            .bool => |b| _ = try self.program.emit0(self.allocator, if (b) .push_true else .push_false),
            .integer => |i| {
                // Store integer in constant pool since operand is usize (can't hold negative i64)
                const idx = try self.program.addConstant(self.allocator, vm.intValue(i));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
            .float => |f| {
                const idx = try self.program.addConstant(self.allocator, vm.floatValue(f));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
            .string, .keyword, .bigint, .ratio, .decimal, .regex, .character => {
                const idx = try self.program.addConstant(self.allocator, try vm.clone(&form, self.allocator));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
            .symbol => |s| {
                // Symbol reference: look up in environment
                const sym_idx = try self.program.addSymbol(self.allocator, s);
                _ = try self.program.emit(self.allocator, .load_var, sym_idx);
            },
            .list => {
                try self.compileList(form.list.items);
            },
            .vector => {
                try self.compileVector(form.vector.items);
            },
            .map => {
                try self.compileMap(form.map.entries);
            },
            .cons => {
                // Compile tail first, then head, then cons
                try self.compileCons(form.cons.*);
            },
            else => {
                // Functions, lazy_seqs, etc. are self-evaluating
                const idx = try self.program.addConstant(self.allocator, try vm.clone(&form, self.allocator));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
        }
    }

    /// Compile a list (function call or special form).
    fn compileList(self: *Compiler, l: list.List) anyerror!void {
        if (l.items.len == 0) {
            _ = try self.program.emit(self.allocator, .list_n, 0);
            return;
        }

        const first = l.items[0];

        // Check for special forms
        if (std.meta.activeTag(first) == .symbol) {
            const sym = first.symbol;

            // (quote form) — just push the form as a constant
            if (std.mem.eql(u8, sym, "quote")) {
                if (l.items.len == 2) {
                    const idx = try self.program.addConstant(self.allocator, try vm.clone(&l.items[1], self.allocator));
                    _ = try self.program.emit(self.allocator, .push_const, idx);
                    return;
                }
            }

            // (if test then else?) — compile to jump instructions
            if (std.mem.eql(u8, sym, "if")) {
                try self.compileIf(l.items);
                return;
            }

            // (do body...) — compile each form, last result is the value
            if (std.mem.eql(u8, sym, "do")) {
                try self.compileDo(l.items);
                return;
            }

            // (let [bindings] body...) — compile bindings and body
            if (std.mem.eql(u8, sym, "let")) {
                try self.compileLet(l.items);
                return;
            }

            // (var sym) / (deref form) / (@ form)
            if (std.mem.eql(u8, sym, "var") or std.mem.eql(u8, sym, "deref") or std.mem.eql(u8, sym, "@")) {
                if (l.items.len == 2) {
                    try self.compileForm(l.items[1]);
                    _ = try self.program.emit0(self.allocator, .deref);
                    return;
                }
            }

            // (set! sym val) — compile val, then store
            if (std.mem.eql(u8, sym, "set!")) {
                if (l.items.len == 3 and std.meta.activeTag(l.items[1]) == .symbol) {
                    try self.compileForm(l.items[2]);
                    const sym_idx = try self.program.addSymbol(self.allocator, l.items[1].symbol);
                    _ = try self.program.emit(self.allocator, .store_var, sym_idx);
                    return;
                }
            }

            // (fn name? ([params] body...)+)
            if (std.mem.eql(u8, sym, "fn")) {
                try self.compileFn(l.items);
                return;
            }

            // (and exprs...) — short-circuit logical and
            if (std.mem.eql(u8, sym, "and")) {
                try self.compileAnd(l.items);
                return;
            }

            // (or exprs...) — short-circuit logical or
            if (std.mem.eql(u8, sym, "or")) {
                try self.compileOr(l.items);
                return;
            }

            // (cond test1 result1 test2 result2 ... :else default)
            if (std.mem.eql(u8, sym, "cond")) {
                try self.compileCond(l.items);
                return;
            }

            // (when test body...) — sugar for (if test (do body...) nil)
            if (std.mem.eql(u8, sym, "when")) {
                try self.compileWhen(l.items);
                return;
            }

            // (loop [bindings] body...)
            if (std.mem.eql(u8, sym, "loop")) {
                try self.compileLoop(l.items);
                return;
            }

            // (recur val1 val2 ...)
            if (std.mem.eql(u8, sym, "recur")) {
                try self.compileRecur(l.items);
                return;
            }

            // Not a special form we handle — fall through to function call
            // But first check if it's a macro that needs expansion
            if (self.env) |e| {
                if (try self.tryExpandMacro(l, e)) |expanded_list| {
                    // Compile the expanded form(s)
                    for (expanded_list.items) |form| {
                        try self.compileForm(form);
                    }
                    return;
                }
            }
        }

        // Function call: compile all elements, then call_n
        try self.compileFunctionCall(l.items);
    }

    /// Compile a function call: (fn arg1 arg2 ...).
    fn compileFunctionCall(self: *Compiler, items: []const Value) anyerror!void {
        const n = items.len - 1; // number of arguments

        // Compile arguments first (they end up below fn on the stack)
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            try self.compileForm(items[i]);
        }

        // Compile the function (ends up on top of args)
        try self.compileForm(items[0]);

        // Call with n arguments
        _ = try self.program.emit(self.allocator, .call_n, n);
    }

    /// Try to expand a macro call. If the first element of the list is a macro,
    /// expand it and return the expanded form as a list.List.
    /// Returns null if the form is not a macro call or expansion fails.
    fn tryExpandMacro(self: *Compiler, l: list.List, env: *vm.Env) anyerror!?list.List {
        if (l.items.len == 0) return null;
        const first = l.items[0];
        if (std.meta.activeTag(first) != .symbol) return null;

        // Look up the symbol in the environment
        const op_val = env.get(first.symbol);
        if (op_val == null) return null;

        // Check if it's a macro
        if (std.meta.activeTag(op_val.?) != .function) return null;
        if (!op_val.?.function.is_macro) return null;

        // Build unevaluated args list
        var macro_args: list.List = .empty;
        defer macro_args.deinit(self.allocator);
        var i: usize = 1;
        while (i < l.items.len) : (i += 1) {
            try macro_args.append(self.allocator, try vm.clone(&l.items[i], self.allocator));
        }

        // Call the macro
        const macro_r = try eval_mod.call(self.allocator, &op_val.?, &macro_args, env, 0, null);
        defer vm.valueDeinit(macro_r.value, self.allocator);

        // The macro returns a form (usually a list). Clone and wrap it in a list for compilation.
        const cloned = try vm.clone(macro_r.value, self.allocator);
        var expanded: list.List = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.append(self.allocator, cloned);
        return expanded;
    }

    /// Compile (if test then else?).
    fn compileIf(self: *Compiler, items: []const Value) anyerror!void {
        if (items.len < 3) return;

        // Compile test
        try self.compileForm(items[1]);

        // jump-if-nil to else branch (placeholder)
        const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);

        // Compile then branch
        try self.compileForm(items[2]);

        // jump past else branch (placeholder)
        const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);

        // Patch jump-to-else target
        const else_pc = self.program.instructions.items.len;
        self.program.instructions.items[jump_to_else_pc].operand = else_pc;

        // Compile else branch (if present)
        if (items.len >= 4) {
            try self.compileForm(items[3]);
        } else {
            _ = try self.program.emit0(self.allocator, .push_nil);
        }

        // Patch jump-past-else target
        const past_else_pc = self.program.instructions.items.len;
        self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
    }

    /// Compile (do body...).
    fn compileDo(self: *Compiler, items: []const Value) anyerror!void {
        for (items[1..]) |form| {
            try self.compileForm(form);
        }
    }

    /// Compile (let [bindings] body...).
    fn compileLet(self: *Compiler, items: []const Value) anyerror!void {
        if (items.len < 3) return;

        const bindings = items[1];
        const body = items[2..];

        // Compile bindings: [sym1 val1 sym2 val2 ...]
        const bind_items: []const Value = switch (std.meta.activeTag(bindings)) {
            .list => bindings.list.items.items,
            .vector => bindings.vector.items.items,
            else => return,
        };

        var i: usize = 0;
        while (i < bind_items.len) : (i += 2) {
            const sym = bind_items[i];
            const val = bind_items[i + 1];

            // For now, let bindings are stored in the environment.
            // We compile the value, then store it.
            try self.compileForm(val);
            if (std.meta.activeTag(sym) == .symbol) {
                const sym_idx = try self.program.addSymbol(self.allocator, sym.symbol);
                _ = try self.program.emit(self.allocator, .store_var, sym_idx);
            }
        }

        // Compile body
        for (body) |form| {
            try self.compileForm(form);
        }
    }

    /// Compile a vector: [expr1 expr2 ...].
    fn compileVector(self: *Compiler, v: vec.Vector) anyerror!void {
        const n = v.items.len;
        for (v.items) |item| {
            try self.compileForm(item);
        }
        _ = try self.program.emit(self.allocator, .vector_n, n);
    }

    /// Compile a map: {k1 v1 k2 v2 ...}.
    fn compileMap(self: *Compiler, m: vm.Map) anyerror!void {
        const n = m.items.len;
        for (m.items) |entry| {
            try self.compileForm(entry.key);
            try self.compileForm(entry.value);
        }
        _ = try self.program.emit(self.allocator, .map_n, n);
    }

    /// Compile a cons cell: (cons head tail).
    fn compileCons(self: *Compiler, c: vm.ConsData) anyerror!void {
        try self.compileForm(c.tail);
        try self.compileForm(c.head);
        _ = try self.program.emit0(self.allocator, .cons);
    }

    /// Compile (fn name? ([params] body...)+).
    fn compileFn(self: *Compiler, items: []const Value) anyerror!void {
        if (items.len < 2) return;
        var idx: usize = 1;
        var fn_name: ?[]const u8 = null;

        // Optional name
        if (std.meta.activeTag(items[idx]) == .symbol) {
            fn_name = try self.allocator.dupe(u8, items[idx].symbol);
            idx += 1;
        }

        // Parse arities (similar to evalFn)
        var fn_arities: std.ArrayListUnmanaged(FnAridity) = .empty;
        errdefer {
            for (fn_arities.items) |*a| {
                a.params.deinit(self.allocator);
                if (a.bytecode) |bc| {
                    bc.deinit(self.allocator);
                    self.allocator.destroy(bc);
                }
                if (a.rest_name) |rn| self.allocator.free(rn);
            }
            fn_arities.deinit(self.allocator);
        }

        while (idx < items.len) {
            const form = items[idx];
            idx += 1;

            var params_list: list.List = undefined;
            var body_forms: []const Value = undefined;

            if (std.meta.activeTag(form) == .vector) {
                // Flattened: (fn [x] body [y] body2)
                params_list = try listFromVector(self.allocator, form.vector.items);
                const body_start = idx;
                while (idx < items.len) {
                    const next = items[idx];
                    if (looksLikeParamList(next) and idx + 1 < items.len) break;
                    idx += 1;
                }
                body_forms = items[body_start..idx];
            } else if (std.meta.activeTag(form) == .list) {
                // Wrapped: (fn ([x] body))
                if (form.list.items.items.len == 0) return;
                const inner_first = form.list.items.items[0];
                if (std.meta.activeTag(inner_first) == .vector) {
                    params_list = try listFromVector(self.allocator, inner_first.vector.items);
                    body_forms = form.list.items.items[1..];
                } else {
                    params_list = form.list.items;
                    const body_start = idx;
                    while (idx < items.len) {
                        const next = items[idx];
                        if (looksLikeParamList(next) and idx + 1 < items.len) break;
                        idx += 1;
                    }
                    body_forms = items[body_start..idx];
                }
            } else {
                continue;
            }

            // Parse params for rest
            var parsed = try parseParams(self.allocator, params_list);
            defer {
                parsed.params.deinit(self.allocator);
                if (parsed.rest_name) |rn| self.allocator.free(rn);
            }

            // Check if body contains unhandled special forms — skip bytecode if so
            // loop/recur is now supported in bytecode (Phase 5).
            var skip_bytecode = false;
            for (body_forms) |bf| {
                if (containsUnhandledSpecialFormHelper(bf)) { skip_bytecode = true; break; }
            }
            // Also skip if params contain destructuring patterns
            if (!skip_bytecode) {
                var pi: usize = 0;
                while (pi < parsed.params.items.len) : (pi += 1) {
                    switch (std.meta.activeTag(parsed.params.items[pi])) {
                        .vector, .list => { skip_bytecode = true; break; },
                        else => {},
                    }
                }
            }

            var bc_ptr: ?*BytecodeProgram = null;
            if (!skip_bytecode) {
                // Compile body to bytecode
                var body_list: list.List = .empty;
                errdefer body_list.deinit(self.allocator);
                try body_list.append(self.allocator, try vm.symValue(self.allocator, "do"));
                for (body_forms) |bf| {
                    try body_list.append(self.allocator, try vm.clone(&bf, self.allocator));
                }
                const bc = try compile(self.allocator, body_list, "<fn>", self.env);
                const bc_created = try self.allocator.create(BytecodeProgram);
                bc_created.* = bc;
                bc_ptr = bc_created;
            }

            const cloned_params = try list.clone(&parsed.params, self.allocator);
            const cloned_rest = if (parsed.rest_name) |rn| try self.allocator.dupe(u8, rn) else null;
            try fn_arities.append(self.allocator, FnAridity{
                .params = cloned_params,
                .bytecode = bc_ptr,
                .rest_name = cloned_rest,
            });
        }

        // Create FnMetadata and add to pool
        const meta = try self.allocator.create(FnMetadata);
        meta.* = .{
            .arities = fn_arities,
            .name = fn_name,
            .allocator = self.allocator,
        };

        // Add to fn_pool
        if (self.program.fn_pool == null) {
            self.program.fn_pool = try self.allocator.alloc(*FnMetadata, 1);
            self.program.fn_pool.?[0] = meta;
        } else {
            const old_pool = self.program.fn_pool.?;
            const new_pool = try self.allocator.realloc(old_pool, old_pool.len + 1);
            new_pool[old_pool.len] = meta;
            self.program.fn_pool = new_pool;
        }
        const meta_idx = self.program.fn_pool.?.len - 1;

        _ = try self.program.emit(self.allocator, .make_fn, meta_idx);
    }

    /// Compile (and exprs...) — short-circuit logical and.
    fn compileAnd(self: *Compiler, items: []const Value) anyerror!void {
        const forms = items[1..];
        if (forms.len == 0) {
            _ = try self.program.emit0(self.allocator, .push_true);
            return;
        }
        if (forms.len == 1) {
            try self.compileForm(forms[0]);
            return;
        }
        const tmp_idx = try self.program.addSymbol(self.allocator, "__and_tmp");
        for (forms) |form| {
            try self.compileForm(form);
            _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
            _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
            _ = try self.program.emit(self.allocator, .jump_if_nil, 0);
        }
        const end_pc = self.program.instructions.items.len;
        _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
        var i: usize = end_pc;
        while (i > 0) : (i -= 1) {
            if (self.program.instructions.items[i].opcode == .jump_if_nil) {
                self.program.instructions.items[i].operand = end_pc;
            }
        }
        if (end_pc > 0 and self.program.instructions.items[0].opcode == .jump_if_nil) {
            self.program.instructions.items[0].operand = end_pc;
        }
    }

    /// Compile (or exprs...) — short-circuit logical or.
    fn compileOr(self: *Compiler, items: []const Value) anyerror!void {
        const forms = items[1..];
        if (forms.len == 0) {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        }
        if (forms.len == 1) {
            try self.compileForm(forms[0]);
            return;
        }
        const tmp_idx = try self.program.addSymbol(self.allocator, "__or_tmp");
        for (forms) |form| {
            try self.compileForm(form);
            _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
            _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
            _ = try self.program.emit(self.allocator, .jump_if_not_nil, 0);
        }
        const end_pc = self.program.instructions.items.len;
        _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
        var i: usize = end_pc;
        while (i > 0) : (i -= 1) {
            if (self.program.instructions.items[i].opcode == .jump_if_not_nil) {
                self.program.instructions.items[i].operand = end_pc;
            }
        }
        if (end_pc > 0 and self.program.instructions.items[0].opcode == .jump_if_not_nil) {
            self.program.instructions.items[0].operand = end_pc;
        }
    }

    /// Compile (cond test1 result1 test2 result2 ... :else default).
    fn compileCond(self: *Compiler, items: []const Value) anyerror!void {
        const clauses = items[1..];
        if (clauses.len == 0) {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        }
        var clause_starts: std.ArrayListUnmanaged(usize) = .empty;
        defer clause_starts.deinit(self.allocator);
        var jump_nil_pcs: std.ArrayListUnmanaged(usize) = .empty;
        defer jump_nil_pcs.deinit(self.allocator);
        var jump_end_pcs: std.ArrayListUnmanaged(usize) = .empty;
        defer jump_end_pcs.deinit(self.allocator);
        var i: usize = 0;
        while (i < clauses.len) : (i += 2) {
            const cond_test = clauses[i];
            const is_else = std.meta.activeTag(cond_test) == .keyword and
                std.mem.eql(u8, cond_test.keyword, "else");
            try clause_starts.append(self.allocator, self.program.instructions.items.len);
            if (is_else) {
                if (i + 1 < clauses.len) {
                    try self.compileForm(clauses[i + 1]);
                }
            } else {
                try self.compileForm(cond_test);
                const jnil_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
                try jump_nil_pcs.append(self.allocator, jnil_pc);
                if (i + 1 < clauses.len) {
                    try self.compileForm(clauses[i + 1]);
                }
                const jump_pc = try self.program.emit(self.allocator, .jump, 0);
                try jump_end_pcs.append(self.allocator, jump_pc);
            }
        }
        const end_pc = self.program.instructions.items.len;
        var j: usize = 0;
        while (j < jump_nil_pcs.items.len) : (j += 1) {
            const target = clause_starts.items[j + 1];
            self.program.instructions.items[jump_nil_pcs.items[j]].operand = target;
        }
        for (jump_end_pcs.items) |pc| {
            self.program.instructions.items[pc].operand = end_pc;
        }
    }

    /// Compile (when test body...) — sugar for (if test (do body...) nil).
    fn compileWhen(self: *Compiler, items: []const Value) anyerror!void {
        if (items.len < 2) {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        }
        try self.compileForm(items[1]);
        const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
        const body = items[2..];
        for (body) |form| {
            try self.compileForm(form);
        }
        const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);
        const else_pc = self.program.instructions.items.len;
        self.program.instructions.items[jump_to_else_pc].operand = else_pc;
        _ = try self.program.emit0(self.allocator, .push_nil);
        const past_else_pc = self.program.instructions.items.len;
        self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
    }

    /// Compile (loop [bindings] body...).
    /// Emits: binding value compilations + store_var for each binding,
    /// then loop_start (with index into loop_infos), then body forms.
    fn compileLoop(self: *Compiler, items: []const Value) anyerror!void {
        if (items.len < 3) {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        }

        const bindings = items[1];
        const body = items[2..];

        // Parse bindings: [sym1 val1 sym2 val2 ...]
        const bind_items: []const Value = switch (std.meta.activeTag(bindings)) {
            .list => bindings.list.items.items,
            .vector => bindings.vector.items.items,
            else => {
                _ = try self.program.emit0(self.allocator, .push_nil);
                return;
            },
        };

        // Collect binding symbol indices
        const binding_count = bind_items.len / 2;
        var sym_indices: []usize = try self.allocator.alloc(usize, binding_count);

        // Compile initial bindings: evaluate values, store in env
        var i: usize = 0;
        while (i < bind_items.len) : (i += 2) {
            const sym = bind_items[i];
            const val = bind_items[i + 1];

            // Record symbol index for recur
            if (std.meta.activeTag(sym) == .symbol) {
                sym_indices[i / 2] = try self.program.addSymbol(self.allocator, sym.symbol);
            }

            // Compile value and store
            try self.compileForm(val);
            if (std.meta.activeTag(sym) == .symbol) {
                _ = try self.program.emit(self.allocator, .store_var, sym_indices[i / 2]);
            }
        }

        // Record body_pc (PC after loop_start)
        const body_pc = self.program.instructions.items.len;

        // Add loop info and emit loop_start
        const loop_info_idx = try self.program.addLoopInfo(self.allocator, body_pc, sym_indices);
        _ = try self.program.emit(self.allocator, .loop_start, loop_info_idx);

        // Compile body forms
        for (body) |form| {
            try self.compileForm(form);
        }
    }

    /// Compile (recur val1 val2 ...).
    /// Values must be compiled in REVERSE order so that the recur handler
    /// (which pops all values then iterates in reverse) assigns them correctly.
    /// Stack after: ..., valN, ..., val2, val1  (val1 on top = first binding)
    fn compileRecur(self: *Compiler, items: []const Value) anyerror!void {
        const args = items[1..];
        // Compile in reverse order: last arg first, first arg last
        var i: usize = args.len;
        while (i > 0) : (i -= 1) {
            try self.compileForm(args[i - 1]);
        }
        // Emit recur opcode
        _ = try self.program.emit0(self.allocator, .recur);
    }
};

// Helper functions used by compiler

/// Check if a form (or any nested form) contains loop or recur.
/// Used to decide whether to skip bytecode compilation.
pub fn containsLoopRecur(form: Value) bool {
    return containsLoopRecurHelper(form);
}

/// Check if a list.List contains loop or recur.
pub fn containsLoopRecurInList(l: list.List) bool {
    return containsLoopRecurInItems(l.items);
}

/// Check if a list contains any function calls (list forms).
/// Used to decide whether to skip bytecode compilation.
/// Bytecode has issues with symbol resolution for called functions,
/// so we skip bytecode for bodies that call other functions.
pub fn containsFunctionCallsInList(l: list.List) bool {
    return containsFunctionCallsInItems(l.items);
}

fn containsFunctionCallsInItems(items: []const Value) bool {
    for (items) |item| {
        if (containsFunctionCallsHelper(item)) return true;
    }
    return false;
}

fn containsFunctionCallsHelper(form: Value) bool {
    switch (form) {
        .list => {
            const lst_items = form.list.items.items;
            // A list is a function call (unless it's empty)
            if (lst_items.len > 0) return true;
            return false;
        },
        .vector => {
            for (form.vector.items.items) |item| {
                if (containsFunctionCallsHelper(item)) return true;
            }
            return false;
        },
        .map => {
            for (form.map.entries.items) |entry| {
                if (containsFunctionCallsHelper(entry.key)) return true;
                if (containsFunctionCallsHelper(entry.value)) return true;
            }
            return false;
        },
        .cons => {
            if (containsFunctionCallsHelper(form.cons.head)) return true;
            if (containsFunctionCallsHelper(form.cons.tail)) return true;
            return false;
        },
        else => return false,
    }
}

fn containsLoopRecurInItems(items: []const Value) bool {
    if (items.len > 0 and std.meta.activeTag(items[0]) == .symbol) {
        const sym = items[0].symbol;
        if (std.mem.eql(u8, sym, "loop") or std.mem.eql(u8, sym, "recur")) {
            return true;
        }
    }
    for (items) |item| {
        if (containsLoopRecurHelper(item)) return true;
    }
    return false;
}

fn containsLoopRecurHelper(form: Value) bool {
    switch (form) {
        .list => return containsLoopRecurInItems(form.list.items.items),
        .vector => {
            for (form.vector.items.items) |item| {
                if (containsLoopRecurHelper(item)) return true;
            }
            return false;
        },
        .map => {
            for (form.map.entries.items) |entry| {
                if (containsLoopRecurHelper(entry.key)) return true;
                if (containsLoopRecurHelper(entry.value)) return true;
            }
            return false;
        },
        .cons => {
            if (containsLoopRecurHelper(form.cons.head)) return true;
            if (containsLoopRecurHelper(form.cons.tail)) return true;
            return false;
        },
        else => return false,
    }
}

/// Check if a params list contains destructuring patterns (vectors/lists).
/// Bytecode VM does not support destructuring.
pub fn containsDestructuring(params: list.List) bool {
    for (params.items) |param| {
        switch (std.meta.activeTag(param)) {
            .vector, .list => return true,
            else => {},
        }
    }
    return false;
}

/// Check if a list contains any special forms that the bytecode compiler
/// does not yet handle. These forms would be incorrectly treated as
/// function calls, causing "Undefined symbol" errors at runtime.
pub fn containsUnhandledSpecialFormInList(l: list.List) bool {
    return containsUnhandledSpecialFormInItems(l.items);
}

fn containsUnhandledSpecialFormInItems(items: []const Value) bool {
    for (items) |item| {
        if (containsUnhandledSpecialFormHelper(item)) return true;
    }
    return false;
}

fn containsUnhandledSpecialFormHelper(form: Value) bool {
    switch (form) {
        .list => {
            const lst_items = form.list.items.items;
            if (lst_items.len == 0) return false;
            // Check if the first element is a symbol matching an unhandled special form
            if (std.meta.activeTag(lst_items[0]) == .symbol) {
                const sym = lst_items[0].symbol;
                // List of special forms not yet compiled to bytecode.
                // and, or, cond, when are now compiled (Phase 3).
                // Macros (when-not, when-let, when-some, when-first, if-let)
                // are kept here because bytecode macro expansion is not reliable.
                if (std.mem.eql(u8, sym, "when-not") or
                    std.mem.eql(u8, sym, "when-let") or
                    std.mem.eql(u8, sym, "when-some") or
                    std.mem.eql(u8, sym, "when-first") or
                    std.mem.eql(u8, sym, "if-let") or
                    std.mem.eql(u8, sym, "case") or
                    std.mem.eql(u8, sym, "quasiquote") or
                    std.mem.eql(u8, sym, "letfn") or
                    std.mem.eql(u8, sym, "binding") or
                    std.mem.eql(u8, sym, "lazy-seq") or
                    std.mem.eql(u8, sym, "dorun") or
                    std.mem.eql(u8, sym, "doall") or
                    std.mem.eql(u8, sym, "->") or
                    std.mem.eql(u8, sym, "->>") or
                    std.mem.eql(u8, sym, "cond->") or
                    std.mem.eql(u8, sym, "cond->>"))
                {
                    return true;
                }
            }
            // Recurse into all items
            for (lst_items) |item| {
                if (containsUnhandledSpecialFormHelper(item)) return true;
            }
            return false;
        },
        .vector => {
            for (form.vector.items.items) |item| {
                if (containsUnhandledSpecialFormHelper(item)) return true;
            }
            return false;
        },
        .map => {
            for (form.map.entries.items) |entry| {
                if (containsUnhandledSpecialFormHelper(entry.key)) return true;
                if (containsUnhandledSpecialFormHelper(entry.value)) return true;
            }
            return false;
        },
        .cons => {
            if (containsUnhandledSpecialFormHelper(form.cons.head)) return true;
            if (containsUnhandledSpecialFormHelper(form.cons.tail)) return true;
            return false;
        },
        else => return false,
    }
}

fn listFromVector(allocator: Allocator, v: vec.Vector) anyerror!list.List {
    var l: list.List = .empty;
    errdefer l.deinit(allocator);
    for (v.items) |item| {
        try l.append(allocator, try vm.clone(&item, allocator));
    }
    return l;
}

fn looksLikeParamList(form: Value) bool {
    const items = switch (std.meta.activeTag(form)) {
        .vector => form.vector.items.items,
        .list => form.list.items.items,
        else => return false,
    };
    if (items.len == 0) return false;
    var found_amp = false;
    for (items) |item| {
        if (std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.symbol, "&")) {
            if (found_amp) return false;
            found_amp = true;
            continue;
        }
        if (std.meta.activeTag(item) != .symbol) return false;
    }
    return true;
}

const ParsedParams = struct {
    params: list.List,
    rest_name: ?[]const u8,
};

fn parseParams(allocator: Allocator, params: list.List) anyerror!ParsedParams {
    var regular_params: list.List = .empty;
    errdefer regular_params.deinit(allocator);
    var rest_name: ?[]const u8 = null;

    var i: usize = 0;
    var found_amp = false;
    while (i < params.items.len) : (i += 1) {
        const item = params.items[i];
        if (!found_amp and std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.symbol, "&")) {
            found_amp = true;
            continue;
        }
        if (found_amp) {
            if (std.meta.activeTag(item) != .symbol) return error.TypeError;
            rest_name = try allocator.dupe(u8, item.symbol);
            break;
        } else {
            try regular_params.append(allocator, try vm.clone(&item, allocator));
        }
    }

    return ParsedParams{ .params = regular_params, .rest_name = rest_name };
}

// ============================================================
// GC scanning for BytecodeProgram
// ============================================================

/// Scan a BytecodeProgram for GC roots.
/// Called by gc_scan.zig to find Value pointers in bytecode programs.
pub fn scanGC(program: *const BytecodeProgram, scanFn: fn (*anyopaque) void) void {
    for (program.constants.items) |*v| {
        scanFn(v);
    }
}

test "bytecode::opCodeName: returns string for each opcode" {
    // Just verify we can get names for a few opcodes
    _ = BytecodeProgram.opcodeName(.push_nil);
    _ = BytecodeProgram.opcodeName(.call_n);
    _ = BytecodeProgram.opcodeName(.ret);
    _ = BytecodeProgram.opcodeName(.nop);
}

test "bytecode::program: init and deinit" {
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit0(allocator, .push_nil);
    _ = try program.emit0(allocator, .ret);
}

test "bytecode::vm: push and return" {
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    _ = try program.emit(allocator, .push_int, 42);
    _ = try program.emit0(allocator, .ret);

    // Create a minimal env
    var env: vm.Env = .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = null,
        .ns_manager = null,
        .referred_names = .empty,
    };
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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

// ============================================================
// Test helper: compile-and-execute pipeline
// ============================================================
// Helper to create a minimal environment for bytecode testing.
fn createTestEnv(allocator: Allocator) vm.Env {
    return .{
        .allocator = allocator,
        .entries = phm.PersistentHashMap.empty(),
        .parent = null,
        .ns_manager = null,
        .referred_names = .empty,
    };
}

test "bytecode::compile: literal nil" {
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit0(allocator, .push_nil);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit(allocator, .push_int, 123);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    _ = try program.emit0(allocator, .push_true);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);
    const sym_idx = try program.addSymbol(allocator, "x");
    _ = try program.emit(allocator, .load_var, sym_idx);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);
    try env.put("x", vm.intValue(99));

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    // push true, jump-if-nil -> else, push 1, jump -> end, push 2
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

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    // push nil, jump-if-nil -> else, push 1, jump -> end, push 2
    // nil triggers jump_if_nil, so we get the else branch (2)
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

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
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

    const result = try execute(allocator, &program, &env, null);
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

// Note: first/rest/count opcode tests are integration-tested via the
// full Clojure test suite (test_lists_sequences.clj, test_collections.clj).
// Standalone unit tests have subtle allocator interactions with ListData
// ownership that are exercised correctly through the normal eval path.

// ============================================================
// Phase 4: Full numeric tower arithmetic tests
// ============================================================

/// Create a test environment with arithmetic builtins registered.
fn createTestEnvWithArithmetic(allocator: Allocator) vm.Env {
    var env = createTestEnv(allocator);
    // Register arithmetic builtins for delegation path
    env.put("+", vm.builtinFnValue(arithmetic.core_plus)) catch unreachable;
    env.put("-", vm.builtinFnValue(arithmetic.core_minus)) catch unreachable;
    env.put("*", vm.builtinFnValue(arithmetic.core_mult)) catch unreachable;
    env.put("/", vm.builtinFnValue(arithmetic.core_div)) catch unreachable;
    env.put("rem", vm.builtinFnValue(arithmetic.core_rem)) catch unreachable;
    return env;
}

test "bytecode::arithmetic: bigint add" {
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    // Use values that produce a result exceeding i64 max
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

    const result = try execute(allocator, &program, &env, null);
    switch (result) {
        .value => |v| {
            // i64.max + i64.max = 18446744073709551614 (exceeds i64, must be bigint)
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
    const allocator = std.testing.allocator;
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

    const result = try execute(allocator, &program, &env, null);
    switch (result) {
        .value => |v| {
            // 10000000000000000000 - 42 = 9999999999999999958 (exceeds i64)
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
    const allocator = std.testing.allocator;
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

    const result = try execute(allocator, &program, &env, null);
    switch (result) {
        .value => |v| {
            // 10^18 * 10^18 = 10^36 (way exceeds i64)
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
    const allocator = std.testing.allocator;
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

    const result = try execute(allocator, &program, &env, null);
    switch (result) {
        .value => |v| {
            // 42 + 12345678901234567890 = 12345678901234567932
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
    const allocator = std.testing.allocator;
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

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const val_idx = try program.addConstant(allocator, vm.intValue(42));
    _ = try program.emit(allocator, .push_const, val_idx);
    _ = try program.emit0(allocator, .neg);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    const val_idx = try program.addConstant(allocator, vm.floatValue(3.14));
    _ = try program.emit(allocator, .push_const, val_idx);
    _ = try program.emit0(allocator, .neg);
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
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

    const result = try execute(allocator, &program, &env, null);
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

// ============================================================
// Phase 5: loop/recur bytecode tests
// ============================================================

test "bytecode::loop_recur: simple counter" {
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    // Simulate: (loop [i 0] (if (>= i 5) i (recur (inc i))))
    // But without function calls, we use direct comparisons and arithmetic
    // loop [i 0] -> push 0, store i, loop_start
    // if (>= i 5) i (recur (inc i))
    //   load i, push 5, ge, jump_if_nil -> recur_branch, load i, jump -> end
    //   recur_branch: load i, push 1, add, recur

    const sym_i = try program.addSymbol(allocator, "i");

    // Initial binding: i = 0
    const zero_idx = try program.addConstant(allocator, vm.intValue(0));
    _ = try program.emit(allocator, .push_const, zero_idx);
    _ = try program.emit(allocator, .store_var, sym_i);

    // loop_start (body starts at next instruction)
    const body_pc = program.instructions.items.len;
    const sym_indices = try allocator.alloc(usize, 1);
    sym_indices[0] = sym_i;
    const loop_idx = try program.addLoopInfo(allocator, body_pc, sym_indices);
    _ = try program.emit(allocator, .loop_start, loop_idx);

    // Body: (if (>= i 5) i (recur (inc i)))
    // Load i
    _ = try program.emit(allocator, .load_var, sym_i);
    // Push 5
    const five_idx = try program.addConstant(allocator, vm.intValue(5));
    _ = try program.emit(allocator, .push_const, five_idx);
    // ge (>=)
    _ = try program.emit0(allocator, .ge);
    // jump_if_nil -> recur_branch
    const jump_nil_pc = try program.emit(allocator, .jump_if_nil, 0);
    // Then branch: load i (return it)
    _ = try program.emit(allocator, .load_var, sym_i);
    // Jump to end
    const jump_end_pc = try program.emit(allocator, .jump, 0);

    // Recur branch: load i, push 1, add, recur
    const recur_pc = program.instructions.items.len;
    program.instructions.items[jump_nil_pc].operand = recur_pc;
    _ = try program.emit(allocator, .load_var, sym_i);
    const one_idx = try program.addConstant(allocator, vm.intValue(1));
    _ = try program.emit(allocator, .push_const, one_idx);
    _ = try program.emit0(allocator, .add);
    _ = try program.emit0(allocator, .recur);

    // End
    const end_pc = program.instructions.items.len;
    program.instructions.items[jump_end_pc].operand = end_pc;
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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
    const allocator = std.testing.allocator;
    var program = BytecodeProgram.init(allocator);
    defer program.deinit(allocator);

    // Simulate: (loop [i 3 s 0] (if (<= i 0) s (recur (dec i) (+ s i))))
    // Result: 3 + 2 + 1 = 6

    const sym_i = try program.addSymbol(allocator, "i");
    const sym_s = try program.addSymbol(allocator, "s");

    // Initial bindings: i = 3, s = 0
    const three_idx = try program.addConstant(allocator, vm.intValue(3));
    _ = try program.emit(allocator, .push_const, three_idx);
    _ = try program.emit(allocator, .store_var, sym_i);
    const zero_idx = try program.addConstant(allocator, vm.intValue(0));
    _ = try program.emit(allocator, .push_const, zero_idx);
    _ = try program.emit(allocator, .store_var, sym_s);

    // loop_start
    const body_pc = program.instructions.items.len;
    const sym_indices = try allocator.alloc(usize, 2);
    sym_indices[0] = sym_i;
    sym_indices[1] = sym_s;
    const loop_idx = try program.addLoopInfo(allocator, body_pc, sym_indices);
    _ = try program.emit(allocator, .loop_start, loop_idx);

    // Body: (if (<= i 0) s (recur (dec i) (+ s i)))
    // Load i, push 0, le
    _ = try program.emit(allocator, .load_var, sym_i);
    _ = try program.emit(allocator, .push_const, zero_idx);
    _ = try program.emit0(allocator, .le);
    // jump_if_nil -> recur_branch
    const jump_nil_pc = try program.emit(allocator, .jump_if_nil, 0);
    // Then: load s
    _ = try program.emit(allocator, .load_var, sym_s);
    // Jump to end
    const jump_end_pc = try program.emit(allocator, .jump, 0);

    // Recur: values must be pushed in REVERSE binding order.
    // The recur handler pops all values, then iterates in reverse.
    // So: push last binding value first, first binding value last.
    // Stack after pushes: ..., new_s, new_i  (new_i on top)
    // recur pops: val0=new_i, val1=new_s → reverse → binding[0]=new_i, binding[1]=new_s ✓
    const recur_pc = program.instructions.items.len;
    program.instructions.items[jump_nil_pc].operand = recur_pc;
    const one_idx = try program.addConstant(allocator, vm.intValue(1));
    // (+ s i) — push first (last binding value)
    _ = try program.emit(allocator, .load_var, sym_s);
    _ = try program.emit(allocator, .load_var, sym_i);
    _ = try program.emit0(allocator, .add);
    // (dec i) = (- i 1) — push second (first binding value, on top)
    _ = try program.emit(allocator, .load_var, sym_i);
    _ = try program.emit(allocator, .push_const, one_idx);
    _ = try program.emit0(allocator, .sub);
    _ = try program.emit0(allocator, .recur);

    const end_pc = program.instructions.items.len;
    program.instructions.items[jump_end_pc].operand = end_pc;
    _ = try program.emit0(allocator, .stop);

    var env = createTestEnv(allocator);
    defer env.deinit(allocator);

    const result = try execute(allocator, &program, &env, null);
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
