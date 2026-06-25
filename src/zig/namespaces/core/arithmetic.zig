// Arithmetic built-in functions: +, -, *, /, rem
// Supports: integer, float, bigint, ratio, decimal
// Coercion follows Clojure rules:
//   - integer + integer → integer (bigint on overflow)
//   - integer + float → float
//   - integer + bigint → bigint
//   - integer + ratio → ratio
//   - integer + decimal → decimal
//   - float + anything → decimal (except ratio→decimal)
//   - bigint + bigint → bigint
//   - bigint + ratio → ratio
//   - bigint + decimal → decimal
//   - ratio + ratio → ratio
//   - ratio + decimal → decimal
//   - decimal + decimal → decimal
//   - integer / integer → ratio (if not exact) or integer
//   - any / float → float
//   - any / bigint → ratio (if not exact) or bigint
//   - any / ratio → ratio
//   - any / decimal → decimal
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const helpers = @import("helpers.zig");
const BI = @import("../../big_int.zig");
const RatioMod = @import("../../ratio.zig");
const BD = @import("../../big_decimal.zig");
const test_utils = @import("test_utils.zig");

const Allocator = std.mem.Allocator;

const isIntF64 = helpers.isIntF64;

// ============================================================
// Coercion helpers
// ============================================================

/// Convert a Value to a BigInt (allocates on allocator)
fn toBigInt(allocator: Allocator, v: Value) anyerror!BI.BigInt {
    return switch (std.meta.activeTag(v)) {
        .integer => BI.bigIntFromI64(allocator, v.integer),
        .bigint => {
            return try v.bigint.clone(allocator);
        },
        else => return error.TypeError,
    };
}

/// Convert a Value to a Ratio (allocates on allocator)
fn toRatio(allocator: Allocator, v: Value) anyerror!RatioMod.Ratio {
    return switch (std.meta.activeTag(v)) {
        .integer => try RatioMod.Ratio.fromI64(allocator, v.integer, 1),
        .bigint => return try RatioMod.Ratio.fromBigInt(allocator, try v.bigint.clone(allocator), BI.bigIntFromI64(allocator, 1)),
        .ratio => return try v.ratio.clone(allocator),
        else => return error.TypeError,
    };
}

/// Convert a Value to a BigDecimal (allocates on allocator)
fn toBigDecimal(allocator: Allocator, v: Value) anyerror!BD.BigDecimal {
    return switch (std.meta.activeTag(v)) {
        .integer => BD.BigDecimal.fromI64(allocator, v.integer, 0),
        .float => {
            // Convert f64 to string then parse as BigDecimal
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v.float});
            defer allocator.free(s);
            return try BD.BigDecimal.fromString(allocator, s);
        },
        .bigint => {
            const ptr = v.bigint;
            const str = try ptr.toString(allocator);
            defer allocator.free(str);
            return try BD.BigDecimal.fromString(allocator, str);
        },
        .ratio => {
            const ptr = v.ratio;
            // ratio → decimal: divide num by den
            var num_bd = try toBigDecimal(allocator, try vm.bigIntValue(allocator, try ptr.num.clone(allocator)));
            var den_bd = try toBigDecimal(allocator, try vm.bigIntValue(allocator, try ptr.den.clone(allocator)));
            const result = try BD.div(num_bd, den_bd);
            num_bd.deinit();
            den_bd.deinit();
            return result;
        },
        .decimal => {
            return try v.decimal.clone(allocator);
        },
        else => return error.TypeError,
    };
}

/// Try to convert a BigInt back to i64 if it fits
fn bigintToI64(bi: BI.BigInt) ?i64 {
    return bi.toI64();
}

/// Create a bigint Value from a local BigInt, cloning to avoid ownership issues.
fn bigIntValueOwned(allocator: Allocator, bi: *BI.BigInt) anyerror!Value {
    if (bigintToI64(bi.*)) |i| {
        bi.deinit();
        return vm.intValue(i);
    }
    const cloned = try bi.clone(allocator);
    bi.deinit();
    return vm.bigIntValue(allocator, cloned);
}

/// Create a ratio Value from a local Ratio, cloning to avoid ownership issues.
fn ratioValueOwned(allocator: Allocator, r: *RatioMod.Ratio) anyerror!Value {
    const cloned = try r.clone(allocator);
    r.deinit();
    return vm.ratioValue(allocator, cloned);
}

/// Create a decimal Value from a local BigDecimal, cloning to avoid ownership issues.
fn decimalValueOwned(allocator: Allocator, d: *BD.BigDecimal) anyerror!Value {
    const cloned = try d.clone(allocator);
    d.deinit();
    return vm.decimalValue(allocator, cloned);
}

// ============================================================
// Binary operation helpers
// ============================================================

/// Add two numeric Values, returning a new Value.
fn addValues(allocator: Allocator, a: Value, b: Value) anyerror!Value {
    // Determine result type based on both operands
    return switch (std.meta.activeTag(a)) {
        .integer => switch (std.meta.activeTag(b)) {
            .integer => {
                // Check for overflow
                const sum = try std.math.add(i64, a.integer, b.integer);
                return vm.intValue(sum);
            },
            .float => return vm.floatValue(@as(f64, @floatFromInt(a.integer)) + b.float),
            .bigint => {
                var bi = try toBigInt(allocator, b);
                defer bi.deinit();
                var result = BI.add(BI.bigIntFromI64(allocator, a.integer), bi);
                if (bigintToI64(result)) |i| {
                    result.deinit();
                    return vm.intValue(i);
                }
                return bigIntValueOwned(allocator, &result);
            },
            .ratio => {
                var r = try toRatio(allocator, b);
                defer r.deinit();
                var int_as_ratio = try RatioMod.Ratio.fromI64(allocator, a.integer, 1);
                defer int_as_ratio.deinit();
                var result = RatioMod.add(int_as_ratio, r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var d = try toBigDecimal(allocator, b);
                defer d.deinit();
                var int_as_dec = BD.BigDecimal.fromI64(allocator, a.integer, 0);
                defer int_as_dec.deinit();
                var result = BD.add(int_as_dec, d);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .float => switch (std.meta.activeTag(b)) {
            .integer => return vm.floatValue(a.float + @as(f64, @floatFromInt(b.integer))),
            .float => return vm.floatValue(a.float + b.float),
            .bigint => {
                // float + bigint → decimal
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.add(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            .ratio => {
                // float + ratio → decimal
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.add(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.add(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .bigint => switch (std.meta.activeTag(b)) {
            .integer => return addValues(allocator, b, a), // commutative
            .float => return addValues(allocator, b, a),
            .bigint => {
                var a_bi: BI.BigInt = undefined;
                var b_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                b_bi = try b.bigint.clone(allocator);
                defer { a_bi.deinit(); b_bi.deinit(); }
                var result = BI.add(a_bi, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            .ratio => {
                var a_r = try toRatio(allocator, a);
                defer a_r.deinit();
                var b_r = try toRatio(allocator, b);
                defer b_r.deinit();
                var result = RatioMod.add(a_r, b_r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.add(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .ratio => switch (std.meta.activeTag(b)) {
            .integer => return addValues(allocator, b, a),
            .float => return addValues(allocator, b, a),
            .bigint => return addValues(allocator, b, a),
            .ratio => {
                var a_r: RatioMod.Ratio = undefined;
                var b_r: RatioMod.Ratio = undefined;
                a_r = try a.ratio.clone(allocator);
                b_r = try b.ratio.clone(allocator);
                defer { a_r.deinit(); b_r.deinit(); }
                var result = RatioMod.add(a_r, b_r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.add(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .decimal => switch (std.meta.activeTag(b)) {
            .integer => return addValues(allocator, b, a),
            .float => return addValues(allocator, b, a),
            .bigint => return addValues(allocator, b, a),
            .ratio => return addValues(allocator, b, a),
            .decimal => {
                var a_dec: BD.BigDecimal = undefined;
                var b_dec: BD.BigDecimal = undefined;
                a_dec = try a.decimal.clone(allocator);
                b_dec = try b.decimal.clone(allocator);
                defer { a_dec.deinit(); b_dec.deinit(); }
                var result = BD.add(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
}

/// Subtract b from a.
fn subValues(allocator: Allocator, a: Value, b: Value) anyerror!Value {
    return switch (std.meta.activeTag(a)) {
        .integer => switch (std.meta.activeTag(b)) {
            .integer => {
                const diff = try std.math.sub(i64, a.integer, b.integer);
                return vm.intValue(diff);
            },
            .float => return vm.floatValue(@as(f64, @floatFromInt(a.integer)) - b.float),
            .bigint => {
                var bi = try toBigInt(allocator, b);
                defer bi.deinit();
                var neg_b = BI.negate(bi);
                defer neg_b.deinit();
                var result = BI.add(BI.bigIntFromI64(allocator, a.integer), neg_b);
                return bigIntValueOwned(allocator, &result);
            },
            .ratio => {
                var r = try toRatio(allocator, b);
                defer r.deinit();
                var int_as_ratio = try RatioMod.Ratio.fromI64(allocator, a.integer, 1);
                defer int_as_ratio.deinit();
                var result = RatioMod.sub(int_as_ratio, r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var d = try toBigDecimal(allocator, b);
                defer d.deinit();
                var int_as_dec = BD.BigDecimal.fromI64(allocator, a.integer, 0);
                defer int_as_dec.deinit();
                var result = BD.sub(int_as_dec, d);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .float => switch (std.meta.activeTag(b)) {
            .integer => return vm.floatValue(a.float - @as(f64, @floatFromInt(b.integer))),
            .float => return vm.floatValue(a.float - b.float),
            .bigint, .ratio, .decimal => {
                // float - (bigint|ratio|decimal) → decimal
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.sub(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .bigint => switch (std.meta.activeTag(b)) {
            .integer => {
                var bi = try toBigInt(allocator, b);
                defer bi.deinit();
                var a_bi = try a.bigint.clone(allocator);
                defer a_bi.deinit();
                var result = BI.sub(a_bi, bi);
                return bigIntValueOwned(allocator, &result);
            },
            .float => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.sub(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            .bigint => {
                var a_bi: BI.BigInt = undefined;
                var b_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                b_bi = try b.bigint.clone(allocator);
                defer { a_bi.deinit(); b_bi.deinit(); }
                var result = BI.sub(a_bi, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            .ratio => {
                var a_r = try toRatio(allocator, a);
                defer a_r.deinit();
                var b_r = try toRatio(allocator, b);
                defer b_r.deinit();
                var result = RatioMod.sub(a_r, b_r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.sub(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .ratio => switch (std.meta.activeTag(b)) {
            .integer => {
                var int_as_ratio = try RatioMod.Ratio.fromI64(allocator, b.integer, 1);
                defer int_as_ratio.deinit();
                const ap = a.ratio;
                var a_r = try ap.clone(allocator);
                defer a_r.deinit();
                var result = RatioMod.sub(a_r, int_as_ratio);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .float => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.sub(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            .bigint => {
                var a_r = try toRatio(allocator, a);
                defer a_r.deinit();
                var b_r = try toRatio(allocator, b);
                defer b_r.deinit();
                var result = RatioMod.sub(a_r, b_r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .ratio => {
                var a_r: RatioMod.Ratio = undefined;
                var b_r: RatioMod.Ratio = undefined;
                a_r = try a.ratio.clone(allocator);
                b_r = try b.ratio.clone(allocator);
                defer { a_r.deinit(); b_r.deinit(); }
                var result = RatioMod.sub(a_r, b_r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.sub(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .decimal => switch (std.meta.activeTag(b)) {
            .integer => {
                var int_as_dec = BD.BigDecimal.fromI64(allocator, b.integer, 0);
                defer int_as_dec.deinit();
                const ap = a.decimal;
                var a_dec = try ap.clone(allocator);
                defer a_dec.deinit();
                var result = BD.sub(a_dec, int_as_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            .float, .bigint, .ratio => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.sub(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec: BD.BigDecimal = undefined;
                var b_dec: BD.BigDecimal = undefined;
                a_dec = try a.decimal.clone(allocator);
                b_dec = try b.decimal.clone(allocator);
                defer { a_dec.deinit(); b_dec.deinit(); }
                var result = BD.sub(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
}

/// Multiply two numeric Values.
fn mulValues(allocator: Allocator, a: Value, b: Value) anyerror!Value {
    return switch (std.meta.activeTag(a)) {
        .integer => switch (std.meta.activeTag(b)) {
            .integer => {
                const product = try std.math.mul(i64, a.integer, b.integer);
                return vm.intValue(product);
            },
            .float => return vm.floatValue(@as(f64, @floatFromInt(a.integer)) * b.float),
            .bigint => {
                var bi = try toBigInt(allocator, b);
                defer bi.deinit();
                var result = BI.mul(BI.bigIntFromI64(allocator, a.integer), bi);
                return bigIntValueOwned(allocator, &result);
            },
            .ratio => {
                var r = try toRatio(allocator, b);
                defer r.deinit();
                var int_as_ratio = try RatioMod.Ratio.fromI64(allocator, a.integer, 1);
                defer int_as_ratio.deinit();
                var result = RatioMod.mul(int_as_ratio, r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var d = try toBigDecimal(allocator, b);
                defer d.deinit();
                var int_as_dec = BD.BigDecimal.fromI64(allocator, a.integer, 0);
                defer int_as_dec.deinit();
                var result = BD.mul(int_as_dec, d);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .float => switch (std.meta.activeTag(b)) {
            .integer => return vm.floatValue(a.float * @as(f64, @floatFromInt(b.integer))),
            .float => return vm.floatValue(a.float * b.float),
            .bigint, .ratio, .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.mul(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .bigint => switch (std.meta.activeTag(b)) {
            .integer => return mulValues(allocator, b, a),
            .float => return mulValues(allocator, b, a),
            .bigint => {
                var a_bi: BI.BigInt = undefined;
                var b_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                b_bi = try b.bigint.clone(allocator);
                defer { a_bi.deinit(); b_bi.deinit(); }
                var result = BI.mul(a_bi, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            .ratio => {
                var a_r = try toRatio(allocator, a);
                defer a_r.deinit();
                var b_r = try toRatio(allocator, b);
                defer b_r.deinit();
                var result = RatioMod.mul(a_r, b_r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.mul(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .ratio => switch (std.meta.activeTag(b)) {
            .integer => return mulValues(allocator, b, a),
            .float => return mulValues(allocator, b, a),
            .bigint => return mulValues(allocator, b, a),
            .ratio => {
                var a_r: RatioMod.Ratio = undefined;
                var b_r: RatioMod.Ratio = undefined;
                a_r = try a.ratio.clone(allocator);
                b_r = try b.ratio.clone(allocator);
                defer { a_r.deinit(); b_r.deinit(); }
                var result = RatioMod.mul(a_r, b_r);
                defer result.deinit();
                return ratioValueOwned(allocator, &result);
            },
            .decimal => {
                var a_dec = try toBigDecimal(allocator, a);
                defer a_dec.deinit();
                var b_dec = try toBigDecimal(allocator, b);
                defer b_dec.deinit();
                var result = BD.mul(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .decimal => switch (std.meta.activeTag(b)) {
            .integer => return mulValues(allocator, b, a),
            .float => return mulValues(allocator, b, a),
            .bigint => return mulValues(allocator, b, a),
            .ratio => return mulValues(allocator, b, a),
            .decimal => {
                var a_dec: BD.BigDecimal = undefined;
                var b_dec: BD.BigDecimal = undefined;
                a_dec = try a.decimal.clone(allocator);
                b_dec = try b.decimal.clone(allocator);
                defer { a_dec.deinit(); b_dec.deinit(); }
                var result = BD.mul(a_dec, b_dec);
                defer result.deinit();
                return decimalValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };
}

/// Divide a by b. Follows Clojure coercion rules:
///   integer / integer → ratio (if not exact) or integer
///   any / float → float
///   any / bigint → ratio (if not exact) or bigint
///   any / ratio → ratio
///   any / decimal → decimal
fn divValues(allocator: Allocator, a: Value, b: Value) anyerror!Value {
    // Check for zero divisor
    const b_is_zero: bool = switch (std.meta.activeTag(b)) {
        .integer => b.integer == 0,
        .float => b.float == 0.0,
        .bigint => b.bigint.isZero(),
        .ratio => b.ratio.isZero(),
        .decimal => b.decimal.isZero(),
        else => return error.TypeError,
    };
    if (b_is_zero) return error.DivisionByZero;

    return switch (std.meta.activeTag(b)) {
        .integer => {
            // Dividing by integer
            return switch (std.meta.activeTag(a)) {
                .integer => {
                    // integer / integer → ratio if not exact
                    if (b.integer == 1) return vm.intValue(a.integer);
                    if (@rem(a.integer, b.integer) == 0) return vm.intValue(@divTrunc(a.integer, b.integer));
                    // Return ratio
                    var r = try RatioMod.Ratio.fromI64(allocator, a.integer, b.integer);
                    return ratioValueOwned(allocator, &r);
                },
                .float => return vm.floatValue(a.float / @as(f64, @floatFromInt(b.integer))),
                .bigint => {
                    var a_bi: BI.BigInt = undefined;
                    a_bi = try a.bigint.clone(allocator);
                    defer a_bi.deinit();
                    var b_bi = BI.bigIntFromI64(allocator, b.integer);
                    defer b_bi.deinit();
                    var dm = try BI.divmod(a_bi, b_bi);
                    defer dm.remainder.deinit();
                    if (dm.remainder.isZero()) {
                        if (bigintToI64(dm.quotient)) |i| {
                            dm.quotient.deinit();
                            return vm.intValue(i);
                        }
                        return bigIntValueOwned(allocator, &dm.quotient);
                    }
                    // Not exact → ratio
                    var r = try RatioMod.Ratio.fromBigInt(allocator, dm.quotient, b_bi);
                    // Actually we need the full numerator: a_bi
                    r.deinit();
                    var r2 = try RatioMod.Ratio.fromBigInt(allocator, try a_bi.clone(allocator), b_bi);
                    defer r2.deinit();
                    return ratioValueOwned(allocator, &r2);
                },
                .ratio => {
                    var a_r: RatioMod.Ratio = undefined;
                    a_r = try a.ratio.clone(allocator);
                    defer a_r.deinit();
                    var b_r = try RatioMod.Ratio.fromI64(allocator, b.integer, 1);
                    defer b_r.deinit();
                    var result = try RatioMod.div(a_r, b_r);
                    defer result.deinit();
                    return ratioValueOwned(allocator, &result);
                },
                .decimal => {
                    var a_dec: BD.BigDecimal = undefined;
                    a_dec = try a.decimal.clone(allocator);
                    defer a_dec.deinit();
                    var b_dec = BD.BigDecimal.fromI64(allocator, b.integer, 0);
                    defer b_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                else => return error.TypeError,
            };
        },
        .float => {
            // Dividing by float → always float
            const divisor = b.float;
            return switch (std.meta.activeTag(a)) {
                .integer => vm.floatValue(@as(f64, @floatFromInt(a.integer)) / divisor),
                .float => vm.floatValue(a.float / divisor),
                .bigint, .ratio, .decimal => {
                    // Convert to decimal first, then to float
                    var a_dec = try toBigDecimal(allocator, a);
                    defer a_dec.deinit();
                    var b_dec = try toBigDecimal(allocator, b);
                    defer b_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    // Convert back to float
                    const str = try result.toString(allocator);
                    defer allocator.free(str);
                    const f = try std.fmt.parseFloat(f64, str);
                    return vm.floatValue(f);
                },
                else => return error.TypeError,
            };
        },
        .bigint => {
            var b_bi: BI.BigInt = undefined;
            b_bi = try b.bigint.clone(allocator);
            defer b_bi.deinit();
            return switch (std.meta.activeTag(a)) {
                .integer => {
                    var a_bi = BI.bigIntFromI64(allocator, a.integer);
                    defer a_bi.deinit();
                    var dm = try BI.divmod(a_bi, b_bi);
                    defer dm.remainder.deinit();
                    if (dm.remainder.isZero()) {
                        if (bigintToI64(dm.quotient)) |i| {
                            dm.quotient.deinit();
                            return vm.intValue(i);
                        }
                        return bigIntValueOwned(allocator, &dm.quotient);
                    }
                    // Not exact → ratio
                    var r = try RatioMod.Ratio.fromBigInt(allocator, try a_bi.clone(allocator), b_bi);
                    defer r.deinit();
                    return ratioValueOwned(allocator, &r);
                },
                .float => {
                    var a_dec = try toBigDecimal(allocator, a);
                    defer a_dec.deinit();
                    var b_dec = try toBigDecimal(allocator, b);
                    defer b_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    const str = try result.toString(allocator);
                    defer allocator.free(str);
                    const f = try std.fmt.parseFloat(f64, str);
                    return vm.floatValue(f);
                },
                .bigint => {
                    var a_bi: BI.BigInt = undefined;
                    a_bi = try a.bigint.clone(allocator);
                    defer a_bi.deinit();
                    var dm = try BI.divmod(a_bi, b_bi);
                    defer dm.remainder.deinit();
                    if (dm.remainder.isZero()) {
                        if (bigintToI64(dm.quotient)) |i| {
                            dm.quotient.deinit();
                            return vm.intValue(i);
                        }
                        return bigIntValueOwned(allocator, &dm.quotient);
                    }
                    // Not exact → ratio
                    var r = try RatioMod.Ratio.fromBigInt(allocator, try a_bi.clone(allocator), b_bi);
                    defer r.deinit();
                    return ratioValueOwned(allocator, &r);
                },
                .ratio => {
                    var a_r: RatioMod.Ratio = undefined;
                    a_r = try a.ratio.clone(allocator);
                    defer a_r.deinit();
                    var b_r = try toRatio(allocator, b);
                    defer b_r.deinit();
                    var result = try RatioMod.div(a_r, b_r);
                    defer result.deinit();
                    return ratioValueOwned(allocator, &result);
                },
                .decimal => {
                    var a_dec: BD.BigDecimal = undefined;
                    a_dec = try a.decimal.clone(allocator);
                    defer a_dec.deinit();
                    var b_dec = try toBigDecimal(allocator, b);
                    defer b_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                else => return error.TypeError,
            };
        },
        .ratio => {
            var b_r: RatioMod.Ratio = undefined;
            b_r = try b.ratio.clone(allocator);
            defer b_r.deinit();
            return switch (std.meta.activeTag(a)) {
                .integer => {
                    var a_r = try RatioMod.Ratio.fromI64(allocator, a.integer, 1);
                    defer a_r.deinit();
                    var result = try RatioMod.div(a_r, b_r);
                    defer result.deinit();
                    return ratioValueOwned(allocator, &result);
                },
                .float => {
                    var a_dec = try toBigDecimal(allocator, a);
                    defer a_dec.deinit();
                    var b_dec = try toBigDecimal(allocator, b);
                    defer b_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    const str = try result.toString(allocator);
                    defer allocator.free(str);
                    const f = try std.fmt.parseFloat(f64, str);
                    return vm.floatValue(f);
                },
                .bigint => {
                    var a_r = try toRatio(allocator, a);
                    defer a_r.deinit();
                    var result = try RatioMod.div(a_r, b_r);
                    defer result.deinit();
                    return ratioValueOwned(allocator, &result);
                },
                .ratio => {
                    var a_r: RatioMod.Ratio = undefined;
                    a_r = try a.ratio.clone(allocator);
                    defer a_r.deinit();
                    var result = try RatioMod.div(a_r, b_r);
                    defer result.deinit();
                    return ratioValueOwned(allocator, &result);
                },
                .decimal => {
                    var a_dec: BD.BigDecimal = undefined;
                    a_dec = try a.decimal.clone(allocator);
                    defer a_dec.deinit();
                    var b_dec = try toBigDecimal(allocator, b);
                    defer b_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                else => return error.TypeError,
            };
        },
        .decimal => {
            var b_dec: BD.BigDecimal = undefined;
            b_dec = try b.decimal.clone(allocator);
            defer b_dec.deinit();
            return switch (std.meta.activeTag(a)) {
                .integer => {
                    var a_dec = BD.BigDecimal.fromI64(allocator, a.integer, 0);
                    defer a_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                .float => {
                    var a_dec = try toBigDecimal(allocator, a);
                    defer a_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                .bigint => {
                    var a_dec = try toBigDecimal(allocator, a);
                    defer a_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                .ratio => {
                    var a_dec = try toBigDecimal(allocator, a);
                    defer a_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                .decimal => {
                    var a_dec: BD.BigDecimal = undefined;
                    a_dec = try a.decimal.clone(allocator);
                    defer a_dec.deinit();
                    var result = try BD.div(a_dec, b_dec);
                    defer result.deinit();
                    return decimalValueOwned(allocator, &result);
                },
                else => return error.TypeError,
            };
        },
        else => return error.TypeError,
    };
}

/// Remainder of a / b. Sign follows dividend (truncates toward zero).
fn remValues(allocator: Allocator, a: Value, b: Value) anyerror!Value {
    const b_is_zero: bool = switch (std.meta.activeTag(b)) {
        .integer => b.integer == 0,
        .float => b.float == 0.0,
        .bigint => b.bigint.isZero(),
        .ratio => b.ratio.isZero(),
        .decimal => b.decimal.isZero(),
        else => return error.TypeError,
    };
    if (b_is_zero) return error.DivisionByZero;

    return switch (std.meta.activeTag(a)) {
        .integer => switch (std.meta.activeTag(b)) {
            .integer => vm.intValue(@rem(a.integer, b.integer)),
            .float => vm.floatValue(@rem(@as(f64, @floatFromInt(a.integer)), b.float)),
            .bigint => {
                var a_bi = BI.bigIntFromI64(allocator, a.integer);
                defer a_bi.deinit();
                var b_bi: BI.BigInt = undefined;
                b_bi = try b.bigint.clone(allocator);
                defer b_bi.deinit();
                var result = try BI.mod(a_bi, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            .ratio, .decimal => return error.TypeError, // rem not defined for ratio/decimal
            else => return error.TypeError,
        },
        .float => switch (std.meta.activeTag(b)) {
            .integer => vm.floatValue(@rem(a.float, @as(f64, @floatFromInt(b.integer)))),
            .float => vm.floatValue(@rem(a.float, b.float)),
            else => return error.TypeError,
        },
        .bigint => switch (std.meta.activeTag(b)) {
            .integer => {
                var a_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                defer a_bi.deinit();
                var b_bi = BI.bigIntFromI64(allocator, b.integer);
                defer b_bi.deinit();
                var result = try BI.mod(a_bi, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            .bigint => {
                var a_bi: BI.BigInt = undefined;
                var b_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                b_bi = try b.bigint.clone(allocator);
                defer { a_bi.deinit(); b_bi.deinit(); }
                var result = try BI.mod(a_bi, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .ratio, .decimal => return error.TypeError, // rem not defined for ratio/decimal
        else => return error.TypeError,
    };
}

/// Modulo of a / b. Sign follows divisor (truncates toward negative infinity).
/// Clojure: (mod num div) = if (rem has same sign as div or is zero) rem else (rem + div)
fn modValues(allocator: Allocator, a: Value, b: Value) anyerror!Value {
    const b_is_zero: bool = switch (std.meta.activeTag(b)) {
        .integer => b.integer == 0,
        .float => b.float == 0.0,
        .bigint => b.bigint.isZero(),
        .ratio => b.ratio.isZero(),
        .decimal => b.decimal.isZero(),
        else => return error.TypeError,
    };
    if (b_is_zero) return error.DivisionByZero;

    return switch (std.meta.activeTag(a)) {
        .integer => switch (std.meta.activeTag(b)) {
            .integer => {
                const r = @rem(a.integer, b.integer);
                if (r == 0) return vm.intValue(0);
                // If remainder and divisor have different signs, add divisor
                const same_sign = (r > 0 and b.integer > 0) or (r < 0 and b.integer < 0);
                if (same_sign) return vm.intValue(r);
                const result = try std.math.add(i64, r, b.integer);
                return vm.intValue(result);
            },
            .float => {
                const r = @rem(@as(f64, @floatFromInt(a.integer)), b.float);
                if (r == 0.0) return vm.floatValue(0.0);
                const same_sign = (r > 0 and b.float > 0) or (r < 0 and b.float < 0);
                if (same_sign) return vm.floatValue(r);
                return vm.floatValue(r + b.float);
            },
            .bigint => {
                var a_bi = BI.bigIntFromI64(allocator, a.integer);
                defer a_bi.deinit();
                var b_bi: BI.BigInt = undefined;
                b_bi = try b.bigint.clone(allocator);
                defer b_bi.deinit();
                var r = try BI.mod(a_bi, b_bi);
                defer r.deinit();
                if (r.isZero()) return vm.intValue(0);
                // Check if remainder and divisor have same sign
                const r_sign = r.sign;
                const b_sign = b_bi.sign;
                if (r_sign == b_sign) return bigIntValueOwned(allocator, &r);
                var result = BI.add(r, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            .ratio, .decimal => return error.TypeError,
            else => return error.TypeError,
        },
        .float => switch (std.meta.activeTag(b)) {
            .integer => {
                const r = @rem(a.float, @as(f64, @floatFromInt(b.integer)));
                if (r == 0.0) return vm.floatValue(0.0);
                const b_f = @as(f64, @floatFromInt(b.integer));
                const same_sign = (r > 0 and b_f > 0) or (r < 0 and b_f < 0);
                if (same_sign) return vm.floatValue(r);
                return vm.floatValue(r + b_f);
            },
            .float => {
                const r = @rem(a.float, b.float);
                if (r == 0.0) return vm.floatValue(0.0);
                const same_sign = (r > 0 and b.float > 0) or (r < 0 and b.float < 0);
                if (same_sign) return vm.floatValue(r);
                return vm.floatValue(r + b.float);
            },
            else => return error.TypeError,
        },
        .bigint => switch (std.meta.activeTag(b)) {
            .integer => {
                var a_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                defer a_bi.deinit();
                var b_bi = BI.bigIntFromI64(allocator, b.integer);
                defer b_bi.deinit();
                var r = try BI.mod(a_bi, b_bi);
                defer r.deinit();
                if (r.isZero()) return vm.intValue(0);
                const r_sign = r.sign;
                const b_sign = b_bi.sign;
                if (r_sign == b_sign) return bigIntValueOwned(allocator, &r);
                var result = BI.add(r, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            .bigint => {
                var a_bi: BI.BigInt = undefined;
                var b_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                b_bi = try b.bigint.clone(allocator);
                defer { a_bi.deinit(); b_bi.deinit(); }
                var r = try BI.mod(a_bi, b_bi);
                defer r.deinit();
                if (r.isZero()) return vm.intValue(0);
                const r_sign = r.sign;
                const b_sign = b_bi.sign;
                if (r_sign == b_sign) return bigIntValueOwned(allocator, &r);
                var result = BI.add(r, b_bi);
                return bigIntValueOwned(allocator, &result);
            },
            else => return error.TypeError,
        },
        .ratio, .decimal => return error.TypeError,
        else => return error.TypeError,
    };
}

/// Quotient of a / b. Integer division truncating toward zero.
fn quotValues(allocator: Allocator, a: Value, b: Value) anyerror!Value {
    const b_is_zero: bool = switch (std.meta.activeTag(b)) {
        .integer => b.integer == 0,
        .float => b.float == 0.0,
        .bigint => b.bigint.isZero(),
        .ratio => b.ratio.isZero(),
        .decimal => b.decimal.isZero(),
        else => return error.TypeError,
    };
    if (b_is_zero) return error.DivisionByZero;

    return switch (std.meta.activeTag(a)) {
        .integer => switch (std.meta.activeTag(b)) {
            .integer => vm.intValue(@divTrunc(a.integer, b.integer)),
            .float => {
                const q = @as(f64, @floatFromInt(a.integer)) / b.float;
                // Truncate toward zero
                const truncated: i64 = @intFromFloat(q);
                return vm.intValue(truncated);
            },
            .bigint => {
                var a_bi = BI.bigIntFromI64(allocator, a.integer);
                defer a_bi.deinit();
                var b_bi: BI.BigInt = undefined;
                b_bi = try b.bigint.clone(allocator);
                defer b_bi.deinit();
                var dm = try BI.divmod(a_bi, b_bi);
                defer dm.remainder.deinit();
                return bigIntValueOwned(allocator, &dm.quotient);
            },
            .ratio, .decimal => return error.TypeError,
            else => return error.TypeError,
        },
        .float => switch (std.meta.activeTag(b)) {
            .integer => {
                const q = a.float / @as(f64, @floatFromInt(b.integer));
                const truncated: i64 = @intFromFloat(q);
                return vm.intValue(truncated);
            },
            .float => {
                const q = a.float / b.float;
                const truncated: i64 = @intFromFloat(q);
                return vm.intValue(truncated);
            },
            else => return error.TypeError,
        },
        .bigint => switch (std.meta.activeTag(b)) {
            .integer => {
                var a_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                defer a_bi.deinit();
                var b_bi = BI.bigIntFromI64(allocator, b.integer);
                defer b_bi.deinit();
                var dm = try BI.divmod(a_bi, b_bi);
                defer dm.remainder.deinit();
                return bigIntValueOwned(allocator, &dm.quotient);
            },
            .bigint => {
                var a_bi: BI.BigInt = undefined;
                var b_bi: BI.BigInt = undefined;
                a_bi = try a.bigint.clone(allocator);
                b_bi = try b.bigint.clone(allocator);
                defer { a_bi.deinit(); b_bi.deinit(); }
                var dm = try BI.divmod(a_bi, b_bi);
                defer dm.remainder.deinit();
                return bigIntValueOwned(allocator, &dm.quotient);
            },
            else => return error.TypeError,
        },
        .ratio, .decimal => return error.TypeError,
        else => return error.TypeError,
    };
}

// ============================================================
// Public built-in functions
// ============================================================

pub fn core_plus(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len == 0) return vm.intValue(0);

    var result = try vm.clone(&args.items[0], allocator);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const new_result = try addValues(allocator, result, args.items[i]);
        vm.valueDeinit(&result, allocator);
        result = new_result;
    }
    return result;
}

pub fn core_minus(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len == 0) return error.ArityError;
    if (args.items.len == 1) {
        // (- x) => 0 - x (negation)
        return subValues(allocator, vm.intValue(0), args.items[0]);
    }

    var result = try vm.clone(&args.items[0], allocator);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const new_result = try subValues(allocator, result, args.items[i]);
        vm.valueDeinit(&result, allocator);
        result = new_result;
    }
    return result;
}

pub fn core_mult(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len == 0) return vm.intValue(1);

    var result = try vm.clone(&args.items[0], allocator);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const new_result = try mulValues(allocator, result, args.items[i]);
        vm.valueDeinit(&result, allocator);
        result = new_result;
    }
    return result;
}

pub fn core_div(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len == 0) return error.ArityError;
    if (args.items.len == 1) {
        // (/ x) => 1 / x (reciprocal)
        return divValues(allocator, vm.intValue(1), args.items[0]);
    }

    var result = try vm.clone(&args.items[0], allocator);
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const new_result = try divValues(allocator, result, args.items[i]);
        vm.valueDeinit(&result, allocator);
        result = new_result;
    }
    return result;
}

pub fn core_rem(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    return remValues(allocator, args.items[0], args.items[1]);
}

pub fn core_mod(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    return modValues(allocator, args.items[0], args.items[1]);
}

pub fn core_quot(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 2) return error.ArityError;
    return quotValues(allocator, args.items[0], args.items[1]);
}

// rationalize - returns the rational value of num
// For integers/bigints/ratios: returns the value as-is
// For floats/decimals: converts to a ratio (unscaled / 10^scale)
pub fn core_rationalize(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];

    return switch (std.meta.activeTag(v)) {
        .integer => try vm.clone(&v, allocator),
        .bigint => try vm.clone(&v, allocator),
        .ratio => try vm.clone(&v, allocator),
        .float => {
            // Convert float to BigDecimal string, then to ratio
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v.float});
            defer allocator.free(s);
            var bd = try BD.BigDecimal.fromString(allocator, s);
            defer bd.deinit();
            // Create ratio: unscaled / 10^scale
            if (bd.scale == 0) {
                // No decimal places, return as integer/bigint
                if (bigintToI64(bd.unscaled)) |i| {
                    return vm.intValue(i);
                }
                return bigIntValueOwned(allocator, &bd.unscaled);
            }
            const num = try bd.unscaled.clone(allocator);
            var den = BI.bigIntFromI64(allocator, 1);
            var s_idx: usize = 0;
            while (s_idx < bd.scale) : (s_idx += 1) {
                den = BI.mul(den, BI.bigIntFromI64(allocator, 10));
            }
            var r = try RatioMod.Ratio.fromBigInt(allocator, num, den);
            defer r.deinit();
            return ratioValueOwned(allocator, &r);
        },
        .decimal => {
            const dp = v.decimal;
            if (dp.scale == 0) {
                // No decimal places, return as integer/bigint
                if (bigintToI64(dp.unscaled)) |i| {
                    return vm.intValue(i);
                }
                return bigIntValueOwned(allocator, &dp.unscaled);
            }
            const num = try dp.unscaled.clone(allocator);
            var den = BI.bigIntFromI64(allocator, 1);
            var s_idx: usize = 0;
            while (s_idx < dp.scale) : (s_idx += 1) {
                den = BI.mul(den, BI.bigIntFromI64(allocator, 10));
            }
            var r = try RatioMod.Ratio.fromBigInt(allocator, num, den);
            defer r.deinit();
            return ratioValueOwned(allocator, &r);
        },
        else => return error.TypeError,
    };
}

/// Returns the numerator of a ratio, or the value itself for integers/bigints.
/// Clojure: (numerator x)
pub fn core_numerator(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];

    return switch (std.meta.activeTag(v)) {
        .integer => try vm.clone(&v, allocator),
        .bigint => try vm.clone(&v, allocator),
        .ratio => {
            const rp = v.ratio;
            return try bigIntValueOwned(allocator, &rp.num);
        },
        else => return error.TypeError,
    };
}

/// Returns the denominator of a ratio, or 1 for integers/bigints.
/// Clojure: (denominator x)
pub fn core_denominator(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];

    return switch (std.meta.activeTag(v)) {
        .integer => vm.intValue(1),
        .bigint => vm.intValue(1),
        .ratio => {
            const rp = v.ratio;
            return try bigIntValueOwned(allocator, &rp.den);
        },
        else => return error.TypeError,
    };
}

pub fn registerArithmeticFunctions(env: *Env) anyerror!void {
    try env.put("plus", vm.builtinFnValue(core_plus));
    try env.put("minus", vm.builtinFnValue(core_minus));
    try env.put("mult", vm.builtinFnValue(core_mult));
    try env.put("div", vm.builtinFnValue(core_div));
    try env.put("mod", vm.builtinFnValue(core_mod));
    try env.put("rem", vm.builtinFnValue(core_rem));
    try env.put("quot", vm.builtinFnValue(core_quot));
    try env.put("rationalize", vm.builtinFnValue(core_rationalize));
    try env.put("numerator", vm.builtinFnValue(core_numerator));
    try env.put("denominator", vm.builtinFnValue(core_denominator));
    try env.put("num", vm.builtinFnValue(core_numerator));
    try env.put("denom", vm.builtinFnValue(core_denominator));
    // Clojure-style aliases
    try env.put("+", vm.builtinFnValue(core_plus));
    try env.put("-", vm.builtinFnValue(core_minus));
    try env.put("*", vm.builtinFnValue(core_mult));
    try env.put("/", vm.builtinFnValue(core_div));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const testSelf = test_utils.testSelf;
const makeArgs = test_utils.makeArgs;

test "arithmetic::mod: positive values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(7), vm.intValue(3) });
    var result = core_mod(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 1);
}

test "arithmetic::mod: neg dividend" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-7), vm.intValue(3) });
    var result = core_mod(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 2);
}

test "arithmetic::mod: neg divisor" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(7), vm.intValue(-3) });
    var result = core_mod(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == -2);
}

test "arithmetic::mod: both neg" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-7), vm.intValue(-3) });
    var result = core_mod(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == -1);
}

test "arithmetic::rem: neg dividend" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-7), vm.intValue(3) });
    var result = core_rem(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == -1);
}

test "arithmetic::quot: positive" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(7), vm.intValue(3) });
    var result = core_quot(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 2);
}

test "arithmetic::quot: neg dividend" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-7), vm.intValue(3) });
    var result = core_quot(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == -2);
}

test "arithmetic::rationalize: int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(5) });
    var result = core_rationalize(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 5);
}

test "arithmetic::rationalize: 1.0 to int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.0) });
    var result = core_rationalize(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 1);
}

test "arithmetic::rationalize: 1.5 to ratio" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.5) });
    var result = core_rationalize(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .ratio);
}

test "regression: minus single arg negation" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(7) });
    var result = core_minus(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == -7);
}

test "regression: minus single arg negation of negative" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-5) });
    var result = core_minus(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 5);
}

test "regression: minus single arg negation of float" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(3.14) });
    var result = core_minus(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .float);
    try std.testing.expect(std.math.approxEqAbs(f64, result.float, -3.14, 0.001));
}

test "regression: minus zero args arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_minus(testSelf(), &args, &a));
}

test "regression: div single arg reciprocal" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(2) });
    var result = core_div(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .ratio);
}

test "regression: div single arg reciprocal of 1" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1) });
    var result = core_div(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 1);
}

test "regression: div single arg reciprocal of negative" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-5) });
    var result = core_div(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .ratio);
}

test "regression: div single arg reciprocal of float" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(2.0) });
    var result = core_div(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .float);
    try std.testing.expect(std.math.approxEqAbs(f64, result.float, 0.5, 0.001));
}

test "regression: div zero args arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_div(testSelf(), &args, &a));
}
