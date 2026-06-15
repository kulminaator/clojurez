// Type checking predicates, type constructors, and numeric coercion
// nil?, number?, string?, list?, symbol?, keyword?, true?, false?, fn?,
// vector?, map?, queue?, coll?, sequential?, keyword
// integer?, int?, double?, float?, NaN?, infinite?
// int, float, double, bigint, bigdec, byte, short
const std = @import("std");
const Value = @import("../../value.zig");
const list = @import("../../list.zig");
const Env = Value.Env;
const BI = @import("../../big_int.zig");
const test_utils = @import("test_utils.zig");
const BD = @import("../../big_decimal.zig");
const RatioMod = @import("../../ratio.zig");
const Allocator = std.mem.Allocator;

// Type predicates
pub fn core_nil_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .nil);
}

pub fn core_number_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const t = args.items[0].type;
    return Value.boolValue(t == .integer or t == .float or t == .bigint or t == .ratio or t == .decimal);
}

pub fn core_string_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .string);
}

pub fn core_regex_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .regex);
}

pub fn core_list_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .list);
}

pub fn core_symbol_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .symbol);
}

pub fn core_keyword_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .keyword);
}

pub fn core_true_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .bool and args.items[0].bool_val);
}

pub fn core_false_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .bool and !args.items[0].bool_val);
}

/// Returns true if x is a boolean (true or false).
/// Clojure: (boolean? x)
pub fn core_boolean_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .bool);
}

/// Returns true if x is a character.
/// Clojure: (char? x)
pub fn core_char_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .character);
}

/// Coerce to char. Accepts a char (identity) or an integer (converts to char).
/// Clojure: (char x)
pub fn core_char(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (v.type) {
        .character => Value.charValue(v.char_val),
        .string => {
            // Extract the first code point from the string
            const s = v.str_val;
            if (s.len == 0) return error.EmptyString;
            const view = std.unicode.Utf8View.init(s) catch return error.InvalidUtf8;
            var it = view.iterator();
            const first_cp = it.nextCodepoint() orelse return error.EmptyString;
            if (first_cp > 0x10FFFF) return error.CharacterOutOfRange;
            return Value.charValue(@as(u21, @intCast(first_cp)));
        },
        .integer => {
            const i = v.int_val;
            if (i < 0) return error.NegativeCharacter;
            if (i > 0x10FFFF) return error.CharacterOutOfRange;
            return Value.charValue(@as(u21, @intCast(i)));
        },
        .float => {
            const f = v.float_val;
            if (f < 0) return error.NegativeCharacter;
            const i = @as(i64, @intFromFloat(f));
            if (i > 0x10FFFF) return error.CharacterOutOfRange;
            return Value.charValue(@as(u21, @intCast(i)));
        },
        .bigint => {
            if (v.bigint_val) |ptr| {
                const i64_val = ptr.toI64() orelse return error.CharacterOutOfRange;
                if (i64_val < 0) return error.NegativeCharacter;
                if (i64_val > 0x10FFFF) return error.CharacterOutOfRange;
                return Value.charValue(@as(u21, @intCast(i64_val)));
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    };
}

pub fn core_fn_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .function or args.items[0].type == .builtin_fn);
}

pub fn core_vector_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .vector);
}

pub fn core_map_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .map);
}

pub fn core_queue_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return Value.boolValue(args.items[0].type == .queue);
}

pub fn core_coll_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    return Value.boolValue(switch (coll.type) {
        .list, .vector, .map, .set, .queue => true,
        else => false,
    });
}

pub fn core_sequential_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    return Value.boolValue(coll.type == .list or coll.type == .vector);
}

// Type constructor
pub fn core_keyword(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len == 1) {
        const arg = args.items[0];
        if (arg.type == .keyword) return try arg.clone(allocator);
        if (arg.type == .symbol) {
            return Value.keywordValue(allocator, arg.sym_val);
        }
        if (arg.type == .string) {
            return Value.keywordValue(allocator, arg.str_val);
        }
    } else if (args.items.len == 2) {
        const ns = args.items[0];
        const name = args.items[1];
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        switch (ns.type) {
            .string => try buf.appendSlice(allocator, ns.str_val),
            .symbol => try buf.appendSlice(allocator, ns.sym_val),
            .keyword => try buf.appendSlice(allocator, ns.kw_val),
            else => return error.TypeError,
        }
        try buf.appendSlice(allocator, "/");
        switch (name.type) {
            .string => try buf.appendSlice(allocator, name.str_val),
            .symbol => try buf.appendSlice(allocator, name.sym_val),
            .keyword => try buf.appendSlice(allocator, name.kw_val),
            else => return error.TypeError,
        }
        return Value.keywordValue(allocator, buf.items);
    }
    return error.ArityError;
}

// ============================================================
// Numeric type predicates
// ============================================================

pub fn core_integer_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const t = args.items[0].type;
    return Value.boolValue(t == .integer or t == .bigint);
}

pub fn core_int_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // int? checks for fixed-precision integers (not bigint)
    // Our integer type (i64) covers Long/Integer/Short/Byte
    return Value.boolValue(args.items[0].type == .integer);
}

pub fn core_double_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Our float type is f64 (double precision)
    return Value.boolValue(args.items[0].type == .float);
}

pub fn core_float_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Clojure float? checks for Double or Float.
    // We only have f64, so same as double?
    return Value.boolValue(args.items[0].type == .float);
}

pub fn core_nan_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    if (v.type != .float) return Value.boolValue(false);
    return Value.boolValue(std.math.isNan(v.float_val));
}

pub fn core_infinite_q(self: *Value, args: list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    if (v.type != .float) return Value.boolValue(false);
    return Value.boolValue(std.math.isInf(v.float_val));
}

// ============================================================
// Numeric coercion functions
// ============================================================

/// Helper: coerce any numeric value to i64, returning null on failure.
fn coerceToInt(v: Value, allocator: Allocator) ?i64 {
    return switch (v.type) {
        .integer => v.int_val,
        .float => @as(i64, @intFromFloat(v.float_val)),
        .bigint => {
            if (v.bigint_val) |ptr| return ptr.toI64();
            return null;
        },
        .ratio => {
            if (v.ratio_val) |ptr| {
                var num = ptr.num.clone(allocator) catch return null;
                var den = ptr.den.clone(allocator) catch return null;
                defer { num.deinit(); den.deinit(); }
                var dm = BI.divmod(num, den) catch return null;
                defer dm.remainder.deinit();
                return dm.quotient.toI64();
            }
            return null;
        },
        .decimal => {
            if (v.decimal_val) |ptr| {
                if (ptr.scale == 0) return ptr.unscaled.toI64();
                var num = ptr.unscaled.clone(allocator) catch return null;
                var den = BI.bigIntFromI64(allocator, 1);
                var s: usize = 0;
                while (s < ptr.scale) : (s += 1) {
                    den = BI.mul(den, BI.bigIntFromI64(allocator, 10));
                }
                defer { num.deinit(); den.deinit(); }
                var dm = BI.divmod(num, den) catch return null;
                defer dm.remainder.deinit();
                return dm.quotient.toI64();
            }
            return null;
        },
        .character => @as(i64, @intCast(v.char_val)),
        else => null,
    };
}

pub fn core_int(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    const i = coerceToInt(v, allocator) orelse return error.TypeError;
    return Value.intValue(i);
}

pub fn core_float(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (v.type) {
        .float => Value.floatValue(v.float_val),
        .integer => Value.floatValue(@as(f64, @floatFromInt(v.int_val))),
        .bigint => {
            if (v.bigint_val) |ptr| {
                const s = try ptr.toString(allocator);
                defer allocator.free(s);
                const f = try std.fmt.parseFloat(f64, s);
                return Value.floatValue(f);
            }
            return error.TypeError;
        },
        .ratio => {
            if (v.ratio_val) |ptr| {
                const num_s = try ptr.num.toString(allocator);
                defer allocator.free(num_s);
                const den_s = try ptr.den.toString(allocator);
                defer allocator.free(den_s);
                const num_f = try std.fmt.parseFloat(f64, num_s);
                const den_f = try std.fmt.parseFloat(f64, den_s);
                return Value.floatValue(num_f / den_f);
            }
            return error.TypeError;
        },
        .decimal => {
            if (v.decimal_val) |ptr| {
                const s = try ptr.toString(allocator);
                defer allocator.free(s);
                const f = try std.fmt.parseFloat(f64, s);
                return Value.floatValue(f);
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    };
}

pub fn core_double(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    // Same as float since our float is f64 (double precision)
    return core_float(self, args, env_env);
}

pub fn core_bigint(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (v.type) {
        .bigint => try v.clone(allocator),
        .integer => try Value.bigIntValue(allocator, BI.bigIntFromI64(allocator, v.int_val)),
        .float => {
            // Convert float to BigDecimal string, then truncate to BigInt
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v.float_val});
            defer allocator.free(s);
            var bd = try BD.BigDecimal.fromString(allocator, s);
            defer bd.deinit();
            // Truncate: divide unscaled by 10^scale
            if (bd.scale == 0) {
                return try Value.bigIntValue(allocator, try bd.unscaled.clone(allocator));
            }
            var num = try bd.unscaled.clone(allocator);
            var den = BI.bigIntFromI64(allocator, 1);
            var s_idx: usize = 0;
            while (s_idx < bd.scale) : (s_idx += 1) {
                den = BI.mul(den, BI.bigIntFromI64(allocator, 10));
            }
            defer { num.deinit(); den.deinit(); }
            var dm = try BI.divmod(num, den);
            defer dm.remainder.deinit();
            return try Value.bigIntValue(allocator, try dm.quotient.clone(allocator));
        },
        .ratio => {
            if (v.ratio_val) |ptr| {
                // Truncate ratio: divide num by den
                var num = try ptr.num.clone(allocator);
                var den = try ptr.den.clone(allocator);
                defer { num.deinit(); den.deinit(); }
                var dm = try BI.divmod(num, den);
                defer dm.remainder.deinit();
                return try Value.bigIntValue(allocator, try dm.quotient.clone(allocator));
            }
            return error.TypeError;
        },
        .decimal => {
            if (v.decimal_val) |ptr| {
                // Truncate: divide unscaled by 10^scale
                if (ptr.scale == 0) {
                    return try Value.bigIntValue(allocator, try ptr.unscaled.clone(allocator));
                }
                var num = try ptr.unscaled.clone(allocator);
                var den = BI.bigIntFromI64(allocator, 1);
                var s: usize = 0;
                while (s < ptr.scale) : (s += 1) {
                    den = BI.mul(den, BI.bigIntFromI64(allocator, 10));
                }
                defer { num.deinit(); den.deinit(); }
                var dm = try BI.divmod(num, den);
                defer dm.remainder.deinit();
                return try Value.bigIntValue(allocator, try dm.quotient.clone(allocator));
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    };
}

pub fn core_bigdec(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (v.type) {
        .decimal => try v.clone(allocator),
        .integer => try Value.decimalValue(allocator, BD.BigDecimal.fromI64(allocator, v.int_val, 0)),
        .float => {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v.float_val});
            defer allocator.free(s);
            return try Value.decimalValue(allocator, try BD.BigDecimal.fromString(allocator, s));
        },
        .bigint => {
            if (v.bigint_val) |ptr| {
                const s = try ptr.toString(allocator);
                defer allocator.free(s);
                return try Value.decimalValue(allocator, try BD.BigDecimal.fromString(allocator, s));
            }
            return error.TypeError;
        },
        .ratio => {
            if (v.ratio_val) |ptr| {
                // Convert ratio to decimal: num / den
                const num_bd = try Value.decimalValue(allocator, try BD.BigDecimal.fromString(
                    allocator, try ptr.num.toString(allocator)));
                const den_bd = try Value.decimalValue(allocator, try BD.BigDecimal.fromString(
                    allocator, try ptr.den.toString(allocator)));
                if (num_bd.decimal_val) |np| {
                    if (den_bd.decimal_val) |dp| {
                        var n = try np.clone(allocator);
                        var d = try dp.clone(allocator);
                        defer { n.deinit(); d.deinit(); }
                        var result = try BD.div(n, d);
                        defer result.deinit();
                        return try Value.decimalValue(allocator, try result.clone(allocator));
                    }
                }
                return error.TypeError;
            }
            return error.TypeError;
        },
        else => return error.TypeError,
    };
}

pub fn core_byte(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Coerce to integer first, then truncate to i8 range (wrapping)
    const v = args.items[0];
    const int_val = coerceToInt(v, env_env.allocator) orelse return error.TypeError;
    // Truncate: take lower 8 bits, interpret as signed
    const b8: u8 = @truncate(@as(u64, @intCast(int_val)));
    const signed_b8: i8 = @as(i8, @bitCast(b8));
    return Value.intValue(@as(i64, @intCast(signed_b8)));
}

pub fn core_short(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Coerce to integer first, then truncate to i16 range (wrapping)
    const v = args.items[0];
    const int_val = coerceToInt(v, env_env.allocator) orelse return error.TypeError;
    // Truncate: take lower 16 bits, interpret as signed
    const b16: u16 = @truncate(@as(u64, @intCast(int_val)));
    const signed_b16: i16 = @as(i16, @bitCast(b16));
    return Value.intValue(@as(i64, @intCast(signed_b16)));
}

/// Returns a keyword representing the runtime type of x.
/// Clojure: (type x)
/// E.g. (type "hello") => :string, (type 42) => :integer, (type nil) => :nil
pub fn core_type(self: *Value, args: list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const type_name = switch (args.items[0].type) {
        .nil => "nil",
        .bool => "bool",
        .integer => "integer",
        .float => "float",
        .bigint => "bigint",
        .ratio => "ratio",
        .decimal => "decimal",
        .string => "string",
        .regex => "regex",
        .character => "character",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .vector => "vector",
        .map => "map",
        .set => "set",
        .queue => "queue",
        .atom => "atom",
        .function => "function",
        .builtin_fn => "builtin_fn",
        .lazy_seq => "lazy_seq",
        .cons => "cons",
        .reduced => "reduced",
        .wrapped => "wrapped",
        .record => args.items[0].record_val.type_name,
    };
    return try Value.keywordValue(env_env.allocator, type_name);
}

pub fn registerTypePredicateFunctions(env: *Env) anyerror!void {
    try env.put("nil?", Value.builtinFnValue(core_nil_q));
    try env.put("number?", Value.builtinFnValue(core_number_q));
    try env.put("string?", Value.builtinFnValue(core_string_q));
    try env.put("regex?", Value.builtinFnValue(core_regex_q));
    try env.put("list?", Value.builtinFnValue(core_list_q));
    try env.put("symbol?", Value.builtinFnValue(core_symbol_q));
    try env.put("keyword?", Value.builtinFnValue(core_keyword_q));
    try env.put("true?", Value.builtinFnValue(core_true_q));
    try env.put("false?", Value.builtinFnValue(core_false_q));
    try env.put("fn?", Value.builtinFnValue(core_fn_q));
    try env.put("vector?", Value.builtinFnValue(core_vector_q));
    try env.put("map?", Value.builtinFnValue(core_map_q));
    try env.put("queue?", Value.builtinFnValue(core_queue_q));
    try env.put("coll?", Value.builtinFnValue(core_coll_q));
    try env.put("sequential?", Value.builtinFnValue(core_sequential_q));
    try env.put("boolean?", Value.builtinFnValue(core_boolean_q));
    // Character type predicate and coercion
    try env.put("char?", Value.builtinFnValue(core_char_q));
    try env.put("char", Value.builtinFnValue(core_char));
    // Numeric type predicates
    try env.put("integer?", Value.builtinFnValue(core_integer_q));
    try env.put("int?", Value.builtinFnValue(core_int_q));
    try env.put("double?", Value.builtinFnValue(core_double_q));
    try env.put("float?", Value.builtinFnValue(core_float_q));
    try env.put("NaN?", Value.builtinFnValue(core_nan_q));
    try env.put("infinite?", Value.builtinFnValue(core_infinite_q));
    // Numeric coercion functions
    try env.put("int", Value.builtinFnValue(core_int));
    try env.put("float", Value.builtinFnValue(core_float));
    try env.put("double", Value.builtinFnValue(core_double));
    try env.put("bigint", Value.builtinFnValue(core_bigint));
    try env.put("bigdec", Value.builtinFnValue(core_bigdec));
    try env.put("byte", Value.builtinFnValue(core_byte));
    try env.put("short", Value.builtinFnValue(core_short));
    // Type constructors
    try env.put("keyword", Value.builtinFnValue(core_keyword));
    // Type introspection
    try env.put("type", Value.builtinFnValue(core_type));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "type_predicates::nil_q: nil is nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_nil_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::nil_q: int is not nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(1) });
    var result = core_nil_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::number_q: integer is number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_number_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::number_q: float is number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(3.14) });
    var result = core_number_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::number_q: nil is not number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_number_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::true_q: true is true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.boolValue(true) });
    var result = core_true_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::true_q: false is not true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.boolValue(false) });
    var result = core_true_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::false_q: false is false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.boolValue(false) });
    var result = core_false_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::coll_q: list is coll" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_coll_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::coll_q: nil is not coll" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_coll_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::sequential_q: list is sequential" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.listValue(list.empty()) });
    var result = core_sequential_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::sequential_q: set is not sequential" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.setValue(.empty) });
    var result = core_sequential_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

// Numeric type predicate tests

test "type_predicates::integer_q: int is integer" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_integer_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::integer_q: float is not integer" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(1.5) });
    var result = core_integer_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::int_q: int is int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_int_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::double_q: float is double" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(1.5) });
    var result = core_double_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::double_q: int is not double" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_double_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::float_q: float is float" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(1.5) });
    var result = core_float_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::nan_q: nan is nan" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(std.math.nan(f64)) });
    var result = core_nan_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::nan_q: normal float is not nan" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(1.5) });
    var result = core_nan_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::nan_q: int is not nan" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_nan_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::infinite_q: positive infinity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(std.math.inf(f64)) });
    var result = core_infinite_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::infinite_q: negative infinity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(-std.math.inf(f64)) });
    var result = core_infinite_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::infinite_q: normal float is not infinite" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(1.5) });
    var result = core_infinite_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

// Numeric coercion tests

test "type_predicates::core_int: float to int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(3.7) });
    var result = core_int(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == 3);
}

test "type_predicates::core_int: float to int negative" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(-3.7) });
    var result = core_int(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .integer);
    try std.testing.expect(result.int_val == -3);
}

test "type_predicates::core_float: int to float" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_float(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .float);
    try std.testing.expect(result.float_val == 42.0);
}

test "type_predicates::core_byte: in range" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(127) });
    var result = core_byte(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 127);
}

test "type_predicates::core_byte: overflow wraps" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(256) });
    var result = core_byte(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == 0);
}

test "type_predicates::core_byte: 128 wraps to -128" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(128) });
    var result = core_byte(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == -128);
}

test "type_predicates::core_short: overflow wraps" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(32768) });
    var result = core_short(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.int_val == -32768);
}

test "type_predicates::core_bigint: int to bigint" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_bigint(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .bigint);
}

test "type_predicates::core_bigdec: int to bigdec" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_bigdec(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .decimal);
}

test "type_predicates::core_int: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_int(testSelf(), args, &a));
}

test "type_predicates::core_integer_q: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_integer_q(testSelf(), args, &a));
}

// Character type tests

test "type_predicates::char_q: char is char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.charValue(65) });
    var result = core_char_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == true);
}

test "type_predicates::char_q: int is not char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(65) });
    var result = core_char_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::char_q: string is not char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try Value.stringValue(std.heap.page_allocator, "A");
    defer s.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_char_q(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.bool_val == false);
}

test "type_predicates::char: int to char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(65) });
    var result = core_char(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .character);
    try std.testing.expect(result.char_val == 65);
}

test "type_predicates::char: char identity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.charValue(65) });
    var result = core_char(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .character);
    try std.testing.expect(result.char_val == 65);
}

test "type_predicates::char: float to char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.floatValue(97.9) });
    var result = core_char(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .character);
    try std.testing.expect(result.char_val == 97);
}

test "type_predicates::char: negative int error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(-1) });
    try std.testing.expectError(error.NegativeCharacter, core_char(testSelf(), args, &a));
}

test "type_predicates::char: out of range error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(0x110000) });
    try std.testing.expectError(error.CharacterOutOfRange, core_char(testSelf(), args, &a));
}

test "type_predicates::char: string to char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try Value.stringValue(std.heap.page_allocator, "A");
    defer s.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    const result = core_char(testSelf(), args, &a) catch unreachable;
    try std.testing.expect(result.type == .character);
    try std.testing.expect(result.char_val == 'A');
}

test "type_predicates::char: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_char(testSelf(), args, &a));
}

test "type_predicates::char_q: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_char_q(testSelf(), args, &a));
}

test "type_predicates::type: returns :string for string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.stringValue(std.heap.page_allocator, "hello") catch unreachable });
    var result = core_type(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.kw_val, "string"));
}

test "type_predicates::type: returns :integer for integer" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.intValue(42) });
    var result = core_type(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.kw_val, "integer"));
}

test "type_predicates::type: returns :nil for nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.nilValue() });
    var result = core_type(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.kw_val, "nil"));
}

test "type_predicates::type: returns :bool for true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ Value.boolValue(true) });
    var result = core_type(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.kw_val, "bool"));
}

test "type_predicates::type: returns :map for map" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m: Value.Map = .empty;
    const alloc = std.heap.page_allocator;
    try m.append(alloc, .{ .key = Value.keywordValue(alloc, "a") catch unreachable, .value = Value.intValue(1) });
    const map_val = Value.mapValue(m);
    const args = makeArgs(&[_]Value{ map_val });
    var result = core_type(testSelf(), args, &a) catch unreachable;
    defer result.deinit(std.heap.page_allocator);
    try std.testing.expect(result.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.kw_val, "map"));
}

test "type_predicates::type: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_type(testSelf(), args, &a));
}

