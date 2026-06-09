// Exact rational number: numerator / denominator (both BigInt).
const std = @import("std");
const Allocator = std.mem.Allocator;
const BI = @import("big_int.zig");
const B = @import("big_int_base.zig");

pub const Ratio = struct {
    num: BI.BigInt,
    den: BI.BigInt,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Ratio {
        return .{
            .num = BI.BigInt.init(allocator),
            .den = BI.BigInt.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Ratio) void {
        self.num.deinit();
        self.den.deinit();
    }

    pub fn isZero(self: Ratio) bool {
        return self.num.isZero();
    }

    pub fn clone(self: Ratio, allocator: Allocator) anyerror!Ratio {
        return .{
            .num = try self.num.clone(allocator),
            .den = try self.den.clone(allocator),
            .allocator = allocator,
        };
    }

    pub fn fromI64(allocator: Allocator, n: i64, d: i64) anyerror!Ratio {
        if (d == 0) return error.DivisionByZero;
        var r = Ratio.init(allocator);
        errdefer r.deinit();
        r.num.setI64(n);
        r.den.setU64(if (d < 0) @as(u64, @intCast(-d)) else @as(u64, @intCast(d)));
        if (d < 0) r.num.negate();
        r.normalize();
        return r;
    }

    pub fn fromBigInt(allocator: Allocator, n: BI.BigInt, d: BI.BigInt) anyerror!Ratio {
        if (d.isZero()) return error.DivisionByZero;
        var r = Ratio.init(allocator);
        errdefer r.deinit();
        r.num = try n.clone(allocator);
        r.den = try d.clone(allocator);
        if (r.den.sign == .negative) {
            r.den.negate();
            r.num.negate();
        }
        r.normalize();
        return r;
    }

    pub fn normalize(self: *Ratio) void {
        if (self.den.sign == .negative) {
            self.den.negate();
            self.num.negate();
        }
        self.den.normalize();
        self.num.normalize();
        if (self.num.isZero()) {
            self.den.setU64(1);
            return;
        }
        var g = BI.gcd(self.num, self.den) catch return;
        defer g.deinit();
        if (g.isZero()) return;
        var dn = BI.divmod(self.num, g) catch unreachable;
        var dd = BI.divmod(self.den, g) catch unreachable;
        dn.remainder.deinit();
        dd.remainder.deinit();
        self.num = dn.quotient;
        self.den = dd.quotient;
    }

    pub fn toString(self: Ratio, allocator: Allocator) anyerror![]const u8 {
        if (self.den.isZero() or (self.den.limbs.len == 1 and self.den.limbs[0] == 1)) {
            return try self.num.toString(allocator);
        }
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, try self.num.toString(allocator));
        try buf.append(allocator, '/');
        try buf.appendSlice(allocator, try self.den.toString(allocator));
        return buf.toOwnedSlice(allocator);
    }
};

pub fn compare(a: Ratio, b: Ratio) B.CompareResult {
    var ad = BI.mul(a.num, b.den);
    var bd = BI.mul(b.num, a.den);
    defer { ad.deinit(); bd.deinit(); }
    return BI.compare(ad, bd);
}

pub fn equals(a: Ratio, b: Ratio) bool {
    return compare(a, b) == .equal;
}

pub fn add(a: Ratio, b: Ratio) Ratio {
    const allocator = a.allocator;
    var an_bd = BI.mul(a.num, b.den);
    var bn_ad = BI.mul(b.num, a.den);
    const new_num = BI.add(an_bd, bn_ad);
    defer { an_bd.deinit(); bn_ad.deinit(); }
    const new_den = BI.mul(a.den, b.den);
    var result = Ratio.init(allocator);
    result.num = new_num;
    result.den = new_den;
    result.normalize();
    return result;
}

pub fn sub(a: Ratio, b: Ratio) Ratio {
    const allocator = a.allocator;
    var an_bd = BI.mul(a.num, b.den);
    var bn_ad = BI.mul(b.num, a.den);
    const new_num = BI.sub(an_bd, bn_ad);
    defer { an_bd.deinit(); bn_ad.deinit(); }
    const new_den = BI.mul(a.den, b.den);
    var result = Ratio.init(allocator);
    result.num = new_num;
    result.den = new_den;
    result.normalize();
    return result;
}

pub fn mul(a: Ratio, b: Ratio) Ratio {
    const allocator = a.allocator;
    const new_num = BI.mul(a.num, b.num);
    const new_den = BI.mul(a.den, b.den);
    var result = Ratio.init(allocator);
    result.num = new_num;
    result.den = new_den;
    result.normalize();
    return result;
}

pub fn div(a: Ratio, b: Ratio) anyerror!Ratio {
    if (b.isZero()) return error.DivisionByZero;
    const allocator = a.allocator;
    const new_num = BI.mul(a.num, b.den);
    const new_den = BI.mul(a.den, b.num);
    var result = Ratio.init(allocator);
    result.num = new_num;
    result.den = new_den;
    result.normalize();
    return result;
}

pub fn negate(a: Ratio) Ratio {
    var result = a;
    result.num.negate();
    return result;
}
