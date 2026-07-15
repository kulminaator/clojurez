// VM execution types: StackEntry, OperandStack, VMResult, LoopFrame, FnAridity, FnMetadata.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;
const list = @import("../list.zig");
const eval_mod = @import("../eval.zig");
const bc = @import("instructions.zig");

const Allocator = std.mem.Allocator;

/// Maximum depth of the bytecode operand stack.
/// Bytecode programs have bounded stack depth determined at compile time.
/// 64 is sufficient for all current bytecode functions.
pub const MAX_STACK_DEPTH: usize = 64;

/// A single entry on the bytecode operand stack.
/// Stores primitives inline to avoid GC allocation for arithmetic (Phase 2).
pub const StackEntry = union(Tag) {
    integer: i64,
    float: f64,
    pointer: *Value,

    pub const Tag = enum(u2) {
        integer = 0,
        float = 1,
        pointer = 2,
    };

    /// Convert this entry to a *Value (allocating if needed).
    pub fn toValue(self: StackEntry, allocator: Allocator) anyerror!*Value {
        return switch (self) {
            .integer => |v| eval_mod.allocValue(allocator, vm.intValue(v)),
            .float => |v| eval_mod.allocValue(allocator, vm.floatValue(v)),
            .pointer => |v| v,
        };
    }

    /// Extract integer, converting float if needed.
    pub fn toInteger(self: StackEntry) anyerror!i64 {
        return switch (self) {
            .integer => |v| v,
            .float => |v| @as(i64, @intFromFloat(v)),
            .pointer => |v| switch (v.*) {
                .integer => v.integer,
                .float => |fv| @as(i64, @intFromFloat(fv)),
                else => return error.TypeError,
            },
        };
    }

    /// Extract float, converting integer if needed.
    pub fn toFloat(self: StackEntry) anyerror!f64 {
        return switch (self) {
            .integer => |v| @as(f64, @floatFromInt(v)),
            .float => |v| v,
            .pointer => |v| switch (v.*) {
                .integer => |iv| @as(f64, @floatFromInt(iv)),
                .float => v.float,
                else => return error.TypeError,
            },
        };
    }

    /// Check if this entry is nil (only possible via pointer).
    pub fn isNil(self: StackEntry) bool {
        return switch (self) {
            .integer => false,
            .float => false,
            .pointer => |v| std.meta.activeTag(v.*) == .nil,
        };
    }

    /// Check if this entry is truthy (nil/false are falsy).
    pub fn isTruthy(self: StackEntry) bool {
        return switch (self) {
            .integer => true,
            .float => true,
            .pointer => |v| vm.isTruthy(v.*),
        };
    }

    /// Determine the effective numeric tag for arithmetic dispatch.
    pub fn numericTag(self: StackEntry) std.meta.Tag(Value) {
        return switch (self) {
            .integer => .integer,
            .float => .float,
            .pointer => |v| std.meta.activeTag(v.*),
        };
    }

    /// Get the Value for comparison/delegation (for pointer entries).
    pub fn toValueConst(self: StackEntry) Value {
        return switch (self) {
            .integer => |v| vm.intValue(v),
            .float => |v| vm.floatValue(v),
            .pointer => |v| v.*,
        };
    }
};

/// The VM operand stack.
/// Uses a fixed-size array of StackEntry to avoid GC allocation on every push
/// (Phase 1: fixed-size, Phase 2: primitive values).
pub const OperandStack = struct {
    items: [MAX_STACK_DEPTH]StackEntry = undefined,
    top: usize = 0,

    pub fn init(_: Allocator) OperandStack {
        return .{ .items = undefined, .top = 0 };
    }

    pub fn deinit(self: *OperandStack) void {
        // No allocation to free — items are owned by caller/GC.
        self.top = 0;
    }

    /// Push a pointer entry (for complex types: strings, lists, functions, etc.)
    pub fn pushPtr(self: *OperandStack, val: *Value) anyerror!void {
        if (self.top >= MAX_STACK_DEPTH) return error.StackOverflow;
        self.items[self.top] = StackEntry{ .pointer = val };
        self.top += 1;
    }

    /// Push an integer directly (no allocation)
    pub fn pushInt(self: *OperandStack, val: i64) anyerror!void {
        if (self.top >= MAX_STACK_DEPTH) return error.StackOverflow;
        self.items[self.top] = StackEntry{ .integer = val };
        self.top += 1;
    }

    /// Push a float directly (no allocation)
    pub fn pushFloat(self: *OperandStack, val: f64) anyerror!void {
        if (self.top >= MAX_STACK_DEPTH) return error.StackOverflow;
        self.items[self.top] = StackEntry{ .float = val };
        self.top += 1;
    }

    /// Push a *Value (legacy compatibility — stores as pointer)
    pub fn push(self: *OperandStack, val: *Value) anyerror!void {
        return self.pushPtr(val);
    }

    /// Pop a StackEntry.
    pub fn pop(self: *OperandStack) ?StackEntry {
        if (self.top == 0) return null;
        self.top -= 1;
        return self.items[self.top];
    }

    /// Pop and convert to *Value (allocating if needed).
    pub fn popValue(self: *OperandStack, allocator: Allocator) anyerror!*Value {
        const entry = self.pop() orelse return error.StackUnderflow;
        return entry.toValue(allocator);
    }

    /// Peek at the top StackEntry.
    pub fn peek(self: *const OperandStack) ?StackEntry {
        if (self.top == 0) return null;
        return self.items[self.top - 1];
    }

    pub fn len(self: *const OperandStack) usize {
        return self.top;
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
    // Phase 5: Store loop binding values directly to avoid env.put/get (HAMT) overhead.
    // Each entry corresponds to binding_sym_indices[i].
    // Using StackEntry to store primitives inline (no allocation for int/float).
    binding_values: []StackEntry,
};

/// Function aridity for make_fn support.
pub const FnAridity = struct {
    params: list.List,
    bytecode: ?*bc.BytecodeProgram,
    rest_name: ?[]const u8,
};

/// Function metadata for make_fn support.
pub const FnMetadata = struct {
    arities: std.ArrayListUnmanaged(FnAridity),
    name: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *FnMetadata) void {
        for (self.arities.items) |*a| {
            a.params.deinit(self.allocator);
            if (a.bytecode) |bc_prog| {
                bc_prog.deinit(self.allocator);
                self.allocator.destroy(bc_prog);
            }
            if (a.rest_name) |rn| self.allocator.free(rn);
        }
        self.arities.deinit(self.allocator);
        if (self.name) |n| self.allocator.free(n);
    }
};

/// Free all loop frames and their resources.
pub fn cleanupLoopStack(allocator: Allocator, loop_stack: *std.ArrayListUnmanaged(*LoopFrame)) void {
    for (loop_stack.items) |frame| {
        // Free pointer entries in binding_values
        var bi: usize = 0;
        while (bi < frame.binding_count) : (bi += 1) {
            switch (frame.binding_values[bi]) {
                .integer, .float => {},
                .pointer => |v| {
                    vm.valueDeinit(v, allocator);
                    allocator.destroy(v);
                },
            }
        }
        allocator.free(frame.binding_values);
        allocator.destroy(frame);
    }
    loop_stack.deinit(allocator);
}

/// Free a StackEntry if it holds a pointer (no-op for integer/float).
pub fn freeEntry(entry: StackEntry, allocator: Allocator) void {
    switch (entry) {
        .integer, .float => {},
        .pointer => |v| {
            vm.valueDeinit(v, allocator);
            allocator.destroy(v);
        },
    }
}
