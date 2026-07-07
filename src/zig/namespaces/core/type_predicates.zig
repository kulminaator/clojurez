// Type checking predicates, type constructors, and numeric coercion
// nil?, number?, string?, list?, symbol?, keyword?, true?, false?, fn?,
// vector?, map?, queue?, coll?, sequential?, keyword
// integer?, int?, double?, float?, NaN?, infinite?
// int, float, double, bigint, bigdec, byte, short
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const BI = @import("../../big_int.zig");
const test_utils = @import("test_utils.zig");
const BD = @import("../../big_decimal.zig");
const RatioMod = @import("../../ratio.zig");
const Allocator = std.mem.Allocator;

// Type predicates
pub fn core_nil_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .nil);
}

pub fn core_number_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const t = std.meta.activeTag(args.items[0]);
    return vm.boolValue(t == .integer or t == .float or t == .bigint or t == .ratio or t == .decimal);
}

pub fn core_string_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .string);
}

pub fn core_regex_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .regex);
}

pub fn core_list_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .list);
}

pub fn core_symbol_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .symbol);
}

pub fn core_keyword_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .keyword);
}

pub fn core_true_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .bool and args.items[0].bool);
}

pub fn core_false_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .bool and !args.items[0].bool);
}

/// Returns true if x is a boolean (true or false).
/// Clojure: (boolean? x)
pub fn core_boolean_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .bool);
}

/// Returns true if x is a character.
/// Clojure: (char? x)
pub fn core_char_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .character);
}

/// Coerce to char. Accepts a char (identity) or an integer (converts to char).
/// Clojure: (char x)
pub fn core_char(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (std.meta.activeTag(v)) {
        .character => vm.charValue(v.character),
        .string => {
            // Extract the first code point from the string
            const s = v.string;
            if (s.len == 0) return error.EmptyString;
            const view = std.unicode.Utf8View.init(s) catch return error.InvalidUtf8;
            var it = view.iterator();
            const first_cp = it.nextCodepoint() orelse return error.EmptyString;
            if (first_cp > 0x10FFFF) return error.CharacterOutOfRange;
            return vm.charValue(@as(u21, @intCast(first_cp)));
        },
        .integer => {
            const i = v.integer;
            if (i < 0) return error.NegativeCharacter;
            if (i > 0x10FFFF) return error.CharacterOutOfRange;
            return vm.charValue(@as(u21, @intCast(i)));
        },
        .float => {
            const f = v.float;
            if (f < 0) return error.NegativeCharacter;
            const i = @as(i64, @intFromFloat(f));
            if (i > 0x10FFFF) return error.CharacterOutOfRange;
            return vm.charValue(@as(u21, @intCast(i)));
        },
        .bigint => {
            const ptr = v.bigint;
            const i64_val = ptr.toI64() orelse return error.CharacterOutOfRange;
            if (i64_val < 0) return error.NegativeCharacter;
            if (i64_val > 0x10FFFF) return error.CharacterOutOfRange;
            return vm.charValue(@as(u21, @intCast(i64_val)));
        },
        else => return error.TypeError,
    };
}

pub fn core_fn_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .function or std.meta.activeTag(args.items[0]) == .builtin_fn);
}

pub fn core_vector_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .vector);
}

pub fn core_map_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // In Clojure, map? returns true for both maps and records
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .map or std.meta.activeTag(args.items[0]) == .record);
}

pub fn core_record_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .record);
}

pub fn core_queue_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .queue);
}

/// Returns true if x is a future value.
pub fn core_future_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .future);
}

/// Returns true if x is a promise value.
pub fn core_promise_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .promise);
}

pub fn core_coll_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    return vm.boolValue(switch (std.meta.activeTag(coll)) {
        .list, .vector, .map, .set, .queue, .record => true,
        else => false,
    });
}

pub fn core_sequential_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const coll = args.items[0];
    return vm.boolValue(std.meta.activeTag(coll) == .list or std.meta.activeTag(coll) == .vector);
}

// Type constructor
pub fn core_keyword(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len == 1) {
        const arg = args.items[0];
        if (std.meta.activeTag(arg) == .keyword) return try vm.shallowClone(&arg, allocator);
        if (std.meta.activeTag(arg) == .symbol) {
            return vm.keywordValue(allocator, arg.symbol);
        }
        if (std.meta.activeTag(arg) == .string) {
            return vm.keywordValue(allocator, arg.string);
        }
    } else if (args.items.len == 2) {
        const ns = args.items[0];
        const name = args.items[1];
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        switch (std.meta.activeTag(ns)) {
            .string => try buf.appendSlice(allocator, ns.string),
            .symbol => try buf.appendSlice(allocator, ns.symbol),
            .keyword => try buf.appendSlice(allocator, ns.keyword),
            else => return error.TypeError,
        }
        try buf.appendSlice(allocator, "/");
        switch (std.meta.activeTag(name)) {
            .string => try buf.appendSlice(allocator, name.string),
            .symbol => try buf.appendSlice(allocator, name.symbol),
            .keyword => try buf.appendSlice(allocator, name.keyword),
            else => return error.TypeError,
        }
        return vm.keywordValue(allocator, buf.items);
    }
    return error.ArityError;
}

// ============================================================
// Numeric type predicates
// ============================================================

pub fn core_integer_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const t = std.meta.activeTag(args.items[0]);
    return vm.boolValue(t == .integer or t == .bigint);
}

pub fn core_int_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // int? checks for fixed-precision integers (not bigint)
    // Our integer type (i64) covers Long/Integer/Short/Byte
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .integer);
}

pub fn core_double_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Our float type is f64 (double precision)
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .float);
}

pub fn core_float_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Clojure float? checks for Double or Float.
    // We only have f64, so same as double?
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .float);
}

pub fn core_nan_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    if (std.meta.activeTag(v) != .float) return vm.boolValue(false);
    return vm.boolValue(std.math.isNan(v.float));
}

pub fn core_infinite_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    if (std.meta.activeTag(v) != .float) return vm.boolValue(false);
    return vm.boolValue(std.math.isInf(v.float));
}

// ============================================================
// Numeric coercion functions
// ============================================================

/// Helper: coerce any numeric value to i64, returning null on failure.
fn coerceToInt(v: Value, allocator: Allocator) ?i64 {
    return switch (std.meta.activeTag(v)) {
        .integer => v.integer,
        .float => @as(i64, @intFromFloat(v.float)),
        .bigint => {
            const ptr = v.bigint;
            return ptr.toI64();
        },
        .ratio => {
            const ptr = v.ratio;
            var num = ptr.num.clone(allocator) catch return null;
            var den = ptr.den.clone(allocator) catch return null;
            defer { num.deinit(); den.deinit(); }
            var dm = BI.divmod(num, den) catch return null;
            defer dm.remainder.deinit();
            return dm.quotient.toI64();
        },
        .decimal => {
            const ptr = v.decimal;
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
        },
        .character => @as(i64, @intCast(v.character)),
        else => null,
    };
}

pub fn core_int(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    const i = coerceToInt(v, allocator) orelse return error.TypeError;
    return vm.intValue(i);
}

pub fn core_float(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (std.meta.activeTag(v)) {
        .float => vm.floatValue(v.float),
        .integer => vm.floatValue(@as(f64, @floatFromInt(v.integer))),
        .bigint => {
            const ptr = v.bigint;
            const s = try ptr.toString(allocator);
            defer allocator.free(s);
            const f = try std.fmt.parseFloat(f64, s);
            return vm.floatValue(f);
        },
        .ratio => {
            const ptr = v.ratio;
            const num_s = try ptr.num.toString(allocator);
            defer allocator.free(num_s);
            const den_s = try ptr.den.toString(allocator);
            defer allocator.free(den_s);
            const num_f = try std.fmt.parseFloat(f64, num_s);
            const den_f = try std.fmt.parseFloat(f64, den_s);
            return vm.floatValue(num_f / den_f);
        },
        .decimal => {
            const ptr = v.decimal;
            const s = try ptr.toString(allocator);
            defer allocator.free(s);
            const f = try std.fmt.parseFloat(f64, s);
            return vm.floatValue(f);
        },
        else => return error.TypeError,
    };
}

pub fn core_double(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    // Same as float since our float is f64 (double precision)
    return core_float(self, args, env_env);
}

pub fn core_bigint(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (std.meta.activeTag(v)) {
        .bigint => try vm.shallowClone(&v, allocator),
        .integer => try vm.bigIntValue(allocator, BI.bigIntFromI64(allocator, v.integer)),
        .float => {
            // Convert float to BigDecimal string, then truncate to BigInt
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v.float});
            defer allocator.free(s);
            var bd = try BD.BigDecimal.fromString(allocator, s);
            defer bd.deinit();
            // Truncate: divide unscaled by 10^scale
            if (bd.scale == 0) {
                return try vm.bigIntValue(allocator, try bd.unscaled.clone(allocator));
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
            return try vm.bigIntValue(allocator, try dm.quotient.clone(allocator));
        },
        .ratio => {
            const ptr = v.ratio;
            // Truncate ratio: divide num by den
            var num = try ptr.num.clone(allocator);
            var den = try ptr.den.clone(allocator);
            defer { num.deinit(); den.deinit(); }
            var dm = try BI.divmod(num, den);
            defer dm.remainder.deinit();
            return try vm.bigIntValue(allocator, try dm.quotient.clone(allocator));
        },
        .decimal => {
            const ptr = v.decimal;
            // Truncate: divide unscaled by 10^scale
            if (ptr.scale == 0) {
                return try vm.bigIntValue(allocator, try ptr.unscaled.clone(allocator));
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
            return try vm.bigIntValue(allocator, try dm.quotient.clone(allocator));
        },
        else => return error.TypeError,
    };
}

pub fn core_bigdec(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    if (args.items.len != 1) return error.ArityError;
    const v = args.items[0];
    return switch (std.meta.activeTag(v)) {
        .decimal => try vm.shallowClone(&v, allocator),
        .integer => try vm.decimalValue(allocator, BD.BigDecimal.fromI64(allocator, v.integer, 0)),
        .float => {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v.float});
            defer allocator.free(s);
            return try vm.decimalValue(allocator, try BD.BigDecimal.fromString(allocator, s));
        },
        .bigint => {
            const ptr = v.bigint;
            const s = try ptr.toString(allocator);
            defer allocator.free(s);
            return try vm.decimalValue(allocator, try BD.BigDecimal.fromString(allocator, s));
        },
        .ratio => {
            const ptr = v.ratio;
            // Convert ratio to decimal: num / den
            const num_bd = try vm.decimalValue(allocator, try BD.BigDecimal.fromString(
                allocator, try ptr.num.toString(allocator)));
            const den_bd = try vm.decimalValue(allocator, try BD.BigDecimal.fromString(
                allocator, try ptr.den.toString(allocator)));
            const np = num_bd.decimal;
            const dp = den_bd.decimal;
            var n = try np.clone(allocator);
            var d = try dp.clone(allocator);
            defer { n.deinit(); d.deinit(); }
            var result = try BD.div(n, d);
            defer result.deinit();
            return try vm.decimalValue(allocator, result);
        },
        else => return error.TypeError,
    };
}

pub fn core_byte(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Coerce to integer first, then truncate to i8 range (wrapping)
    const v = args.items[0];
    const int_val = coerceToInt(v, env_env.allocator) orelse return error.TypeError;
    // Truncate: take lower 8 bits, interpret as signed
    const b8: u8 = @truncate(@as(u64, @intCast(int_val)));
    const signed_b8: i8 = @as(i8, @bitCast(b8));
    return vm.intValue(@as(i64, @intCast(signed_b8)));
}

pub fn core_short(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    // Coerce to integer first, then truncate to i16 range (wrapping)
    const v = args.items[0];
    const int_val = coerceToInt(v, env_env.allocator) orelse return error.TypeError;
    // Truncate: take lower 16 bits, interpret as signed
    const b16: u16 = @truncate(@as(u64, @intCast(int_val)));
    const signed_b16: i16 = @as(i16, @bitCast(b16));
    return vm.intValue(@as(i64, @intCast(signed_b16)));
}

/// Returns a keyword representing the runtime type of x.
/// Clojure: (type x)
/// E.g. (type "hello") => :string, (type 42) => :integer, (type nil) => :nil
pub fn core_type(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const type_name = switch (std.meta.activeTag(args.items[0])) {
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
        .future => "future",
        .promise => "promise",
        .function => "function",
        .builtin_fn => "builtin_fn",
        .lazy_seq => "lazy_seq",
        .cons => "cons",
        .chunk => "chunk",
        .chunked_cons => "chunked_cons",
        .reduced => "reduced",
        .wrapped => "wrapped",
        .record => args.items[0].record.type_name,
    };
    return try vm.keywordValue(env_env.allocator, type_name);
}

/// Returns the metadata of x, or nil if it has none.
/// For records, returns the record's meta map.
pub fn core_meta(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const allocator = env_env.allocator;
    const val = args.items[0];

    if (std.meta.activeTag(val) == .record) {
        if (val.record.meta) |m| {
            // Clone and return the meta map
            const cloned = try vm.cloneMap(allocator, m);
            return try vm.mapValue(allocator, cloned);
        }
        return vm.nilValue();
    }

    if (std.meta.activeTag(val) == .function) {
        const fn_data = val.function;
        // Check for cached metadata
        if (fn_data.cached_meta) |cached| {
            return cached;  // Share — metadata is immutable, GC keeps it alive
        }
        // Build and cache the metadata
        const meta_map = try buildFnMeta(allocator, fn_data);
        // Store in cache (fn_data is *FnData, mutable)
        fn_data.cached_meta = meta_map;
        // Return shared reference — metadata is immutable
        return meta_map;
    }

    // For other types, return nil
    return vm.nilValue();
}

/// Build metadata map for a function value: {:doc, :arglists, :name, :macro}
fn buildFnMeta(allocator: Allocator, fn_data: *const vm.FnData) anyerror!Value {
    var entries: vm.Map = .empty;
    errdefer {
        for (entries.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(entries.items);
    }

    // :doc
    if (fn_data.docstring) |doc| {
        const doc_key = try vm.keywordValue(allocator, "doc");
        const doc_val = try vm.stringValue(allocator, doc);
        try entries.append(allocator, .{ .key = doc_key, .value = doc_val });
    }

    // :arglists
    var arglists = try buildArglistsValue(allocator, fn_data);
    defer vm.valueDeinit(&arglists, allocator);
    const arglists_key = try vm.keywordValue(allocator, "arglists");
    const arglists_val = try vm.shallowClone(&arglists, allocator);
    try entries.append(allocator, .{ .key = arglists_key, .value = arglists_val });

    // :name
    if (fn_data.name) |name| {
        const name_key = try vm.keywordValue(allocator, "name");
        const name_val = try vm.symValue(allocator, name);
        try entries.append(allocator, .{ .key = name_key, .value = name_val });
    }

    // :macro
    const macro_key = try vm.keywordValue(allocator, "macro");
    const macro_val = vm.boolValue(fn_data.is_macro);
    try entries.append(allocator, .{ .key = macro_key, .value = macro_val });

    return try vm.mapValue(allocator, entries);
}

/// Build arglists value from FnData arities: ((a) (a b) (a b & rest))
fn buildArglistsValue(allocator: Allocator, fn_data: *const vm.FnData) anyerror!Value {
    var arglists: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (arglists.items) |*v| {
            vm.valueDeinit(v, allocator);
        }
        allocator.free(arglists.items);
    }

    for (fn_data.arities.items) |arity| {
        var param_list: std.ArrayListUnmanaged(Value) = .empty;
        errdefer {
            for (param_list.items) |*v| {
                vm.valueDeinit(v, allocator);
            }
            allocator.free(param_list.items);
        }

        for (arity.params.items) |param| {
            const cloned_param = try vm.shallowClone(&param, allocator);
            try param_list.append(allocator, cloned_param);
        }

        // Handle rest param: add '& rest_name'
        if (arity.rest_name) |rest_name| {
            const amp = try vm.symValue(allocator, "&");
            try param_list.append(allocator, amp);
            const rest_sym = try vm.symValue(allocator, rest_name);
            try param_list.append(allocator, rest_sym);
        }

        const arity_list = try vm.listValue(allocator, try list.clone(&param_list, allocator));
        try arglists.append(allocator, arity_list);
    }

    return try vm.listValue(allocator, arglists);
}

/// Returns a copy of x with metadata m attached.
/// For records, creates a new record with updated meta.
/// For other types, returns x unchanged (metadata not supported).
pub fn core_with_meta(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const allocator = env_env.allocator;
    const val = args.items[0];
    const new_meta = args.items[1];

    if (std.meta.activeTag(val) == .record) {
        const rd = val.record;
        const new_meta_map = if (std.meta.activeTag(new_meta) == .map)
            try vm.cloneMap(allocator, new_meta.map.entries)
        else
            null;
        errdefer {
            if (new_meta_map) |m| {
                for (m.items) |*entry| {
                    vm.valueDeinit(&entry.key, allocator);
                    vm.valueDeinit(&entry.value, allocator);
                }
                allocator.free(m.items);
            }
        }
        const cloned_fields = try vm.cloneMap(allocator, rd.fields);
        const cloned_extmap = try vm.cloneMap(allocator, rd.extmap);
        const cloned_type_name = try allocator.dupe(u8, rd.type_name);
        errdefer {
            for (cloned_fields.items) |*entry| {
                vm.valueDeinit(&entry.key, allocator);
                vm.valueDeinit(&entry.value, allocator);
            }
            allocator.free(cloned_fields.items);
            for (cloned_extmap.items) |*entry| {
                vm.valueDeinit(&entry.key, allocator);
                vm.valueDeinit(&entry.value, allocator);
            }
            allocator.free(cloned_extmap.items);
            allocator.free(cloned_type_name);
        }
        return try vm.recordValue(allocator, cloned_type_name, cloned_fields, cloned_extmap, new_meta_map);
    }
    // For other types, return a clone of the original value
    return try vm.shallowClone(&val, allocator);
}

pub fn registerTypePredicateFunctions(env: *Env) anyerror!void {
    try env.put("nil?", vm.builtinFnValue(core_nil_q));
    try env.put("number?", vm.builtinFnValue(core_number_q));
    try env.put("string?", vm.builtinFnValue(core_string_q));
    try env.put("regex?", vm.builtinFnValue(core_regex_q));
    try env.put("list?", vm.builtinFnValue(core_list_q));
    try env.put("symbol?", vm.builtinFnValue(core_symbol_q));
    try env.put("keyword?", vm.builtinFnValue(core_keyword_q));
    try env.put("true?", vm.builtinFnValue(core_true_q));
    try env.put("false?", vm.builtinFnValue(core_false_q));
    try env.put("fn?", vm.builtinFnValue(core_fn_q));
    try env.put("vector?", vm.builtinFnValue(core_vector_q));
    try env.put("map?", vm.builtinFnValue(core_map_q));
    try env.put("record?", vm.builtinFnValue(core_record_q));
    try env.put("queue?", vm.builtinFnValue(core_queue_q));
    try env.put("future?", vm.builtinFnValue(core_future_q));
    try env.put("promise?", vm.builtinFnValue(core_promise_q));
    try env.put("coll?", vm.builtinFnValue(core_coll_q));
    try env.put("sequential?", vm.builtinFnValue(core_sequential_q));
    try env.put("boolean?", vm.builtinFnValue(core_boolean_q));
    // Character type predicate and coercion
    try env.put("char?", vm.builtinFnValue(core_char_q));
    try env.put("char", vm.builtinFnValue(core_char));
    // Numeric type predicates
    try env.put("integer?", vm.builtinFnValue(core_integer_q));
    try env.put("int?", vm.builtinFnValue(core_int_q));
    try env.put("double?", vm.builtinFnValue(core_double_q));
    try env.put("float?", vm.builtinFnValue(core_float_q));
    try env.put("NaN?", vm.builtinFnValue(core_nan_q));
    try env.put("infinite?", vm.builtinFnValue(core_infinite_q));
    // Numeric coercion functions
    try env.put("int", vm.builtinFnValue(core_int));
    try env.put("float", vm.builtinFnValue(core_float));
    try env.put("double", vm.builtinFnValue(core_double));
    try env.put("bigint", vm.builtinFnValue(core_bigint));
    try env.put("bigdec", vm.builtinFnValue(core_bigdec));
    try env.put("byte", vm.builtinFnValue(core_byte));
    try env.put("short", vm.builtinFnValue(core_short));
    // Type constructors
    try env.put("keyword", vm.builtinFnValue(core_keyword));
    // Type introspection
    try env.put("type", vm.builtinFnValue(core_type));
    // Metadata
    try env.put("meta", vm.builtinFnValue(core_meta));
    try env.put("with-meta", vm.builtinFnValue(core_with_meta));
    // Chunked sequence predicate
    try env.put("chunked-seq?", vm.builtinFnValue(core_chunked_seq_q));
    try env.put("has-doc?", vm.builtinFnValue(core_has_doc_q));
    try env.put("get-doc", vm.builtinFnValue(core_get_doc));
}

// chunked-seq? - check if s is a chunked sequence
pub fn core_chunked_seq_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    return vm.boolValue(std.meta.activeTag(args.items[0]) == .chunked_cons);
}

// has-doc? - check if a function/macro has a docstring (no allocation)
pub fn core_has_doc_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const val = args.items[0];
    if (std.meta.activeTag(val) == .function) {
        return vm.boolValue(val.function.docstring != null);
    }
    return vm.boolValue(false);
}

// get-doc - return the docstring of a function/macro, or nil (minimal allocation)
pub fn core_get_doc(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const val = args.items[0];
    if (std.meta.activeTag(val) == .function) {
        if (val.function.docstring) |doc| {
            return try vm.stringValue(env_env.allocator, doc);
        }
    }
    return vm.nilValue();
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "type_predicates::nil_q: nil is nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue() });
    var result = core_nil_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::nil_q: int is not nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1) });
    var result = core_nil_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::number_q: integer is number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_number_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::number_q: float is number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(3.14) });
    var result = core_number_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::number_q: nil is not number" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue() });
    var result = core_number_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::true_q: true is true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.boolValue(true) });
    var result = core_true_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::true_q: false is not true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.boolValue(false) });
    var result = core_true_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::false_q: false is false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.boolValue(false) });
    var result = core_false_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::coll_q: list is coll" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ try vm.listValue(std.heap.page_allocator, list.empty()) });
    var result = core_coll_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::coll_q: nil is not coll" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue() });
    var result = core_coll_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::sequential_q: list is sequential" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ try vm.listValue(std.heap.page_allocator, list.empty()) });
    var result = core_sequential_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::sequential_q: set is not sequential" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ try vm.setValue(std.heap.page_allocator, .empty) });
    var result = core_sequential_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

// Numeric type predicate tests

test "type_predicates::integer_q: int is integer" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_integer_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::integer_q: float is not integer" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.5) });
    var result = core_integer_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::int_q: int is int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_int_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::double_q: float is double" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.5) });
    var result = core_double_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::double_q: int is not double" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_double_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::float_q: float is float" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.5) });
    var result = core_float_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::nan_q: nan is nan" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(std.math.nan(f64)) });
    var result = core_nan_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::nan_q: normal float is not nan" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.5) });
    var result = core_nan_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::nan_q: int is not nan" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_nan_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::infinite_q: positive infinity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(std.math.inf(f64)) });
    var result = core_infinite_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::infinite_q: negative infinity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(-std.math.inf(f64)) });
    var result = core_infinite_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::infinite_q: normal float is not infinite" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(1.5) });
    var result = core_infinite_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

// Numeric coercion tests

test "type_predicates::core_int: float to int" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(3.7) });
    var result = core_int(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 3);
}

test "type_predicates::core_int: float to int negative" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(-3.7) });
    var result = core_int(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == -3);
}

test "type_predicates::core_float: int to float" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_float(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .float);
    try std.testing.expect(result.float == 42.0);
}

test "type_predicates::core_byte: in range" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(127) });
    var result = core_byte(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 127);
}

test "type_predicates::core_byte: overflow wraps" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(256) });
    var result = core_byte(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == 0);
}

test "type_predicates::core_byte: 128 wraps to -128" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(128) });
    var result = core_byte(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == -128);
}

test "type_predicates::core_short: overflow wraps" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(32768) });
    var result = core_short(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.integer == -32768);
}

test "type_predicates::core_bigint: int to bigint" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_bigint(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .bigint);
}

test "type_predicates::core_bigdec: int to bigdec" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_bigdec(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .decimal);
}

test "type_predicates::core_int: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_int(testSelf(), &args, &a));
}

test "type_predicates::core_integer_q: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_integer_q(testSelf(), &args, &a));
}

// Character type tests

test "type_predicates::char_q: char is char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.charValue(65) });
    var result = core_char_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "type_predicates::char_q: int is not char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(65) });
    var result = core_char_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::char_q: string is not char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "A");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_char_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "type_predicates::char: int to char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(65) });
    var result = core_char(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .character);
    try std.testing.expect(result.character == 65);
}

test "type_predicates::char: char identity" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.charValue(65) });
    var result = core_char(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .character);
    try std.testing.expect(result.character == 65);
}

test "type_predicates::char: float to char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.floatValue(97.9) });
    var result = core_char(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .character);
    try std.testing.expect(result.character == 97);
}

test "type_predicates::char: negative int error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(-1) });
    try std.testing.expectError(error.NegativeCharacter, core_char(testSelf(), &args, &a));
}

test "type_predicates::char: out of range error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(0x110000) });
    try std.testing.expectError(error.CharacterOutOfRange, core_char(testSelf(), &args, &a));
}

test "type_predicates::char: string to char" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "A");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    const result = core_char(testSelf(), &args, &a) catch unreachable;
    try std.testing.expect(std.meta.activeTag(result) == .character);
    try std.testing.expect(result.character == 'A');
}

test "type_predicates::char: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_char(testSelf(), &args, &a));
}

test "type_predicates::char_q: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_char_q(testSelf(), &args, &a));
}

test "type_predicates::type: returns :string for string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.stringValue(std.heap.page_allocator, "hello") catch unreachable });
    var result = core_type(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.keyword, "string"));
}

test "type_predicates::type: returns :integer for integer" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_type(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.keyword, "integer"));
}

test "type_predicates::type: returns :nil for nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue() });
    var result = core_type(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.keyword, "nil"));
}

test "type_predicates::type: returns :bool for true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.boolValue(true) });
    var result = core_type(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.keyword, "bool"));
}

test "type_predicates::type: returns :map for map" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var m: vm.Map = .empty;
    const alloc = std.heap.page_allocator;
    try m.append(alloc, .{ .key = vm.keywordValue(alloc, "a") catch unreachable, .value = vm.intValue(1) });
    const map_val = try vm.mapValue(alloc, m);
    const args = makeArgs(&[_]Value{ map_val });
    var result = core_type(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .keyword);
    try std.testing.expect(std.mem.eql(u8, result.keyword, "map"));
}

test "type_predicates::type: arity error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    try std.testing.expectError(error.ArityError, core_type(testSelf(), &args, &a));
}

