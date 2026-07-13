// Bytecode compiler and VM for ClojureZ.
// Compiles Clojure AST (list.List) to bytecode for faster repeated execution.
// Uses a stack-based VM with a constant pool.
//
// This file is the coordinator module that re-exports all sub-modules.
// Split into:
//   bytecode/instructions.zig    — OpCode, Instruction, BytecodeProgram, SourceMarker, LoopInfo
//   bytecode/vm_types.zig        — StackEntry, OperandStack, VMResult, LoopFrame, FnAridity, FnMetadata
//   bytecode/vm_ops.zig          — compareOp, arithmeticOp, vmFirst, vmRest, vmCount, vmGet, etc.
//   bytecode/vm.zig              — execute()
//   bytecode/compiler.zig        — compile(), Compiler struct
//   bytecode/compiler_helpers.zig — isSimpleBytecodeForm, isBytecodeOptimizableOperator, etc.
//   bytecode/compiler_special_forms.zig — compileIf, compileFn, compileAnd, etc.
//   bytecode/gc.zig              — scanGC

const bc = @import("bytecode/instructions.zig");
const vmt = @import("bytecode/vm_types.zig");
const vmo = @import("bytecode/vm_ops.zig");
const vm_mod = @import("bytecode/vm.zig");
const compiler = @import("bytecode/compiler.zig");
const ch = @import("bytecode/compiler_helpers.zig");
const gc = @import("bytecode/gc.zig");

// ============================================================
// Re-export public types
// ============================================================

pub const Instruction = bc.Instruction;
pub const OpCode = bc.OpCode;
pub const SourceMarker = bc.SourceMarker;
pub const LoopInfo = bc.LoopInfo;
pub const BytecodeProgram = bc.BytecodeProgram;

pub const MAX_STACK_DEPTH = vmt.MAX_STACK_DEPTH;
pub const StackEntry = vmt.StackEntry;
pub const OperandStack = vmt.OperandStack;
pub const VMResult = vmt.VMResult;
pub const LoopFrame = vmt.LoopFrame;
pub const FnAridity = vmt.FnAridity;
pub const FnMetadata = vmt.FnMetadata;

// ============================================================
// Re-export public functions
// ============================================================

/// Compile a Clojure AST (list.List) to bytecode.
pub const compile = compiler.compile;

/// Execute a BytecodeProgram with the given environment.
pub const execute = vm_mod.execute;

/// Print a detailed bytecode error message.
pub const reportBytecodeError = vm_mod.reportBytecodeError;

/// Scan a BytecodeProgram for GC roots.
pub const scanGC = gc.scanGC;

/// Check if a list contains any REAL function calls (not arithmetic/comparison).
pub const containsRealFunctionCallsInList = ch.containsRealFunctionCallsInList;

/// Check if a params list contains destructuring patterns (vectors/lists).
pub const containsDestructuring = ch.containsDestructuring;

/// Check if a list contains any special forms that the bytecode compiler does not yet handle.
pub const containsUnhandledSpecialFormInList = ch.containsUnhandledSpecialFormInList;

// ============================================================
// Tests (imported from separate file to keep this file small)
// ============================================================

const _tests = @import("bytecode/bytecode_tests.zig");
