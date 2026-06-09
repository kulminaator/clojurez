// BigInt base types using owned slices.
// Base 10^18 limbs (u64), little-endian order.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LIMB = u64;
pub const Base: LIMB = 1_000_000_000_000_000_000; // 10^18

pub const Sign = enum { positive, negative };
pub const CompareResult = enum { less, equal, greater };

/// Owned signed big integer using owned slices.
pub const BigInt = struct {
    sign: Sign = .positive,
    limbs: []LIMB = &.{},
    allocator: Allocator,
    owns_limbs: bool = false,

    pub fn init(allocator: Allocator) BigInt {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BigInt) void {
        if (self.owns_limbs and self.limbs.len > 0) {
            self.allocator.free(self.limbs);
            self.limbs = &.{};
            self.owns_limbs = false;
        }
        self.sign = .positive;
    }

    pub fn isZero(self: BigInt) bool {
        var i: usize = self.limbs.len;
        while (i > 0) {
            i -= 1;
            if (self.limbs[i] != 0) return false;
        }
        return true;
    }

    pub fn clone(self: BigInt, allocator: Allocator) anyerror!BigInt {
        var result = BigInt.init(allocator);
        errdefer result.deinit();
        result.sign = self.sign;
        if (self.limbs.len > 0) {
            result.limbs = try allocator.dupe(LIMB, self.limbs);
            result.owns_limbs = true;
        }
        return result;
    }

    pub fn abs(self: BigInt, allocator: Allocator) anyerror!BigInt {
        var result = try self.clone(allocator);
        result.sign = .positive;
        return result;
    }

    pub fn negate(self: *BigInt) void {
        if (!self.isZero()) self.sign = if (self.sign == .positive) .negative else .positive;
    }

    pub fn normalize(self: *BigInt) void {
        while (self.limbs.len > 1 and self.limbs[self.limbs.len - 1] == 0) {
            self.limbs = self.limbs[0 .. self.limbs.len - 1];
        }
        if (self.limbs.len == 1 and self.limbs[0] == 0) {
            if (self.owns_limbs) self.allocator.free(self.limbs);
            self.limbs = &.{};
            self.owns_limbs = false;
            self.sign = .positive;
        }
    }

    pub fn setU64(self: *BigInt, n: u64) void {
        if (self.owns_limbs and self.limbs.len > 0) self.allocator.free(self.limbs);
        self.limbs = &.{};
        self.owns_limbs = false;
        self.sign = .positive;
        if (n == 0) return;
        // Split into base-10^18 limbs
        if (n < Base) {
            self.limbs = self.allocator.alloc(LIMB, 1) catch unreachable;
            self.limbs[0] = @as(LIMB, @intCast(n));
        } else {
            self.limbs = self.allocator.alloc(LIMB, 2) catch unreachable;
            self.limbs[0] = @as(LIMB, @intCast(n % Base));
            self.limbs[1] = @as(LIMB, @intCast(n / Base));
        }
        self.owns_limbs = true;
    }

    pub fn setI64(self: *BigInt, n: i64) void {
        if (self.owns_limbs and self.limbs.len > 0) self.allocator.free(self.limbs);
        self.limbs = &.{};
        self.owns_limbs = false;
        if (n == 0) { self.sign = .positive; return; }
        self.sign = if (n < 0) .negative else .positive;
        const abs_n: u64 = if (n < 0) @as(u64, @intCast(-n)) else @as(u64, @intCast(n));
        // Split into base-10^18 limbs
        if (abs_n < Base) {
            self.limbs = self.allocator.alloc(LIMB, 1) catch unreachable;
            self.limbs[0] = @as(LIMB, @intCast(abs_n));
        } else {
            self.limbs = self.allocator.alloc(LIMB, 2) catch unreachable;
            self.limbs[0] = @as(LIMB, @intCast(abs_n % Base));
            self.limbs[1] = @as(LIMB, @intCast(abs_n / Base));
        }
        self.owns_limbs = true;
    }

    pub fn toI64(self: BigInt) ?i64 {
        if (self.limbs.len == 0) return 0;
        const max_i64: u64 = @as(u64, @intCast(std.math.maxInt(i64)));
        var v: u64 = 0;
        if (self.limbs.len == 1) {
            v = self.limbs[0];
        } else if (self.limbs.len == 2) {
            // Reconstruct from two limbs
            const hi: u64 = self.limbs[1];
            const lo: u64 = self.limbs[0];
            // Check for overflow: hi * Base + lo must fit in u64
            if (hi > (std.math.maxInt(u64) - lo) / Base) return null;
            v = hi * Base + lo;
        } else {
            return null; // Too many limbs to fit in i64
        }
        if (self.sign == .negative) {
            if (v > max_i64) return null;
            return -@as(i64, @intCast(v));
        }
        if (v > max_i64) return null;
        return @as(i64, @intCast(v));
    }

    pub fn toString(self: BigInt, allocator: Allocator) anyerror![]const u8 {
        if (self.isZero()) return allocator.dupe(u8, "0");
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        if (self.sign == .negative) try buf.append(allocator, '-');
        if (self.limbs.len == 0) return allocator.dupe(u8, "0");
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{self.limbs[self.limbs.len - 1]}));
        var i: usize = self.limbs.len - 1;
        while (i > 0) {
            i -= 1;
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{:0>18}", .{self.limbs[i]}));
        }
        return buf.toOwnedSlice(allocator);
    }
};

// ---- Comparison ----

pub fn compareLen(a: []const LIMB, b: []const LIMB) CompareResult {
    const al = effLen(a);
    const bl = effLen(b);
    if (al != bl) return if (al > bl) .greater else .less;
    var i = al;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return if (a[i] > b[i]) .greater else .less;
    }
    return .equal;
}

fn effLen(s: []const LIMB) usize {
    var len = s.len;
    while (len > 1 and s[len - 1] == 0) len -= 1;
    if (len == 1 and s[0] == 0) return 0;
    return len;
}

// ---- Addition ----

pub fn addLimbs(allocator: Allocator, a: []const LIMB, b: []const LIMB) anyerror![]LIMB {
    const al = effLen(a);
    const bl = effLen(b);
    const ml = if (al > bl) al else bl;
    var result: std.ArrayListUnmanaged(LIMB) = .empty;
    errdefer result.deinit(allocator);
    var carry: u128 = 0;
    var i: usize = 0;
    while (i < ml or carry > 0) : (i += 1) {
        var sum: u128 = carry;
        if (i < al) sum += a[i];
        if (i < bl) sum += b[i];
        try result.append(allocator, @as(LIMB, @intCast(sum % Base)));
        carry = @as(LIMB, @intCast(sum / Base));
    }
    return result.toOwnedSlice(allocator);
}

// ---- Subtraction (a >= b) ----

pub fn subLimbs(allocator: Allocator, a: []const LIMB, b: []const LIMB) anyerror![]LIMB {
    const al = effLen(a);
    var result: std.ArrayListUnmanaged(LIMB) = .empty;
    errdefer result.deinit(allocator);
    var borrow: u128 = 0;
    var i: usize = 0;
    while (i < al) : (i += 1) {
        const av: u128 = a[i];
        const bv: u128 = if (i < effLen(b)) b[i] else 0;
        const total_sub = bv + borrow;
        if (av >= total_sub) {
            try result.append(allocator, @as(LIMB, @intCast(av - total_sub)));
            borrow = 0;
        } else {
            try result.append(allocator, @as(LIMB, @intCast(av + Base - total_sub)));
            borrow = 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

// ---- Multiplication ----

pub fn mulLimbs(allocator: Allocator, a: []const LIMB, b: []const LIMB) anyerror![]LIMB {
    const al = effLen(a);
    const bl = effLen(b);
    if (al == 0 or bl == 0) return allocator.alloc(LIMB, 0);
    const rl = al + bl;
    var result: std.ArrayListUnmanaged(LIMB) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, rl);
    var k: usize = 0;
    while (k < rl) : (k += 1) try result.append(allocator, 0);

    var i: usize = 0;
    while (i < al) : (i += 1) {
        var carry: u128 = 0;
        var j: usize = 0;
        while (j < bl or carry > 0) : (j += 1) {
            const prod: u128 = @as(u128, a[i]) * (if (j < bl) @as(u128, b[j]) else 0) + carry;
            const existing: u128 = result.items[i + j];
            const total = prod + existing;
            result.items[i + j] = @as(LIMB, @intCast(total % Base));
            carry = total / Base;
        }
    }
    return result.toOwnedSlice(allocator);
}

// ---- Division ----

pub fn divLimbs(allocator: Allocator, a: []const LIMB, b: []const LIMB) anyerror!struct { quotient: []LIMB, remainder: []LIMB } {
    const al = effLen(a);
    const bl = effLen(b);
    if (bl == 0) return error.DivisionByZero;

    const cmp = compareLen(a, b);
    if (cmp == .less) {
        return .{
            .quotient = try allocator.alloc(LIMB, 0),
            .remainder = try allocator.dupe(LIMB, a[0..al]),
        };
    }
    if (cmp == .equal) {
        var q = try allocator.alloc(LIMB, 1);
        q[0] = 1;
        return .{ .quotient = q, .remainder = try allocator.alloc(LIMB, 0) };
    }

    var work: std.ArrayListUnmanaged(LIMB) = .empty;
    defer work.deinit(allocator);
    try work.ensureTotalCapacity(allocator, al);
    var idx: usize = 0;
    while (idx < al) : (idx += 1) try work.append(allocator, a[idx]);

    const qlen = al - bl + 1;
    var quotient: std.ArrayListUnmanaged(LIMB) = .empty;
    defer quotient.deinit(allocator);
    try quotient.ensureTotalCapacity(allocator, qlen);
    var qi: usize = 0;
    while (qi < qlen) : (qi += 1) try quotient.append(allocator, 0);

    var pos: usize = al - bl;
    while (true) : (pos = if (pos == 0) 0 else pos - 1) {
        const w_top: u128 = if (pos + bl < work.items.len) @as(u128, work.items[pos + bl]) else 0;
        const w_next: u128 = work.items[pos + bl - 1];
        const b_top: u128 = b[bl - 1];

        var q_hat: LIMB = 0;
        if (b_top > 0) {
            const combined = w_top * Base + w_next;
            const q_hat_est = combined / b_top;
            q_hat = if (q_hat_est >= Base) (Base - 1) else @as(LIMB, @intCast(q_hat_est));
        }

        while (q_hat > 0) {
            var borrow2: u128 = 0;
            var k: usize = 0;
            while (k < bl) : (k += 1) {
                const t: u128 = @as(u128, q_hat) * b[k] + borrow2;
                const idx2 = pos + k;
                const val: u128 = work.items[idx2];
                const rem = @as(LIMB, @intCast(t % Base));
                const div2 = @as(LIMB, @intCast(t / Base));
                if (val >= @as(u128, rem)) {
                    work.items[idx2] = @as(LIMB, @intCast(val - @as(u128, rem)));
                    borrow2 = @as(u128, div2);
                } else {
                    work.items[idx2] = @as(LIMB, @intCast(val + Base - @as(u128, rem)));
                    borrow2 = @as(u128, div2) + 1;
                }
            }
            var bp = pos + bl;
            while (borrow2 > 0 and bp < work.items.len) : (bp += 1) {
                if (work.items[bp] >= @as(LIMB, @intCast(borrow2))) {
                    work.items[bp] -= @as(LIMB, @intCast(borrow2));
                    borrow2 = 0;
                } else {
                    borrow2 -= @as(u128, work.items[bp] + 1);
                    work.items[bp] = 0;
                }
            }
            if (borrow2 > 0) {
                q_hat -= 1;
                var carry2: u128 = 0;
                k = 0;
                while (k < bl or carry2 > 0) : (k += 1) {
                    const s: u128 = @as(u128, work.items[pos + k]) + (if (k < bl) @as(u128, b[k]) else 0) + carry2;
                    work.items[pos + k] = @as(LIMB, @intCast(s % Base));
                    carry2 = s / Base;
                }
            } else break;
        }
        quotient.items[pos] = q_hat;
        if (pos == 0) break;
    }

    var q_res: std.ArrayListUnmanaged(LIMB) = .empty;
    errdefer q_res.deinit(allocator);
    var r_res: std.ArrayListUnmanaged(LIMB) = .empty;
    errdefer r_res.deinit(allocator);

    var q_start: usize = qlen;
    while (q_start > 0 and quotient.items[q_start - 1] == 0) q_start -= 1;
    if (q_start > 0) {
        try q_res.ensureTotalCapacity(allocator, q_start);
        var qs: usize = 0;
        while (qs < q_start) : (qs += 1) try q_res.append(allocator, quotient.items[qs]);
    }

    var r_start: usize = al;
    while (r_start > 1 and work.items[r_start - 1] == 0) r_start -= 1;
    if (r_start > 0) {
        try r_res.ensureTotalCapacity(allocator, r_start);
        var rs: usize = 0;
        while (rs < r_start) : (rs += 1) try r_res.append(allocator, work.items[rs]);
    }

    return .{
        .quotient = try q_res.toOwnedSlice(allocator),
        .remainder = try r_res.toOwnedSlice(allocator),
    };
}
