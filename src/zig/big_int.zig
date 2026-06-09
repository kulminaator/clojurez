// High-level BigInt API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const B = @import("big_int_base.zig");

pub const BigInt = B.BigInt;
pub const Sign = B.Sign;

pub fn bigIntFromI64(allocator: Allocator, n: i64) BigInt {
    var result = BigInt.init(allocator);
    result.setI64(n);
    return result;
}

pub fn bigIntFromU64(allocator: Allocator, n: u64) BigInt {
    var result = BigInt.init(allocator);
    result.setU64(n);
    return result;
}

pub fn bigIntFromString(allocator: Allocator, s: []const u8) anyerror!BigInt {
    var result = BigInt.init(allocator);
    errdefer result.deinit();
    var i: usize = 0;
    var neg: bool = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    if (i >= s.len) return error.InvalidNumber;

    while (i < s.len) : (i += 1) {
        const digit: B.LIMB = s[i] - '0';
        result = mulBySmall(allocator, result, 10);
        if (digit > 0) {
            var d_val = bigIntFromU64(allocator, digit);
            const sum = add(result, d_val);
            result.deinit();
            d_val.deinit();
            result = sum;
        }
    }
    if (neg) result.negate();
    return result;
}

pub fn mulBySmall(allocator: Allocator, a: BigInt, small: B.LIMB) BigInt {
    if (small == 0) return BigInt.init(allocator);
    if (small == 1) return a.clone(allocator) catch unreachable;
    var result = BigInt.init(allocator);
    result.sign = a.sign;
    if (a.limbs.len == 0) return result;

    var carry: u128 = 0;
    var idx: usize = 0;
    while (idx < a.limbs.len or carry > 0) : (idx += 1) {
        const limb: u128 = if (idx < a.limbs.len) a.limbs[idx] else 0;
        const prod = limb * @as(u128, small) + carry;
        carry = prod / B.Base;
        const new_len: usize = idx + 1;
        if (result.owns_limbs) {
            result.limbs = allocator.realloc(result.limbs, new_len) catch unreachable;
        } else {
            result.limbs = allocator.alloc(B.LIMB, new_len) catch unreachable;
            result.owns_limbs = true;
        }
        result.limbs[idx] = @as(B.LIMB, @intCast(prod % B.Base));
    }
    result.normalize();
    return result;
}

pub fn compare(a: BigInt, b: BigInt) B.CompareResult {
    if (a.sign != b.sign) {
        if (a.isZero()) return if (b.isZero()) .equal else if (b.sign == .positive) .less else .greater;
        if (b.isZero()) return if (a.sign == .positive) .greater else .less;
        return if (a.sign == .positive) .greater else .less;
    }
    const cmp = B.compareLen(a.limbs, b.limbs);
    if (a.sign == .negative) {
        return switch (cmp) {
            .less => .greater,
            .equal => .equal,
            .greater => .less,
        };
    }
    return cmp;
}

pub fn equals(a: BigInt, b: BigInt) bool {
    return compare(a, b) == .equal;
}

pub fn add(a: BigInt, b: BigInt) BigInt {
    const allocator = a.allocator;
    if (a.isZero()) return b.clone(allocator) catch unreachable;
    if (b.isZero()) return a.clone(allocator) catch unreachable;
    if (a.sign == b.sign) {
        var result = BigInt.init(allocator);
        result.sign = a.sign;
        const new_limbs = B.addLimbs(allocator, a.limbs, b.limbs) catch unreachable;
        result.limbs = new_limbs;
        result.owns_limbs = true;
        result.normalize();
        return result;
    }
    const mag_cmp = B.compareLen(a.limbs, b.limbs);
    switch (mag_cmp) {
        .greater => return subMag(allocator, a, b, a.sign),
        .less => return subMag(allocator, b, a, b.sign),
        .equal => return BigInt.init(allocator),
    }
}

fn subMag(allocator: Allocator, large: BigInt, small: BigInt, resultSign: Sign) BigInt {
    var result = BigInt.init(allocator);
    result.sign = resultSign;
    const new_limbs = B.subLimbs(allocator, large.limbs, small.limbs) catch unreachable;
    result.limbs = new_limbs;
    result.owns_limbs = true;
    result.normalize();
    return result;
}

pub fn sub(a: BigInt, b: BigInt) BigInt {
    const allocator = a.allocator;
    var neg_b = b.clone(allocator) catch unreachable;
    neg_b.negate();
    const result = add(a, neg_b);
    neg_b.deinit();
    return result;
}

pub fn mul(a: BigInt, b: BigInt) BigInt {
    const allocator = a.allocator;
    if (a.isZero() or b.isZero()) return BigInt.init(allocator);
    var result = BigInt.init(allocator);
    result.sign = if (a.sign == .positive) b.sign else if (b.sign == .positive) a.sign else .positive;
    const new_limbs = B.mulLimbs(allocator, a.limbs, b.limbs) catch unreachable;
    result.limbs = new_limbs;
    result.owns_limbs = true;
    result.normalize();
    return result;
}

pub fn divmod(a: BigInt, b: BigInt) anyerror!struct { quotient: BigInt, remainder: BigInt } {
    const allocator = a.allocator;
    if (b.isZero()) return error.DivisionByZero;
    if (a.isZero()) return .{ .quotient = BigInt.init(allocator), .remainder = BigInt.init(allocator) };

    const neg_result = a.sign != b.sign;
    var a_abs = try a.abs(allocator);
    var b_abs = try b.abs(allocator);
    defer { a_abs.deinit(); b_abs.deinit(); }

    const div_result = try B.divLimbs(allocator, a_abs.limbs, b_abs.limbs);

    var quotient = BigInt.init(allocator);
    quotient.limbs = div_result.quotient;
    quotient.owns_limbs = true;
    quotient.normalize();
    if (neg_result) quotient.negate();

    var remainder = BigInt.init(allocator);
    remainder.limbs = div_result.remainder;
    remainder.owns_limbs = true;
    remainder.sign = a.sign;
    remainder.normalize();

    return .{ .quotient = quotient, .remainder = remainder };
}

pub fn mod(a: BigInt, b: BigInt) anyerror!BigInt {
    if (b.isZero()) return error.DivisionByZero;
    const dm = try divmod(a, b);
    var r = dm.remainder;
    if (r.sign != b.sign and !r.isZero()) {
        const result = add(r, b);
        r.deinit();
        return result;
    }
    return r;
}

pub fn negate(a: BigInt) BigInt {
    var result = a;
    result.negate();
    return result;
}

pub fn gcd(a: BigInt, b: BigInt) anyerror!BigInt {
    const allocator = a.allocator;
    var x = try a.abs(allocator);
    errdefer x.deinit();
    var y = try b.abs(allocator);
    errdefer y.deinit();

    while (!y.isZero()) {
        const dm = try B.divLimbs(allocator, x.limbs, y.limbs);
        allocator.free(dm.quotient);
        // x = y, y = x mod y (Euclidean algorithm)
        var new_y = BigInt.init(allocator);
        new_y.limbs = dm.remainder;
        new_y.owns_limbs = true;
        new_y.normalize();
        x.deinit();
        x = try y.clone(allocator);
        y.deinit();
        y = new_y;
    }
    y.deinit();
    x.normalize();
    return x;
}

// ===== Unit Tests =====

test "big_int::gcd: gcd(15, 10) = 5" {
    const allocator = std.heap.page_allocator;
    var a = bigIntFromI64(allocator, 15);
    var b = bigIntFromI64(allocator, 10);
    defer { a.deinit(); b.deinit(); }
    var g = try gcd(a, b);
    defer g.deinit();
    try std.testing.expect(g.toI64() == 5);
}

test "big_int::gcd: gcd(3, 2) = 1" {
    const allocator = std.heap.page_allocator;
    var a = bigIntFromI64(allocator, 3);
    var b = bigIntFromI64(allocator, 2);
    defer { a.deinit(); b.deinit(); }
    var g = try gcd(a, b);
    defer g.deinit();
    try std.testing.expect(g.toI64() == 1);
}
