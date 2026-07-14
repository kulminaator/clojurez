// VM operation helpers: compareOp, arithmeticOp, vmFirst, vmRest, vmCount,
// vmGet, vmAssoc, vmConj, vmNth, vmSeq, vmDeref, vmMakeFn, resolveSymbol.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const eval_mod = @import("../eval.zig");
const phm = @import("../persistent_hash_map.zig");
const BI = @import("../big_int.zig");
const RatioMod = @import("../ratio.zig");
const BD = @import("../big_decimal.zig");
const arithmetic = @import("../namespaces/core/arithmetic.zig");
const helpers = @import("../namespaces/core/helpers.zig");
const sequences = @import("../namespaces/core/sequences.zig");
const chunks = @import("../namespaces/core/chunks.zig");
const bc = @import("instructions.zig");
const vmt = @import("vm_types.zig");

const Allocator = std.mem.Allocator;

// Re-export types used by these functions
pub const OpCode = bc.OpCode;
pub const FnMetadata = vmt.FnMetadata;
pub const StackEntry = vmt.StackEntry;

/// Resolve a symbol name in the environment, handling qualified symbols.
/// Qualified symbols like "zig.core/+" are split on "/" and resolved
/// through the namespace manager, matching the AST evaluator's behavior.
pub fn resolveSymbol(env: *vm.Env, sym_name: []const u8) anyerror!Value {
    // Check for qualified symbol: alias/name or namespace/name
    if (std.mem.indexOfScalar(u8, sym_name, '/')) |slash_idx| {
        const alias = sym_name[0..slash_idx];
        const name = sym_name[slash_idx + 1 ..];

        // Try to resolve through namespace manager
        const ns_mgr = eval_mod.findNsManager(env) orelse {
            // No namespace manager — fall back to simple lookup
            const val = env.get(sym_name);
            if (val) |v| return v;
            std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
            return error.UndefinedSymbol;
        };

        // Resolve alias to namespace name
        const current_ns = ns_mgr.getCurrentNamespace();
        const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;

        // Get target namespace's env
        const target_env = ns_mgr.getNamespace(target_ns) orelse {
            // Target namespace doesn't exist — fall back to simple lookup
            const val = env.get(sym_name);
            if (val) |v| return v;
            std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
            return error.UndefinedSymbol;
        };

        // Look up name in target namespace
        const val = target_env.get(name);
        if (val) |v| return v;
        std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
        return error.UndefinedSymbol;
    }

    // Unqualified symbol — simple environment lookup (traverses parent chain)
    const val = env.get(sym_name);
    if (val) |v| return v;
    std.debug.print("Undefined symbol: '{s}'\n", .{sym_name});
    return error.UndefinedSymbol;
}

/// Perform a comparison operation.
/// For = and !=, uses vm.compare (handles nil properly).
/// For <, >, <=, >=, uses toNum conversion to match core_less etc.
pub fn compareOp(op: OpCode, a: Value, b: Value) anyerror!Value {
    return switch (op) {
        .eq => vm.boolValue(vm.compare(a, b) == 0),
        .ne => vm.boolValue(vm.compare(a, b) != 0),
        .lt => {
            const an = helpers.toNum(a);
            const bn = helpers.toNum(b);
            return vm.boolValue(an < bn);
        },
        .gt => {
            const an = helpers.toNum(a);
            const bn = helpers.toNum(b);
            return vm.boolValue(an > bn);
        },
        .le => {
            const an = helpers.toNum(a);
            const bn = helpers.toNum(b);
            return vm.boolValue(an <= bn);
        },
        .ge => {
            const an = helpers.toNum(a);
            const bn = helpers.toNum(b);
            return vm.boolValue(an >= bn);
        },
        .compare => vm.intValue(vm.compare(a, b)),
        else => unreachable,
    };
}

/// Perform an arithmetic operation.
/// For integer/float operands, computes directly.
/// For bigint/ratio/decimal, delegates to the corresponding zig.core builtin.
pub fn arithmeticOp(op: OpCode, a: Value, b: Value, allocator: Allocator, env: *vm.Env) anyerror!Value {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);

    // Delegate to zig.core builtin for non-integer/float types
    if (needsDelegation(a_tag) or needsDelegation(b_tag)) {
        return delegateArithmetic(op, a, b, allocator, env);
    }

    // Fast path: integer and float arithmetic
    if (a_tag == .float or b_tag == .float) {
        const af: f64 = switch (a_tag) {
            .float => a.float,
            .integer => @as(f64, @floatFromInt(a.integer)),
            else => unreachable,
        };
        const bf: f64 = switch (b_tag) {
            .float => b.float,
            .integer => @as(f64, @floatFromInt(b.integer)),
            else => unreachable,
        };
        return switch (op) {
            .add => vm.floatValue(af + bf),
            .sub => vm.floatValue(af - bf),
            .mul => vm.floatValue(af * bf),
            .div => if (bf == 0) error.DivisionByZero else vm.floatValue(af / bf),
            .rem => if (bf == 0) error.DivisionByZero else vm.floatValue(@rem(af, bf)),
            else => unreachable,
        };
    }

    // Both integers
    const ai = a.integer;
    const bi = b.integer;
    return switch (op) {
        .add => vm.intValue(ai + bi),
        .sub => vm.intValue(ai - bi),
        .mul => vm.intValue(ai * bi),
        .div => if (bi == 0) error.DivisionByZero else vm.intValue(@divTrunc(ai, bi)),
        .rem => if (bi == 0) error.DivisionByZero else vm.intValue(ai - @divTrunc(ai, bi) * bi),
        else => unreachable,
    };
}

/// Check if a value type needs delegation to zig.core builtins.
fn needsDelegation(tag: std.meta.Tag(Value)) bool {
    return switch (tag) {
        .bigint, .ratio, .decimal => true,
        else => false,
    };
}

/// Delegate arithmetic to the corresponding zig.core builtin.
/// Looks up the builtin (e.g., "+", "-", "*", "/", "rem") and calls it
/// with the two operands as arguments.
fn delegateArithmetic(op: OpCode, a: Value, b: Value, allocator: Allocator, env: *vm.Env) anyerror!Value {
    const op_name = switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "rem",
        else => unreachable,
    };

    // Look up the zig.core builtin in the environment
    const fn_val = try resolveSymbol(env, op_name);

    // Build args list: [a, b]
    var args: list.List = .empty;
    errdefer args.deinit(allocator);
    try args.append(allocator, try vm.shallowClone(&a, allocator));
    try args.append(allocator, try vm.shallowClone(&b, allocator));

    // Call the builtin
    const call_result = try eval_mod.callWithEnv(allocator, &fn_val, &args, env, 0);

    switch (call_result) {
        .value => |v| return try vm.shallowClone(&v, allocator),
        .trampoline => return error.NotImplemented,
    }
}

/// Perform negation on a numeric value, supporting the full numeric tower.
pub fn negateOp(val: Value, allocator: Allocator) anyerror!Value {
    return switch (val) {
        .integer => |v| vm.intValue(-v),
        .float => |v| vm.floatValue(-v),
        .bigint => {
            var cloned = try val.bigint.clone(allocator);
            defer cloned.deinit();
            cloned.negate();
            const negated = try cloned.clone(allocator);
            return try vm.bigIntValue(allocator, negated);
        },
        .ratio => {
            var cloned = try val.ratio.clone(allocator);
            defer cloned.deinit();
            const negated = RatioMod.negate(cloned);
            return try vm.ratioValue(allocator, negated);
        },
        .decimal => {
            var cloned = try val.decimal.clone(allocator);
            defer cloned.deinit();
            const negated = BD.negate(cloned);
            return try vm.decimalValue(allocator, negated);
        },
        else => return error.TypeError,
    };
}

/// VM implementation of (first coll) — returns first element or nil.
pub fn vmFirst(allocator: Allocator, val: Value) anyerror!Value {
    var v = val;
    while (std.meta.activeTag(v) == .lazy_seq) {
        const result = try sequences.forceLazySeqGetResult(allocator, &v);
        vm.valueDeinit(&v, allocator);
        v = result;
    }
    switch (v) {
        .list => {
            if (v.list.items.items.len == 0) return vm.nilValue();
            return try vm.shallowClone(&v.list.items.items[0], allocator);
        },
        .vector => {
            if (v.vector.items.items.len == 0) return vm.nilValue();
            return try vm.shallowClone(&v.vector.items.items[0], allocator);
        },
        .cons => return try vm.shallowClone(&v.cons.head, allocator),
        .chunked_cons => {
            const ccd = v.chunked_cons;
            return ccd.chunk.items[ccd.chunk.off];
        },
        .string => {
            const s = v.string;
            if (s.len == 0) return vm.nilValue();
            const cp_bytes = vm.utf8CodepointAt(s, 0) orelse return vm.nilValue();
            const cp = std.unicode.utf8Decode(cp_bytes) catch return vm.nilValue();
            return vm.charValue(cp);
        },
        else => return vm.nilValue(),
    }
}

/// VM implementation of (rest coll) — returns all but first element.
pub fn vmRest(allocator: Allocator, val: Value) anyerror!Value {
    var v = val;
    while (std.meta.activeTag(v) == .lazy_seq) {
        const result = try sequences.forceLazySeqGetResult(allocator, &v);
        vm.valueDeinit(&v, allocator);
        v = result;
    }
    switch (v) {
        .list => {
            if (v.list.items.items.len <= 1) return try vm.listValue(allocator, list.empty());
            var rest_list: list.List = .empty;
            errdefer rest_list.deinit(allocator);
            for (v.list.items.items[1..]) |item| {
                try rest_list.append(allocator, try vm.shallowClone(&item, allocator));
            }
            return try vm.listValue(allocator, rest_list);
        },
        .vector => {
            if (v.vector.items.items.len <= 1) return try vm.listValue(allocator, list.empty());
            var rest_list: list.List = .empty;
            errdefer rest_list.deinit(allocator);
            for (v.vector.items.items[1..]) |item| {
                try rest_list.append(allocator, try vm.shallowClone(&item, allocator));
            }
            return try vm.listValue(allocator, rest_list);
        },
        .cons => return try vm.shallowClone(&v.cons.tail, allocator),
        .chunked_cons => {
            const ccd = v.chunked_cons;
            const chunk = ccd.chunk;
            const tail = ccd.tail;
            if (chunk.off + 1 < chunk.end) {
                const dropped = chunk.dropFirst();
                const new_chunk = try vm.chunkValue(
                    allocator, dropped.items, dropped.off, dropped.end, false);
                return chunks.chunkedCons(allocator, new_chunk, tail);
            }
            return try vmSeq(allocator, tail);
        },
        .string => {
            const s = v.string;
            const codepoint_count = vm.utf8CodepointCount(s);
            if (codepoint_count <= 1) return try vm.listValue(allocator, list.empty());
            var result: list.List = .empty;
            errdefer result.deinit(allocator);
            var idx: usize = 1;
            while (idx < codepoint_count) : (idx += 1) {
                const cp_bytes = vm.utf8CodepointAt(s, idx) orelse break;
                const cp = std.unicode.utf8Decode(cp_bytes) catch break;
                try result.append(allocator, vm.charValue(cp));
            }
            return try vm.listValue(allocator, result);
        },
        else => return try vm.listValue(allocator, list.empty()),
    }
}

/// VM implementation of (count coll) — returns element count as integer.
pub fn vmCount(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .list => return vm.intValue(@as(i64, @intCast(val.list.items.items.len))),
        .vector => return vm.intValue(@as(i64, @intCast(val.vector.items.items.len))),
        .map => return vm.intValue(@as(i64, @intCast(val.map.entries.items.len))),
        .set => return vm.intValue(@as(i64, @intCast(val.set.items.items.len))),
        .queue => return vm.intValue(@as(i64, @intCast(val.queue.items.items.len))),
        .string => return vm.intValue(@as(i64, @intCast(vm.utf8CodepointCount(val.string)))),
        .cons => {
            var count: i64 = 0;
            var current = try vm.shallowClone(&val, allocator);
            errdefer vm.valueDeinit(&current, allocator);
            while (true) {
                switch (current) {
                    .cons => {
                        count += 1;
                        const tail = try vm.shallowClone(&current.cons.tail, allocator);
                        vm.valueDeinit(&current, allocator);
                        current = tail;
                    },
                    .nil => break,
                    .list => {
                        count += @as(i64, @intCast(current.list.items.items.len));
                        break;
                    },
                    else => {
                        count += 1;
                        break;
                    },
                }
            }
            return vm.intValue(count);
        },
        .record => {
            const rd = val.record;
            const total: i64 = @as(i64, @intCast(rd.fields.items.len)) + @as(i64, @intCast(rd.extmap.items.len));
            return vm.intValue(total);
        },
        else => return error.TypeError,
    }
}

/// VM implementation of (empty? coll) — returns true if collection is empty.
/// Matches core_empty_q behavior: checks list, vector, map, set, queue, string.
pub fn vmIsEmpty(allocator: Allocator, val: Value) anyerror!Value {
    _ = allocator;
    const len: usize = switch (std.meta.activeTag(val)) {
        .list => val.list.items.items.len,
        .vector => val.vector.items.items.len,
        .map => val.map.entries.items.len,
        .set => val.set.items.items.len,
        .queue => val.queue.items.items.len,
        .string => val.string.len,
        else => return error.TypeError,
    };
    return vm.boolValue(len == 0);
}

/// VM implementation of (not-empty coll) — returns coll if not empty, nil otherwise.
/// Matches core_not_empty behavior.
pub fn vmIsNotEmpty(allocator: Allocator, val: Value) anyerror!Value {
    const len: usize = switch (std.meta.activeTag(val)) {
        .list => val.list.items.items.len,
        .vector => val.vector.items.items.len,
        .map => val.map.entries.items.len,
        .set => val.set.items.items.len,
        .queue => val.queue.items.items.len,
        else => return vm.nilValue(),
    };
    if (len == 0) return vm.nilValue();
    return try vm.shallowClone(&val, allocator);
}

/// VM implementation of (empty coll) — returns empty collection of same type.
pub fn vmMakeEmpty(allocator: Allocator, val: Value) anyerror!Value {
    return switch (std.meta.activeTag(val)) {
        .list => vm.listValue(allocator, list.empty()),
        .vector => vm.vectorValue(allocator, vec.empty()),
        .map => vm.mapValue(allocator, .empty),
        .set => vm.setValue(allocator, .empty),
        .queue => vm.queueValue(allocator, .empty),
        else => vm.nilValue(),
    };
}

/// VM implementation of (get map key) — returns value or nil.
pub fn vmGet(allocator: Allocator, coll: Value, key: Value) anyerror!Value {
    switch (coll) {
        .map => {
            for (coll.map.entries.items) |entry| {
                if (vm.equals(entry.key, key)) return try vm.shallowClone(&entry.value, allocator);
            }
            return vm.nilValue();
        },
        .set => {
            for (coll.set.items.items) |item| {
                if (vm.equals(item, key)) return try vm.shallowClone(&item, allocator);
            }
            return vm.nilValue();
        },
        .record => {
            for (coll.record.fields.items) |entry| {
                if (vm.equals(entry.key, key)) return try vm.shallowClone(&entry.value, allocator);
            }
            for (coll.record.extmap.items) |entry| {
                if (vm.equals(entry.key, key)) return try vm.shallowClone(&entry.value, allocator);
            }
            return vm.nilValue();
        },
        else => return vm.nilValue(),
    }
}

/// VM implementation of (assoc map key val) — returns new map.
pub fn vmAssoc(allocator: Allocator, map_val: Value, key: Value, val: Value) anyerror!Value {
    if (std.meta.activeTag(map_val) != .map) return error.TypeError;
    var new_map: vm.Map = .empty;
    errdefer {
        for (new_map.items) |*entry| {
            vm.valueDeinit(&entry.key, allocator);
            vm.valueDeinit(&entry.value, allocator);
        }
        allocator.free(new_map.items);
    }
    try new_map.ensureTotalCapacity(allocator, map_val.map.entries.items.len + 1);
    for (map_val.map.entries.items) |entry| {
        if (vm.equals(entry.key, key)) {
            try new_map.append(allocator, .{
                .key = try vm.shallowClone(&entry.key, allocator),
                .value = try vm.shallowClone(&val, allocator),
            });
        } else {
            try new_map.append(allocator, .{
                .key = try vm.shallowClone(&entry.key, allocator),
                .value = try vm.shallowClone(&entry.value, allocator),
            });
        }
    }
    if (new_map.items.len == map_val.map.entries.items.len) {
        try new_map.append(allocator, .{
            .key = try vm.shallowClone(&key, allocator),
            .value = try vm.shallowClone(&val, allocator),
        });
    }
    return try vm.mapValue(allocator, new_map);
}

/// VM implementation of (conj coll item) — returns new collection.
pub fn vmConj(allocator: Allocator, coll: Value, item: Value) anyerror!Value {
    switch (coll) {
        .list => {
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            try new_list.append(allocator, try vm.shallowClone(&item, allocator));
            for (coll.list.items.items) |e| {
                try new_list.append(allocator, try vm.shallowClone(&e, allocator));
            }
            return try vm.listValue(allocator, new_list);
        },
        .vector => {
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            for (coll.vector.items.items) |e| {
                try new_vec.append(allocator, try vm.shallowClone(&e, allocator));
            }
            try new_vec.append(allocator, try vm.shallowClone(&item, allocator));
            return try vm.vectorValue(allocator, new_vec);
        },
        .map => {
            if (std.meta.activeTag(item) == .list or std.meta.activeTag(item) == .vector) {
                const items = switch (item) {
                    .list => item.list.items.items,
                    .vector => item.vector.items.items,
                    else => unreachable,
                };
                if (items.len != 2) return error.ArityError;
                return try vmAssoc(allocator, coll, items[0], items[1]);
            }
            return error.TypeError;
        },
        .set => {
            var new_set: vm.Set = .empty;
            errdefer {
                for (new_set.items) |*s| vm.valueDeinit(s, allocator);
                allocator.free(new_set.items);
            }
            for (coll.set.items.items) |e| {
                try new_set.append(allocator, try vm.shallowClone(&e, allocator));
            }
            var found = false;
            for (coll.set.items.items) |e| {
                if (vm.equals(e, item)) { found = true; break; }
            }
            if (!found) try new_set.append(allocator, try vm.shallowClone(&item, allocator));
            return try vm.setValue(allocator, new_set);
        },
        else => return error.TypeError,
    }
}

/// VM implementation of (nth coll index) — returns element at index.
pub fn vmNth(allocator: Allocator, coll: Value, idx_val: Value) anyerror!Value {
    const idx: usize = switch (idx_val) {
        .integer => |i| blk: {
            if (i < 0) return error.IndexOutOfBounds;
            break :blk @as(usize, @intCast(i));
        },
        else => return error.TypeError,
    };
    switch (coll) {
        .list => {
            if (idx >= coll.list.items.items.len) return error.IndexOutOfBounds;
            return try vm.shallowClone(&coll.list.items.items[idx], allocator);
        },
        .vector => {
            if (idx >= coll.vector.items.items.len) return error.IndexOutOfBounds;
            return try vm.shallowClone(&coll.vector.items.items[idx], allocator);
        },
        .string => {
            const cp_bytes = vm.utf8CodepointAt(coll.string, idx) orelse return error.IndexOutOfBounds;
            const cp = std.unicode.utf8Decode(cp_bytes) catch return error.TypeError;
            return vm.charValue(cp);
        },
        .queue => {
            if (idx >= coll.queue.items.items.len) return error.IndexOutOfBounds;
            return try vm.shallowClone(&coll.queue.items.items[idx], allocator);
        },
        else => return error.TypeError,
    }
}

/// Perform a type check on a value. Returns true/false based on opcode.
/// Each opcode checks for a specific type or set of types.
pub fn vmTypeCheck(op: OpCode, val: Value) Value {
    const tag = std.meta.activeTag(val);
    return switch (op) {
        .is_number => vm.boolValue(
            tag == .integer or tag == .float or tag == .bigint or tag == .ratio or tag == .decimal,
        ),
        .is_int => vm.boolValue(tag == .integer),
        .is_float => vm.boolValue(tag == .float),
        .is_string => vm.boolValue(tag == .string),
        .is_boolean => vm.boolValue(tag == .bool),
        .is_list => vm.boolValue(tag == .list),
        .is_vector => vm.boolValue(tag == .vector),
        .is_map => vm.boolValue(tag == .map or tag == .record),
        .is_set => vm.boolValue(tag == .set),
        .is_symbol => vm.boolValue(tag == .symbol),
        .is_keyword => vm.boolValue(tag == .keyword),
        else => unreachable,
    };
}

/// VM implementation of (seq coll) — returns seq or nil.
pub fn vmSeq(allocator: Allocator, val: Value) anyerror!Value {
    // Force lazy sequences before processing
    var v = val;
    while (std.meta.activeTag(v) == .lazy_seq) {
        const result = try sequences.forceLazySeqGetResult(allocator, &v);
        vm.valueDeinit(&v, allocator);
        v = result;
    }
    switch (v) {
        .nil => return vm.nilValue(),
        .list => {
            if (v.list.items.items.len == 0) return vm.nilValue();
            return try vm.shallowClone(&v, allocator);
        },
        .vector => {
            if (v.vector.items.items.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            for (v.vector.items.items) |item| {
                try l.append(allocator, try vm.shallowClone(&item, allocator));
            }
            return try vm.listValue(allocator, l);
        },
        .map => {
            if (v.map.entries.items.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            for (v.map.entries.items) |entry| {
                var pair: list.List = .empty;
                try pair.append(allocator, try vm.shallowClone(&entry.key, allocator));
                try pair.append(allocator, try vm.shallowClone(&entry.value, allocator));
                try l.append(allocator, try vm.listValue(allocator, pair));
            }
            return try vm.listValue(allocator, l);
        },
        .set => {
            if (v.set.items.items.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            for (v.set.items.items) |item| {
                try l.append(allocator, try vm.shallowClone(&item, allocator));
            }
            return try vm.listValue(allocator, l);
        },
        .string => {
            if (v.string.len == 0) return vm.nilValue();
            var l: list.List = .empty;
            errdefer l.deinit(allocator);
            var i: usize = 0;
            while (i < v.string.len) {
                const cp_len = std.unicode.utf8ByteSequenceLength(v.string[i]) catch break;
                const cp_bytes = v.string[i .. i + cp_len];
                const cp = std.unicode.utf8Decode(cp_bytes) catch break;
                try l.append(allocator, vm.charValue(cp));
                i += cp_len;
            }
            return try vm.listValue(allocator, l);
        },
        .cons => return try vm.shallowClone(&v, allocator),
        else => return error.TypeError,
    }
}

/// VM implementation of deref — handles atom, reduced, future, promise.
pub fn vmDeref(allocator: Allocator, val: Value) anyerror!Value {
    switch (val) {
        .atom => |data| return try vm.shallowClone(&data.value, allocator),
        .reduced => |data| return try vm.shallowClone(data, allocator),
        .future => {
            const data = val.future;
            while (data.state.load(.monotonic) == 0) {
                const io = std.Io.Threaded.global_single_threaded.io();
                const duration = std.Io.Duration.fromMilliseconds(1);
                std.Io.sleep(io, duration, std.Io.Clock.awake) catch {};
            }
            if (data.state.load(.monotonic) == 1) {
                if (data.result) |r| return try vm.shallowClone(&r, allocator);
            }
            return vm.nilValue();
        },
        .promise => {
            const data = val.promise;
            while (data.state.load(.monotonic) == 0) {
                const io = std.Io.Threaded.global_single_threaded.io();
                const duration = std.Io.Duration.fromMilliseconds(1);
                std.Io.sleep(io, duration, std.Io.Clock.awake) catch {};
            }
            if (data.value) |*v| return try vm.shallowClone(v, allocator);
            return vm.nilValue();
        },
        else => return error.TypeError,
    }
}

/// VM implementation of (contains? coll key) — checks if collection contains key.
/// Matches core_contains_q behavior.
pub fn vmContains(allocator: Allocator, coll: Value, key: Value) anyerror!Value {
    _ = allocator;
    switch (std.meta.activeTag(coll)) {
        .map => {
            for (coll.map.entries.items) |entry| {
                if (vm.equals(entry.key, key)) return vm.boolValue(true);
            }
            return vm.boolValue(false);
        },
        .record => {
            for (coll.record.fields.items) |entry| {
                if (vm.equals(entry.key, key)) return vm.boolValue(true);
            }
            for (coll.record.extmap.items) |entry| {
                if (vm.equals(entry.key, key)) return vm.boolValue(true);
            }
            return vm.boolValue(false);
        },
        .set => {
            for (coll.set.items.items) |item| {
                if (vm.equals(item, key)) return vm.boolValue(true);
            }
            return vm.boolValue(false);
        },
        .vector, .list => {
            if (std.meta.activeTag(key) != .integer) return vm.boolValue(false);
            const idx = key.integer;
            if (idx < 0) return vm.boolValue(false);
            const len: usize = switch (std.meta.activeTag(coll)) {
                .vector => coll.vector.items.items.len,
                .list => coll.list.items.items.len,
                else => unreachable,
            };
            return vm.boolValue(@as(usize, @intCast(idx)) < len);
        },
        else => return error.TypeError,
    }
}

/// VM implementation of (str arg1 arg2 ...) — concatenates args to string.
/// Matches core_str behavior: nil is skipped, other types use fmtToBuffer.
pub fn vmStrN(allocator: Allocator, values: []const Value) anyerror!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (values) |arg| {
        // nil is skipped (not converted to "nil")
        if (std.meta.activeTag(arg) == .nil) continue;
        // Handle character type: convert code point to UTF-8 string
        if (std.meta.activeTag(arg) == .character) {
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(arg.character, &utf8_buf) catch return error.InvalidUnicode;
            try buf.appendSlice(allocator, utf8_buf[0..utf8_len]);
            continue;
        }
        // Handle string type: append directly
        if (std.meta.activeTag(arg) == .string) {
            try buf.appendSlice(allocator, arg.string);
            continue;
        }
        // All other types: use fmtToBuffer
        try vm.fmtToBuffer(arg, &buf, allocator);
    }
    return vm.stringValue(allocator, try buf.toOwnedSlice(allocator));
}

/// VM implementation of (peek coll) — returns last element or nil.
/// Matches core_peek behavior: queue returns first, vector/list returns last.
pub fn vmPeek(allocator: Allocator, val: Value) anyerror!Value {
    return switch (std.meta.activeTag(val)) {
        .queue => {
            if (val.queue.items.items.len == 0) return vm.nilValue();
            return try vm.shallowClone(&val.queue.items.items[0], allocator);
        },
        .vector => {
            if (val.vector.items.items.len == 0) return vm.nilValue();
            return try vm.shallowClone(&val.vector.items.items[val.vector.items.items.len - 1], allocator);
        },
        .list => {
            if (val.list.items.items.len == 0) return vm.nilValue();
            return try vm.shallowClone(&val.list.items.items[val.list.items.items.len - 1], allocator);
        },
        else => return error.TypeError,
    };
}

/// VM implementation of (pop coll) — returns collection without last element.
/// Matches core_pop behavior: vector/list removes last, queue removes first.
pub fn vmPop(allocator: Allocator, val: Value) anyerror!Value {
    return switch (std.meta.activeTag(val)) {
        .vector => {
            if (val.vector.items.items.len == 0) return try vm.vectorValue(allocator, vec.empty());
            var new_vec: vec.Vector = .empty;
            errdefer new_vec.deinit(allocator);
            const len = val.vector.items.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_vec.append(allocator, val.vector.items.items[i]);
            }
            return try vm.vectorValue(allocator, new_vec);
        },
        .list => {
            if (val.list.items.items.len == 0) return try vm.listValue(allocator, list.empty());
            var new_list: list.List = .empty;
            errdefer new_list.deinit(allocator);
            const len = val.list.items.items.len - 1;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                try new_list.append(allocator, val.list.items.items[i]);
            }
            return try vm.listValue(allocator, new_list);
        },
        .queue => {
            if (val.queue.items.items.len == 0) return try vm.queueValue(allocator, .empty);
            var new_queue: vm.Queue = .empty;
            errdefer {
                for (new_queue.items) |*item| {
                    vm.valueDeinit(item, allocator);
                }
                allocator.free(new_queue.items);
            }
            var i: usize = 1;
            while (i < val.queue.items.items.len) : (i += 1) {
                try new_queue.append(allocator, val.queue.items.items[i]);
            }
            return try vm.queueValue(allocator, new_queue);
        },
        else => return error.TypeError,
    };
}

/// VM implementation of (make-reduced val) — wraps value in reduced wrapper.
pub fn vmMakeReduced(allocator: Allocator, val: Value) anyerror!Value {
    return vm.reducedValue(allocator, try vm.shallowClone(&val, allocator));
}

/// VM implementation of (is-reduced val) — checks if value is a reduced wrapper.
pub fn vmIsReduced(allocator: Allocator, val: Value) anyerror!Value {
    _ = allocator;
    return vm.boolValue(std.meta.activeTag(val) == .reduced);
}

/// VM implementation of (unreduced val) — unwraps reduced or returns as-is.
pub fn vmUnreduced(allocator: Allocator, val: Value) anyerror!Value {
    if (std.meta.activeTag(val) == .reduced) {
        const data = val.reduced;
        return try vm.shallowClone(data, allocator);
    }
    return try vm.shallowClone(&val, allocator);
}

/// VM implementation of (get-meta val) — returns metadata map or nil.
/// Handles common cases: functions (cached_meta), records (meta field).
/// For symbols/keywords, returns nil (full namespace lookup requires AST evaluator).
pub fn vmGetMeta(allocator: Allocator, val: Value) anyerror!Value {
    return switch (std.meta.activeTag(val)) {
        .function => {
            const fn_data = val.function;
            if (fn_data.cached_meta) |cached| {
                return cached;
            }
            // Build metadata from function data
            var meta_map: vm.Map = .empty;
            errdefer { for (meta_map.items) |*e| { vm.valueDeinit(&e.key, allocator); vm.valueDeinit(&e.value, allocator); } allocator.free(meta_map.items); }
            if (fn_data.name) |name| {
                const key = try vm.keywordValue(allocator, "name");
                const v = try vm.symValue(allocator, name);
                try meta_map.append(allocator, .{ .key = key, .value = v });
            }
            if (fn_data.is_macro) {
                const key = try vm.keywordValue(allocator, "macro");
                try meta_map.append(allocator, .{ .key = key, .value = vm.boolValue(true) });
            }
            if (fn_data.docstring) |doc| {
                const key = try vm.keywordValue(allocator, "doc");
                const v = try vm.stringValue(allocator, doc);
                try meta_map.append(allocator, .{ .key = key, .value = v });
            }
            if (fn_data.namespace) |ns| {
                const key = try vm.keywordValue(allocator, "ns");
                const v = try vm.symValue(allocator, ns);
                try meta_map.append(allocator, .{ .key = key, .value = v });
            }
            if (meta_map.items.len > 0) {
                return try vm.mapValue(allocator, meta_map);
            }
            return vm.nilValue();
        },
        .record => {
            if (val.record.meta) |m| {
                const cloned = try vm.cloneMap(allocator, m);
                return try vm.mapValue(allocator, cloned);
            }
            return vm.nilValue();
        },
        else => return vm.nilValue(),
    };
}

/// VM implementation of (set-meta val meta) — returns new value with metadata.
/// For records, creates a new record with the meta. For other types, returns clone.
pub fn vmSetMeta(allocator: Allocator, val: Value, meta: Value) anyerror!Value {
    if (std.meta.activeTag(meta) == .nil) return try vm.shallowClone(&val, allocator);
    if (std.meta.activeTag(meta) != .map) return error.TypeError;

    return switch (std.meta.activeTag(val)) {
        .record => {
            const rd = val.record;
            const new_meta_map = try vm.cloneMap(allocator, meta.map.entries);
            errdefer {
                for (new_meta_map.items) |*entry| {
                    vm.valueDeinit(&entry.key, allocator);
                    vm.valueDeinit(&entry.value, allocator);
                }
                allocator.free(new_meta_map.items);
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
        },
        else => return try vm.shallowClone(&val, allocator),
    };
}

/// VM implementation of (make-keyword ns name) or (make-keyword name).
/// Matches core_keyword behavior: ns/name concatenated with "/".
pub fn vmMakeKeyword(allocator: Allocator, parts: []const Value) anyerror!Value {
    if (parts.len == 0 or parts.len > 2) return error.ArityError;
    const name_val = parts[parts.len - 1];
    const name_str = switch (name_val) {
        .string => |s| s,
        .symbol => |s| s,
        .keyword => |s| s,
        else => return error.TypeError,
    };

    if (parts.len == 2) {
        const ns_val = parts[0];
        if (std.meta.activeTag(ns_val) == .nil) {
            return vm.keywordValue(allocator, name_str);
        }
        const ns_str = switch (ns_val) {
            .string => |s| s,
            .symbol => |s| s,
            .keyword => |s| s,
            else => return error.TypeError,
        };
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, ns_str);
        try buf.appendSlice(allocator, "/");
        try buf.appendSlice(allocator, name_str);
        return vm.keywordValue(allocator, buf.items);
    }
    return vm.keywordValue(allocator, name_str);
}

/// VM implementation of (make-symbol ns name) or (make-symbol name).
/// Matches core_symbol behavior: ns/name concatenated with "/".
pub fn vmMakeSymbol(allocator: Allocator, parts: []const Value) anyerror!Value {
    if (parts.len == 0 or parts.len > 2) return error.ArityError;
    const name_val = parts[parts.len - 1];
    const name_str = switch (name_val) {
        .string => |s| s,
        .symbol => |s| s,
        .keyword => |s| s,
        else => return error.TypeError,
    };

    if (parts.len == 2) {
        const ns_val = parts[0];
        if (std.meta.activeTag(ns_val) == .nil) {
            return vm.symValue(allocator, name_str);
        }
        const ns_str = switch (ns_val) {
            .string => |s| s,
            .symbol => |s| s,
            .keyword => |s| s,
            else => return error.TypeError,
        };
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, ns_str);
        try buf.appendSlice(allocator, "/");
        try buf.appendSlice(allocator, name_str);
        return vm.symValue(allocator, buf.items);
    }
    return vm.symValue(allocator, name_str);
}

/// Create a function value from FnMetadata, capturing current environment.
pub fn vmMakeFn(allocator: Allocator, meta: *const FnMetadata, env: *const vm.Env) anyerror!Value {
    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer {
        for (arities.items) |*a| {
            a.params.deinit(allocator);
            a.body.deinit(allocator);
            if (a.bytecode) |bc_prog| {
                bc_prog.deinit(allocator);
                allocator.destroy(bc_prog);
            }
            if (a.rest_name) |rn| allocator.free(rn);
        }
        allocator.free(arities.items);
    }
    try arities.ensureTotalCapacity(allocator, meta.arities.items.len);
    for (meta.arities.items) |a| {
        const cloned_params = try list.clone(&a.params, allocator);
        const cloned_rest = if (a.rest_name) |rn| try allocator.dupe(u8, rn) else null;
        try arities.append(allocator, vm.Arity{
            .params = cloned_params,
            .body = list.empty(),
            .bytecode = a.bytecode,
            .rest_name = cloned_rest,
        });
    }
    var new_entries = phm.PersistentHashMap.empty();
    var it = env.entries.entryIterator();
    while (it.next()) |entry| {
        new_entries = try new_entries.mapAssoc(allocator, entry.key, entry.val);
    }
    const fn_env: vm.Env = .{
        .allocator = allocator,
        .entries = new_entries,
        .parent = env.parent,
        .ns_manager = env.ns_manager,
    };
    var fn_val = try vm.fnValue(allocator, arities, fn_env, false);
    const persistent_fn = try vm.shallowClone(&fn_val, allocator);
    vm.valueDeinit(&fn_val, allocator);
    return persistent_fn;
}
