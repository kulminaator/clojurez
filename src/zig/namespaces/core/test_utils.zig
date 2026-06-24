// Shared test utilities for unit tests in core/ modules.
// Eliminates duplicated testEnv(), testSelf(), makeArgs() across files.
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");

/// Create a fresh empty environment for testing.
pub fn testEnv() vm.Env {
    return vm.Env.init(std.heap.page_allocator);
}

/// Create a list of Value arguments from a slice.
pub fn makeArgs(args: []const Value) list.List {
    var result: list.List = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        _ = result.append(std.heap.page_allocator, args[i]) catch unreachable;
    }
    return result;
}

/// A nil Value used as `self` for builtin function tests.
pub fn testSelf() *const Value {
    _testSelf = vm.nilValue();
    return &_testSelf;
}
var _testSelf: Value = vm.nilValue();
