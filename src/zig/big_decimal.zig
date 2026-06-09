// Arbitrary precision decimal number.
const std = @import("std");
const Allocator = std.mem.Allocator;
const BI = @import("big_int.zig");
const B = @import("big_int_base.zig");

pub const BigDecimal = struct {
    unscaled: BI.BigInt,
    scale: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) BigDecimal {
        return .{
            .unscaled = BI.BigInt.init(allocator),
            .scale = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BigDecimal) void {
        self.unscaled.deinit();
    }

    pub fn isZero(self: BigDecimal) bool {
        return self.unscaled.isZero();
    }

    pub fn clone(self: BigDecimal, allocator: Allocator) anyerror!BigDecimal {
        return .{
            .unscaled = try self.unscaled.clone(allocator),
            .scale = self.scale,
            .allocator = allocator,
        };
    }

    pub fn fromI64(allocator: Allocator, n: i64, scale: usize) BigDecimal {
        var result = BigDecimal.init(allocator);
        result.unscaled.setI64(n);
        result.scale = scale;
        return result;
    }

    pub fn fromString(allocator: Allocator, s: []const u8) anyerror!BigDecimal {
        var result = BigDecimal.init(allocator);
        errdefer result.deinit();

        var i: usize = 0;
        var neg: bool = false;
        if (i < s.len and (s[i] == '-' or s[i] == '+')) {
            neg = s[i] == '-';
            i += 1;
        }

        var int_part: std.ArrayListUnmanaged(u8) = .empty;
        var frac_part: std.ArrayListUnmanaged(u8) = .empty;
        errdefer { int_part.deinit(allocator); frac_part.deinit(allocator); }

        var found_dot = false;
        while (i < s.len) : (i += 1) {
            if (s[i] == '.') {
                if (found_dot) return error.InvalidNumber;
                found_dot = true;
                continue;
            }
            if (!std.ascii.isDigit(s[i])) return error.InvalidNumber;
            if (found_dot) {
                try frac_part.append(allocator, s[i]);
            } else {
                try int_part.append(allocator, s[i]);
            }
        }

        var full: std.ArrayListUnmanaged(u8) = .empty;
        defer full.deinit(allocator);
        if (neg) try full.append(allocator, '-');
        if (int_part.items.len > 0) {
            try full.appendSlice(allocator, int_part.items);
        } else {
            try full.append(allocator, '0');
        }
        try full.appendSlice(allocator, frac_part.items);

        if (full.items.len == 0 or (full.items.len == 1 and (full.items[0] == '-' or full.items[0] == '+'))) {
            result.unscaled.setI64(0);
        } else {
            result.unscaled = try BI.bigIntFromString(allocator, full.items);
        }
        result.scale = frac_part.items.len;
        return result;
    }

    pub fn toString(self: BigDecimal, allocator: Allocator) anyerror![]const u8 {
        if (self.isZero()) return allocator.dupe(u8, "0");

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        const abs_val = try self.unscaled.abs(allocator);
        const abs_str = try abs_val.toString(allocator);
        defer allocator.free(abs_str);

        const digits = abs_str;
        const digit_len = digits.len;

        if (self.scale == 0) {
            try buf.appendSlice(allocator, digits);
            return buf.toOwnedSlice(allocator);
        }

        if (digit_len <= self.scale) {
            try buf.appendSlice(allocator, "0.");
            var pad: usize = self.scale - digit_len;
            while (pad > 0) : (pad -= 1) try buf.append(allocator, '0');
            try buf.appendSlice(allocator, digits);
        } else {
            const int_end = digit_len - self.scale;
            try buf.appendSlice(allocator, digits[0..int_end]);
            try buf.append(allocator, '.');
            try buf.appendSlice(allocator, digits[int_end..]);
        }

        return buf.toOwnedSlice(allocator);
    }
};

pub fn compare(a: BigDecimal, b: BigDecimal) B.CompareResult {
    const allocator = a.allocator;
    const max_scale = if (a.scale > b.scale) a.scale else b.scale;
    var a_scaled = scaleUp(allocator, a, max_scale);
    var b_scaled = scaleUp(allocator, b, max_scale);
    defer { a_scaled.deinit(); b_scaled.deinit(); }
    return BI.compare(a_scaled.unscaled, b_scaled.unscaled);
}

pub fn equals(a: BigDecimal, b: BigDecimal) bool {
    return compare(a, b) == .equal;
}

fn scaleUp(allocator: Allocator, d: BigDecimal, new_scale: usize) BigDecimal {
    if (new_scale <= d.scale) return d.clone(allocator) catch unreachable;
    var result = BigDecimal.init(allocator);
    result.scale = new_scale;
    result.unscaled = BI.mulBySmall(allocator, d.unscaled, pow10(new_scale - d.scale));
    return result;
}

fn pow10(n: usize) u64 {
    var result: u64 = 1;
    var i: usize = 0;
    while (i < n) : (i += 1) result *= 10;
    return result;
}

pub fn add(a: BigDecimal, b: BigDecimal) BigDecimal {
    const allocator = a.allocator;
    const max_scale = if (a.scale > b.scale) a.scale else b.scale;
    var a_scaled = scaleUp(allocator, a, max_scale);
    var b_scaled = scaleUp(allocator, b, max_scale);
    defer { a_scaled.deinit(); b_scaled.deinit(); }
    var result = BigDecimal.init(allocator);
    result.scale = max_scale;
    result.unscaled = BI.add(a_scaled.unscaled, b_scaled.unscaled);
    return result;
}

pub fn sub(a: BigDecimal, b: BigDecimal) BigDecimal {
    const allocator = a.allocator;
    const max_scale = if (a.scale > b.scale) a.scale else b.scale;
    var a_scaled = scaleUp(allocator, a, max_scale);
    var b_scaled = scaleUp(allocator, b, max_scale);
    defer { a_scaled.deinit(); b_scaled.deinit(); }
    var result = BigDecimal.init(allocator);
    result.scale = max_scale;
    result.unscaled = BI.sub(a_scaled.unscaled, b_scaled.unscaled);
    return result;
}

pub fn mul(a: BigDecimal, b: BigDecimal) BigDecimal {
    const allocator = a.allocator;
    var result = BigDecimal.init(allocator);
    result.scale = a.scale + b.scale;
    result.unscaled = BI.mul(a.unscaled, b.unscaled);
    return result;
}

pub fn div(a: BigDecimal, b: BigDecimal) anyerror!BigDecimal {
    if (b.isZero()) return error.DivisionByZero;
    const allocator = a.allocator;
    const extra_scale: usize = 18;
    var num = BI.mulBySmall(allocator, a.unscaled, pow10(b.scale + extra_scale));
    defer num.deinit();
    var dm = try BI.divmod(num, b.unscaled);
    defer dm.remainder.deinit();
    var result = BigDecimal.init(allocator);
    result.scale = a.scale + b.scale + extra_scale;
    result.unscaled = dm.quotient;
    return result;
}

pub fn negate(a: BigDecimal) BigDecimal {
    var result = a;
    result.unscaled.negate();
    return result;
}
