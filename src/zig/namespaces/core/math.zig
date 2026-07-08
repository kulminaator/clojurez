// Math built-in functions for clojure.math namespace
// Implements: constants (E, PI), trigonometric functions, angle conversion,
// hyperbolic functions, exponential/logarithmic, rounding, IEEE operations,
// sign functions, exact integer arithmetic, floor division/modulus,
// floating-point bit operations, and random.
const std = @import("std");
const math = std.math;
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const helpers = @import("helpers.zig");
const BI = @import("../../big_int.zig");

const Allocator = std.mem.Allocator;

// ============================================================
// Conversion helpers
// ============================================================

/// Convert a Value to f64. Accepts integer, float, and bigint.
pub fn toF64(allocator: Allocator, v: Value) anyerror!f64 {
    return switch (std.meta.activeTag(v)) {
        .integer => @as(f64, @floatFromInt(v.integer)),
        .float => v.float,
        .bigint => {
            const s = try v.bigint.toString(allocator);
            defer allocator.free(s);
            return std.fmt.parseFloat(f64, s);
        },
        else => return error.TypeError,
    };
}

// ============================================================
// Constants
// ============================================================

pub fn core_E(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    _ = args;
    if (vm.cachedE()) |v| return v;
    return vm.floatValue(std.math.e);
}

pub fn core_PI(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    _ = args;
    if (vm.cachedPI()) |v| return v;
    return vm.floatValue(std.math.pi);
}

// ============================================================
// Trigonometric Functions
// ============================================================

pub fn core_sin(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@sin(d));
}

pub fn core_cos(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@cos(d));
}

pub fn core_tan(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@tan(d));
}

pub fn core_asin(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.asin(d));
}

pub fn core_acos(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.acos(d));
}

pub fn core_atan(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.atan(d));
}

pub fn core_atan2(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const y = try toF64(env_env.allocator, args.items[0]);
    const x = try toF64(env_env.allocator, args.items[1]);
    return vm.floatValue(math.atan2(y, x));
}

// ============================================================
// Angle Conversion
// ============================================================

pub fn core_to_radians(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.degreesToRadians(d));
}

pub fn core_to_degrees(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.radiansToDegrees(d));
}

// ============================================================
// Hyperbolic Functions
// ============================================================

pub fn core_sinh(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.sinh(d));
}

pub fn core_cosh(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.cosh(d));
}

pub fn core_tanh(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.tanh(d));
}

// ============================================================
// Exponential / Logarithmic Functions
// ============================================================

pub fn core_exp(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@exp(d));
}

pub fn core_log(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@log(d));
}

pub fn core_log10(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@log10(d));
}

pub fn core_sqrt(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@sqrt(d));
}

pub fn core_cbrt(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.cbrt(d));
}

pub fn core_expm1(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.expm1(d));
}

pub fn core_log1p(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.log1p(d));
}

pub fn core_pow(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const a = try toF64(env_env.allocator, args.items[0]);
    const b = try toF64(env_env.allocator, args.items[1]);
    return vm.floatValue(math.pow(f64, a, b));
}

pub fn core_hypot(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const a = try toF64(env_env.allocator, args.items[0]);
    const b = try toF64(env_env.allocator, args.items[1]);
    return vm.floatValue(math.hypot(a, b));
}

// ============================================================
// Rounding Functions
// ============================================================

pub fn core_ceil(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@ceil(d));
}

pub fn core_floor(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(@floor(d));
}

pub fn core_rint(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(rintImpl(d));
}

pub fn core_round(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.intValue(roundImpl(d));
}

/// JVM Math.round: floor(x + 0.5), clamped to long range.
/// NaN → 0, +Inf → MAX_VALUE, -Inf → MIN_VALUE.
fn roundImpl(d: f64) i64 {
    if (math.isNan(d)) return 0;
    if (math.isInf(d)) return if (d > 0) math.maxInt(i64) else math.minInt(i64);
    const r = @floor(d + 0.5);
    // Clamp to i64 range
    const min_f: f64 = @as(f64, @floatFromInt(math.minInt(i64)));
    const max_f: f64 = @as(f64, @floatFromInt(math.maxInt(i64)));
    if (r <= min_f) return math.minInt(i64);
    if (r >= max_f) return math.maxInt(i64);
    return @as(i64, @intFromFloat(r));
}

/// rint: round to nearest integer, ties to even (banker's rounding).
/// Returns f64 (preserves -0.0 for negative inputs near zero).
fn rintImpl(d: f64) f64 {
    if (math.isNan(d)) return math.nan(f64);
    if (math.isInf(d)) return d;
    const floored = @floor(d);
    const ceiled = @ceil(d);
    if (d == floored or d == ceiled) return d;
    const mid = floored + 0.5;
    if (d < mid) return floored;
    if (d > mid) return ceiled;
    // Exactly at midpoint — round to even
    if (@rem(@as(i64, @intFromFloat(floored)), 2) == 0) return floored;
    return ceiled;
}

// ============================================================
// IEEE Remainder + Sign Functions
// ============================================================

pub fn core_IEEE_remainder(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const dividend = try toF64(env_env.allocator, args.items[0]);
    const divisor = try toF64(env_env.allocator, args.items[1]);
    return vm.floatValue(ieeeRemainderImpl(dividend, divisor));
}

pub fn core_signum(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(signumImpl(d));
}

pub fn core_copy_sign(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const magnitude = try toF64(env_env.allocator, args.items[0]);
    const sign = try toF64(env_env.allocator, args.items[1]);
    return vm.floatValue(math.copysign(magnitude, sign));
}

/// IEEE 754 remainder: dividend - divisor * n where n is the integer
/// closest to dividend/divisor. If two integers are equally close, n is even.
fn ieeeRemainderImpl(dividend: f64, divisor: f64) f64 {
    if (math.isNan(dividend) or math.isNan(divisor)) return math.nan(f64);
    if (math.isInf(dividend)) return math.nan(f64);
    if (divisor == 0.0) return math.nan(f64);
    if (math.isInf(divisor)) return dividend;
    const quotient = dividend / divisor;
    const n = @round(quotient);
    return dividend - divisor * n;
}

/// Returns -1.0, 0.0, or 1.0 based on sign. Preserves -0.0.
/// Returns NaN if input is NaN.
fn signumImpl(d: f64) f64 {
    if (math.isNan(d)) return math.nan(f64);
    if (d > 0) return 1.0;
    if (d < 0) return -1.0;
    return d;
}

// ============================================================
// Exact Integer Arithmetic
// ============================================================

pub fn core_add_exact(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const b: i64 = try helpers.toInt(args.items[1]);
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.ArithmeticException;
    return vm.intValue(result[0]);
}

pub fn core_subtract_exact(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const b: i64 = try helpers.toInt(args.items[1]);
    const result = @subWithOverflow(a, b);
    if (result[1] != 0) return error.ArithmeticException;
    return vm.intValue(result[0]);
}

pub fn core_multiply_exact(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const b: i64 = try helpers.toInt(args.items[1]);
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.ArithmeticException;
    return vm.intValue(result[0]);
}

pub fn core_increment_exact(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const result = @addWithOverflow(a, 1);
    if (result[1] != 0) return error.ArithmeticException;
    return vm.intValue(result[0]);
}

pub fn core_decrement_exact(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const result = @subWithOverflow(a, 1);
    if (result[1] != 0) return error.ArithmeticException;
    return vm.intValue(result[0]);
}

pub fn core_negate_exact(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const result = @subWithOverflow(0, a);
    if (result[1] != 0) return error.ArithmeticException;
    return vm.intValue(result[0]);
}

// ============================================================
// Floor Division / Modulus
// ============================================================

pub fn core_floor_div(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const b: i64 = try helpers.toInt(args.items[1]);
    return vm.intValue(floorDiv(a, b));
}

pub fn core_floor_mod(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 2) return error.ArityError;
    const a: i64 = try helpers.toInt(args.items[0]);
    const b: i64 = try helpers.toInt(args.items[1]);
    return vm.intValue(floorMod(a, b));
}

/// Floor division: integer division rounding toward negative infinity.
/// Special case: floorDiv(MIN_VALUE, -1) returns MIN_VALUE (per JVM spec).
fn floorDiv(a: i64, b: i64) i64 {
    if (b == 0) @panic("division by zero");
    // Special case: MIN_VALUE / -1 overflows, return MIN_VALUE per JVM spec
    if (a == math.minInt(i64) and b == -1) return math.minInt(i64);
    // Use @divTrunc for truncation toward zero, then adjust
    const q = @divTrunc(a, b);
    const r = @rem(a, b);
    // If remainder is non-zero and a and b have different signs, subtract 1
    if (r != 0 and ((a < 0) != (b < 0))) return q - 1;
    return q;
}

/// Floor modulus: x - floorDiv(x, y) * y.
/// The sign of the result matches the sign of the divisor.
fn floorMod(a: i64, b: i64) i64 {
    if (b == 0) @panic("division by zero");
    // Special case: floorMod(MIN_VALUE, -1) = 0 (MIN_VALUE is divisible by -1)
    if (a == math.minInt(i64) and b == -1) return 0;
    return a - floorDiv(a, b) * b;
}

// ============================================================
// Floating-Point Bit Operations
// ============================================================

pub fn core_ulp(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(ulpImpl(d));
}

pub fn core_get_exponent(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.intValue(@as(i64, @intCast(getExponentImpl(d))));
}

pub fn core_scalb(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    const scale: i32 = try helpers.toInt32(args.items[1]);
    return vm.floatValue(math.scalbn(d, scale));
}

pub fn core_next_after(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const start = try toF64(env_env.allocator, args.items[0]);
    const direction = try toF64(env_env.allocator, args.items[1]);
    return vm.floatValue(math.nextAfter(f64, start, direction));
}

pub fn core_next_up(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.nextAfter(f64, d, math.inf(f64)));
}

pub fn core_next_down(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const d = try toF64(env_env.allocator, args.items[0]);
    return vm.floatValue(math.nextAfter(f64, d, -math.inf(f64)));
}

/// ULP (Unit in Last Place): the gap between a float and the next representable value.
/// NaN → NaN, ±Inf → +Inf, 0.0 → Double.MIN_VALUE.
fn ulpImpl(d: f64) f64 {
    if (math.isNan(d)) return math.nan(f64);
    if (math.isInf(d)) return math.inf(f64);
    if (d == 0.0) return math.floatTrueMin(f64);
    const abs_d = @abs(d);
    return @abs(math.nextAfter(f64, abs_d, math.inf(f64)) - abs_d);
}

/// Returns the unbiased exponent of a double.
/// NaN/±Inf → 1024 (MAX_EXPONENT + 1), zero/subnormal → -1023 (MIN_EXPONENT - 1).
fn getExponentImpl(d: f64) i32 {
    if (math.isNan(d) or math.isInf(d)) return 1024;
    if (d == 0.0) return -1023;
    const abs_d = @abs(d);
    // Subnormal check: smallest normal is 2^-1022
    if (abs_d < math.ldexp(@as(f64, 1.0), -1022)) return -1023;
    const frexp_result = math.frexp(abs_d);
    return frexp_result.exponent - 1;
}

// ============================================================
// Random
// ============================================================

pub fn core_random(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    _ = args;
    // Delegate to existing rand logic: random double in [0.0, 1.0)
    const random_mod = @import("random.zig");
    const bits = random_mod.nextRandom() & 0x001F_FFFF_FFFF_FFFF;
    const frac = @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
    return vm.floatValue(frac);
}

// ============================================================
// Registration
// ============================================================

pub fn registerMathFunctions(env: *Env) anyerror!void {
    // Constants
    try env.put("E", vm.builtinFnValue(core_E));
    try env.put("PI", vm.builtinFnValue(core_PI));

    // Trigonometric functions
    try env.put("sin", vm.builtinFnValue(core_sin));
    try env.put("cos", vm.builtinFnValue(core_cos));
    try env.put("tan", vm.builtinFnValue(core_tan));
    try env.put("asin", vm.builtinFnValue(core_asin));
    try env.put("acos", vm.builtinFnValue(core_acos));
    try env.put("atan", vm.builtinFnValue(core_atan));
    try env.put("atan2", vm.builtinFnValue(core_atan2));

    // Angle conversion
    try env.put("to-radians", vm.builtinFnValue(core_to_radians));
    try env.put("to-degrees", vm.builtinFnValue(core_to_degrees));

    // Hyperbolic functions
    try env.put("sinh", vm.builtinFnValue(core_sinh));
    try env.put("cosh", vm.builtinFnValue(core_cosh));
    try env.put("tanh", vm.builtinFnValue(core_tanh));

    // Exponential / logarithmic functions
    try env.put("exp", vm.builtinFnValue(core_exp));
    try env.put("log", vm.builtinFnValue(core_log));
    try env.put("log10", vm.builtinFnValue(core_log10));
    try env.put("sqrt", vm.builtinFnValue(core_sqrt));
    try env.put("cbrt", vm.builtinFnValue(core_cbrt));
    try env.put("expm1", vm.builtinFnValue(core_expm1));
    try env.put("log1p", vm.builtinFnValue(core_log1p));
    try env.put("pow", vm.builtinFnValue(core_pow));
    try env.put("hypot", vm.builtinFnValue(core_hypot));

    // Rounding functions
    try env.put("ceil", vm.builtinFnValue(core_ceil));
    try env.put("floor", vm.builtinFnValue(core_floor));
    try env.put("rint", vm.builtinFnValue(core_rint));
    try env.put("round", vm.builtinFnValue(core_round));

    // IEEE remainder + sign functions
    try env.put("IEEE-remainder", vm.builtinFnValue(core_IEEE_remainder));
    try env.put("signum", vm.builtinFnValue(core_signum));
    try env.put("copy-sign", vm.builtinFnValue(core_copy_sign));

    // Exact integer arithmetic
    try env.put("add-exact", vm.builtinFnValue(core_add_exact));
    try env.put("subtract-exact", vm.builtinFnValue(core_subtract_exact));
    try env.put("multiply-exact", vm.builtinFnValue(core_multiply_exact));
    try env.put("increment-exact", vm.builtinFnValue(core_increment_exact));
    try env.put("decrement-exact", vm.builtinFnValue(core_decrement_exact));
    try env.put("negate-exact", vm.builtinFnValue(core_negate_exact));

    // Floor division / modulus
    try env.put("floor-div", vm.builtinFnValue(core_floor_div));
    try env.put("floor-mod", vm.builtinFnValue(core_floor_mod));

    // Floating-point bit operations
    try env.put("ulp", vm.builtinFnValue(core_ulp));
    try env.put("get-exponent", vm.builtinFnValue(core_get_exponent));
    try env.put("scalb", vm.builtinFnValue(core_scalb));
    try env.put("next-after", vm.builtinFnValue(core_next_after));
    try env.put("next-up", vm.builtinFnValue(core_next_up));
    try env.put("next-down", vm.builtinFnValue(core_next_down));

    // Random
    try env.put("random", vm.builtinFnValue(core_random));
}
