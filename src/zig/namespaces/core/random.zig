// Random number generation: rand, rand-int
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const helpers = @import("helpers.zig");
const test_utils = @import("test_utils.zig");

const toInt = helpers.toInt;

// Use SplitMix64 PRNG seeded with monotonic time
var prng = std.Random.SplitMix64.init(42);

pub fn initRandom() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Clock.awake.now(io);
    const seed: u64 = @intCast(ts.nanoseconds);
    prng = std.Random.SplitMix64.init(seed);
}

// Get a random u64 from the PRNG
fn nextRandom() u64 {
    return prng.next();
}

// rand - returns a random double in [0.0, 1.0)
// (rand) => random double in [0.0, 1.0)
// (rand n) => random integer in [0, n)
pub fn core_rand(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len > 1) return error.ArityError;

    if (args.items.len == 0) {
        // (rand) => random double in [0.0, 1.0)
        // Mask to 53 bits (f64 mantissa precision), then divide by 2^53
        const bits = nextRandom() & 0x001F_FFFF_FFFF_FFFF;
        const frac = @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
        return vm.floatValue(frac);
    }

    // (rand n) => random integer in [0, n)
    const n = try toInt(args.items[0]);
    if (n <= 0) return error.ArgumentError;
    const r = nextRandom() % @as(u64, @intCast(n));
    return vm.intValue(@as(i64, @intCast(r)));
}

// rand-int - returns a random integer in [0, n)
pub fn core_rand_int(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const n = try toInt(args.items[0]);
    if (n <= 0) return error.ArgumentError;
    const r = nextRandom() % @as(u64, @intCast(n));
    return vm.intValue(@as(i64, @intCast(r)));
}

pub fn registerRandomFunctions(env: *Env) anyerror!void {
    initRandom();
    try env.put("rand", vm.builtinFnValue(core_rand));
    try env.put("rand-int", vm.builtinFnValue(core_rand_int));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "random::rand: no args returns float in [0.0, 1.0)" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_rand(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .float);
    try std.testing.expect(result.float >= 0.0);
    try std.testing.expect(result.float < 1.0);
}

test "random::rand: with arg returns int in [0, n)" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(100) });
    var result = core_rand(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer >= 0);
    try std.testing.expect(result.integer < 100);
}

test "random::rand-int: returns int in [0, n)" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(50) });
    var result = core_rand_int(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer >= 0);
    try std.testing.expect(result.integer < 50);
}

test "random::rand-int: wrong arity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_rand_int(testSelf(), &args, &a));
}
