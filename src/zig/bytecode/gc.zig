// GC scanning for BytecodeProgram.
const bc = @import("instructions.zig");

/// Scan a BytecodeProgram for GC roots.
/// Called by gc_scan.zig to find Value pointers in bytecode programs.
pub fn scanGC(program: *const bc.BytecodeProgram, scanFn: fn (*anyopaque) void) void {
    for (program.constants.items) |*v| {
        scanFn(v);
    }
}
