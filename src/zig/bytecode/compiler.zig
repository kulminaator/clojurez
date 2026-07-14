// Bytecode compiler: AST → Bytecode.
// Contains the compile() entry point and Compiler struct with core methods.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const eval_mod = @import("../eval.zig");
const bc = @import("instructions.zig");
const vmt = @import("vm_types.zig");
const ch = @import("compiler_helpers.zig");
const csf = @import("compiler_special_forms.zig");

const Allocator = std.mem.Allocator;

// Re-export types
pub const OpCode = bc.OpCode;
pub const BytecodeProgram = bc.BytecodeProgram;
pub const FnAridity = vmt.FnAridity;
pub const FnMetadata = vmt.FnMetadata;

// ============================================================
// Compiler struct
// ============================================================

/// The bytecode compiler. Translates Clojure AST to bytecode instructions.
pub const Compiler = struct {
    allocator: Allocator,
    program: *BytecodeProgram,
    env: ?*vm.Env, // for macro expansion
    fn_name: ?[]const u8 = null, // enclosing function name (for call_self)
    // When true, skip special operator compilation (map, reduce, etc.)
    // and use generic call_n. Used by threading macros to preserve arg order.
    skip_special_ops: bool = false,
    // Function pointer to break circular dependency with compiler_special_forms.zig.
    // Set by the compile() entry point before any compilation begins.
    compile_fn: *const ch.CompileFnType = &compile,

    /// Compile (abs n) => if (n < 0) (0 - n) n
    fn compileAbs(self: *Compiler, arg: Value) anyerror!void {
        // Store arg in a temp variable so we can reuse it
        const tmp_sym = try self.program.addSymbol(self.allocator, "__abs_tmp");
        try self.compileForm(arg);
        _ = try self.program.emit(self.allocator, .store_var, tmp_sym);

        // Load n, compare with 0
        _ = try self.program.emit(self.allocator, .load_var, tmp_sym);
        _ = try self.program.emit(self.allocator, .push_int, 0);
        _ = try self.program.emit0(self.allocator, .lt);

        // jump_if_nil to else branch
        const jnil_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);

        // then branch: (0 - n)
        _ = try self.program.emit(self.allocator, .push_int, 0);
        _ = try self.program.emit(self.allocator, .load_var, tmp_sym);
        _ = try self.program.emit0(self.allocator, .sub);

        // jump to end
        const jump_end_pc = try self.program.emit(self.allocator, .jump, 0);

        const else_pc = self.program.instructions.items.len;
        self.program.instructions.items[jnil_pc].operand = else_pc;

        // else branch: just n
        _ = try self.program.emit(self.allocator, .load_var, tmp_sym);

        const end_pc = self.program.instructions.items.len;
        self.program.instructions.items[jump_end_pc].operand = end_pc;
    }

    /// Compile (boolean x) => if x true false
    fn compileBoolean(self: *Compiler, arg: Value) anyerror!void {
        try self.compileForm(arg);

        // jump_if_nil to false branch
        const jnil_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);

        // true branch
        _ = try self.program.emit0(self.allocator, .push_true);

        // jump to end
        const jump_end_pc = try self.program.emit(self.allocator, .jump, 0);

        const false_pc = self.program.instructions.items.len;
        self.program.instructions.items[jnil_pc].operand = false_pc;

        // false branch
        _ = try self.program.emit0(self.allocator, .push_false);

        const end_pc = self.program.instructions.items.len;
        self.program.instructions.items[jump_end_pc].operand = end_pc;
    }

    /// Map a type predicate name to its bytecode opcode.
    fn typePredicateOpcode(name: []const u8) ?OpCode {
        if (std.mem.eql(u8, name, "number?")) return .is_number;
        if (std.mem.eql(u8, name, "int?")) return .is_int;
        if (std.mem.eql(u8, name, "float?")) return .is_float;
        if (std.mem.eql(u8, name, "double?")) return .is_float;
        if (std.mem.eql(u8, name, "string?")) return .is_string;
        if (std.mem.eql(u8, name, "boolean?")) return .is_boolean;
        if (std.mem.eql(u8, name, "list?")) return .is_list;
        if (std.mem.eql(u8, name, "vector?")) return .is_vector;
        if (std.mem.eql(u8, name, "map?")) return .is_map;
        if (std.mem.eql(u8, name, "set?")) return .is_set;
        if (std.mem.eql(u8, name, "symbol?")) return .is_symbol;
        if (std.mem.eql(u8, name, "keyword?")) return .is_keyword;
        return null;
    }

    /// Try to resolve a symbol at compile time using the function's captured environment.
    fn tryResolveAndEmitLoad(self: *Compiler, sym_name: []const u8) anyerror!bool {
        const e = self.env orelse return false;

        if (std.mem.indexOfScalar(u8, sym_name, '/')) |slash_idx| {
            const alias = sym_name[0..slash_idx];
            const name = sym_name[slash_idx + 1 ..];
            const ns_mgr = eval_mod.findNsManager(e) orelse return false;
            const current_ns = ns_mgr.getCurrentNamespace();
            const target_ns = ns_mgr.resolveAlias(current_ns, alias) orelse alias;
            const target_env = ns_mgr.getNamespace(target_ns) orelse return false;
            const val = target_env.get(name) orelse return false;
            const idx = try self.program.addResolvedValue(self.allocator, val);
            _ = try self.program.emit(self.allocator, .load_cached, idx);
            return true;
        }

        const val = e.get(sym_name) orelse return false;
        const idx = try self.program.addResolvedValue(self.allocator, val);
        _ = try self.program.emit(self.allocator, .load_cached, idx);
        return true;
    }

    /// Compile a form (any Clojure expression).
    pub fn compileForm(self: *Compiler, form: Value) anyerror!void {
        switch (form) {
            .nil => _ = try self.program.emit0(self.allocator, .push_nil),
            .bool => |b| _ = try self.program.emit0(self.allocator, if (b) .push_true else .push_false),
            .integer => |i| {
                const idx = try self.program.addConstant(self.allocator, vm.intValue(i));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
            .float => |f| {
                const idx = try self.program.addConstant(self.allocator, vm.floatValue(f));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
            .string, .keyword, .bigint, .ratio, .decimal, .regex, .character => {
                const idx = try self.program.addConstant(self.allocator, try vm.shallowClone(&form, self.allocator));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
            .symbol => |s| {
                const sym_idx = try self.program.addSymbol(self.allocator, s);
                _ = try self.program.emit(self.allocator, .load_var, sym_idx);
            },
            .list => try self.compileList(form.list.items),
            .vector => try self.compileVector(form.vector.items),
            .map => try self.compileMap(form.map.entries),
            .cons => try self.compileCons(form.cons.*),
            else => {
                const idx = try self.program.addConstant(self.allocator, try vm.shallowClone(&form, self.allocator));
                _ = try self.program.emit(self.allocator, .push_const, idx);
            },
        }
    }

    /// Compile a list (function call or special form).
    pub fn compileList(self: *Compiler, l: list.List) anyerror!void {
        if (l.items.len == 0) {
            _ = try self.program.emit(self.allocator, .list_n, 0);
            return;
        }

        const first = l.items[0];

        if (std.meta.activeTag(first) == .symbol) {
            const sym = first.symbol;

            if (std.mem.eql(u8, sym, "quote")) {
                if (l.items.len == 2) {
                    const idx = try self.program.addConstant(self.allocator, try vm.shallowClone(&l.items[1], self.allocator));
                    _ = try self.program.emit(self.allocator, .push_const, idx);
                    return;
                }
            }
            if (std.mem.eql(u8, sym, "if")) { try csf.compileIf(self, l.items); return; }
            if (std.mem.eql(u8, sym, "do")) { try self.compileDo(l.items); return; }
            if (std.mem.eql(u8, sym, "let")) { try csf.compileLet(self, l.items); return; }
            if (std.mem.eql(u8, sym, "var") or std.mem.eql(u8, sym, "deref") or std.mem.eql(u8, sym, "@")) {
                if (l.items.len == 2) {
                    try self.compileForm(l.items[1]);
                    _ = try self.program.emit0(self.allocator, .deref);
                    return;
                }
            }
            if (std.mem.eql(u8, sym, "set!")) {
                if (l.items.len == 3 and std.meta.activeTag(l.items[1]) == .symbol) {
                    try self.compileForm(l.items[2]);
                    const sym_idx = try self.program.addSymbol(self.allocator, l.items[1].symbol);
                    _ = try self.program.emit(self.allocator, .store_var, sym_idx);
                    return;
                }
            }
            if (std.mem.eql(u8, sym, "fn")) { try csf.compileFn(self, l.items); return; }
            if (std.mem.eql(u8, sym, "and")) { try csf.compileAnd(self, l.items); return; }
            if (std.mem.eql(u8, sym, "or")) { try csf.compileOr(self, l.items); return; }
            if (std.mem.eql(u8, sym, "cond")) { try csf.compileCond(self, l.items); return; }
            if (std.mem.eql(u8, sym, "when")) { try csf.compileWhen(self, l.items); return; }
            if (std.mem.eql(u8, sym, "when-not")) { try csf.compileWhenNot(self, l.items); return; }
            if (std.mem.eql(u8, sym, "when-first")) { try csf.compileWhenFirst(self, l.items); return; }
            if (std.mem.eql(u8, sym, "if-let")) { try csf.compileIfLet(self, l.items); return; }
            if (std.mem.eql(u8, sym, "when-let")) { try csf.compileWhenLet(self, l.items); return; }
            if (std.mem.eql(u8, sym, "when-some")) { try csf.compileWhenSome(self, l.items); return; }
            if (std.mem.eql(u8, sym, "loop")) { try csf.compileLoop(self, l.items); return; }
            if (std.mem.eql(u8, sym, "recur")) { try csf.compileRecur(self, l.items); return; }
            if (std.mem.eql(u8, sym, "case")) { try csf.compileCase(self, l.items); return; }
            if (std.mem.eql(u8, sym, "letfn")) { try csf.compileLetFn(self, l.items); return; }
            if (std.mem.eql(u8, sym, "->")) { try csf.compileThreadingRight(self, l.items); return; }
            if (std.mem.eql(u8, sym, "->>")) { try csf.compileThreadingLeft(self, l.items); return; }
            if (std.mem.eql(u8, sym, "quasiquote")) { try csf.compileQuasiquote(self, l.items); return; }
            if (std.mem.eql(u8, sym, "lazy-seq")) { try csf.compileLazySeq(self, l.items); return; }

            // Macro expansion
            if (self.env) |e| {
                if (try self.tryExpandMacro(l, e)) |expanded_list| {
                    for (expanded_list.items) |form| {
                        try self.compileForm(form);
                    }
                    return;
                }
            }
        }

        try self.compileFunctionCall(l.items);
    }

    /// Compile (do body...).
    pub fn compileDo(self: *Compiler, items: []const Value) anyerror!void {
        for (items[1..]) |form| {
            try self.compileForm(form);
        }
    }

    /// Compile a vector: [expr1 expr2 ...].
    pub fn compileVector(self: *Compiler, v: vec.Vector) anyerror!void {
        const n = v.items.len;
        for (v.items) |item| {
            try self.compileForm(item);
        }
        _ = try self.program.emit(self.allocator, .vector_n, n);
    }

    /// Compile a map: {k1 v1 k2 v2 ...}.
    pub fn compileMap(self: *Compiler, m: vm.Map) anyerror!void {
        const n = m.items.len;
        for (m.items) |entry| {
            try self.compileForm(entry.key);
            try self.compileForm(entry.value);
        }
        _ = try self.program.emit(self.allocator, .map_n, n);
    }

    /// Compile a cons cell: (cons head tail).
    pub fn compileCons(self: *Compiler, c: vm.ConsData) anyerror!void {
        try self.compileForm(c.tail);
        try self.compileForm(c.head);
        _ = try self.program.emit0(self.allocator, .cons);
    }

    /// Compile a function call: (fn arg1 arg2 ...).
    pub fn compileFunctionCall(self: *Compiler, items: []const Value) anyerror!void {
        if (items.len > 0 and std.meta.activeTag(items[0]) == .symbol) {
            const op_name = items[0].symbol;

            const all_simple = blk: {
                for (items[1..]) |arg| {
                    if (!ch.isSimpleBytecodeForm(arg)) break :blk false;
                }
                break :blk true;
            };

            const all_safe = blk: {
                for (items[1..]) |arg| {
                    if (!ch.isSafeBytecodeArg(arg)) break :blk false;
                }
                break :blk true;
            };

            // When skip_special_ops is true (e.g., threading macros building synthetic
            // call lists), disable special operator compilation to preserve argument order.
            const effective_all_safe = all_safe and !self.skip_special_ops;
            const effective_all_simple = all_simple and !self.skip_special_ops;

            // Arithmetic operators
            if (effective_all_safe) {
                if (std.mem.eql(u8, op_name, "+")) {
                    return self.compileArithmeticOp(items[1..], .add);
                }
                if (std.mem.eql(u8, op_name, "-")) {
                    if (items.len == 2) {
                        try self.compileForm(items[1]);
                        _ = try self.program.emit0(self.allocator, .neg);
                        return;
                    }
                    return self.compileArithmeticOp(items[1..], .sub);
                }
                if (std.mem.eql(u8, op_name, "*")) {
                    return self.compileArithmeticOp(items[1..], .mul);
                }
                if (std.mem.eql(u8, op_name, "/")) {
                    return self.compileArithmeticOp(items[1..], .div);
                }
                if (std.mem.eql(u8, op_name, "rem")) {
                    return self.compileArithmeticOp(items[1..], .rem);
                }
                if (std.mem.eql(u8, op_name, "quot")) {
                    return self.compileArithmeticOp(items[1..], .quot);
                }
                if (std.mem.eql(u8, op_name, "mod")) {
                    return self.compileArithmeticOp(items[1..], .mod);
                }

                // Comparison operators
                if (items.len >= 3) {
                    if (std.mem.eql(u8, op_name, "=")) {
                        return self.compileMultiArgEq(items[1..]);
                    }
                    if (std.mem.eql(u8, op_name, "!=") or std.mem.eql(u8, op_name, "not=")) {
                        return self.compileMultiArgNe(items[1..]);
                    }
                    // 2-arg only for ordering comparisons
                    if (items.len == 3) {
                        if (std.mem.eql(u8, op_name, "<")) {
                            return self.compileComparisonOp(items[1..], .lt);
                        }
                        if (std.mem.eql(u8, op_name, ">")) {
                            return self.compileComparisonOp(items[1..], .gt);
                        }
                        if (std.mem.eql(u8, op_name, "<=")) {
                            return self.compileComparisonOp(items[1..], .le);
                        }
                        if (std.mem.eql(u8, op_name, ">=")) {
                            return self.compileComparisonOp(items[1..], .ge);
                        }
                    }
                }
            }

            // not: (not x) => push x, not
            if (effective_all_safe and std.mem.eql(u8, op_name, "not")) {
                if (items.len == 2) {
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, .not);
                    return;
                }
            }

            // nil?: (nil? x) => push x, is_nil
            if (effective_all_safe and std.mem.eql(u8, op_name, "nil?")) {
                if (items.len == 2) {
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, .is_nil);
                    return;
                }
            }

            // Type predicates: (number? x), (int? x), (float? x), etc.
            if (effective_all_safe and items.len == 2) {
                const tc_opcode = typePredicateOpcode(op_name);
                if (tc_opcode) |opcode| {
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, opcode);
                    return;
                }
            }

            // empty?: (empty? coll) => push coll, is_empty
            if (effective_all_safe and std.mem.eql(u8, op_name, "empty?") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .is_empty);
                return;
            }

            // not-empty: (not-empty coll) => push coll, is_not_empty
            if (effective_all_safe and std.mem.eql(u8, op_name, "not-empty") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .is_not_empty);
                return;
            }

            // empty: (empty coll) => push coll, make_empty
            if (effective_all_safe and std.mem.eql(u8, op_name, "empty") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .make_empty);
                return;
            }

            // Shorthand operators (Phase 5)
            if (effective_all_safe and items.len == 2) {
                if (std.mem.eql(u8, op_name, "inc")) {
                    // (inc n) => n 1 +
                    try self.compileForm(items[1]);
                    _ = try self.program.emit(self.allocator, .push_int, 1);
                    _ = try self.program.emit0(self.allocator, .add);
                    return;
                }
                if (std.mem.eql(u8, op_name, "dec")) {
                    // (dec n) => n 1 -
                    try self.compileForm(items[1]);
                    _ = try self.program.emit(self.allocator, .push_int, 1);
                    _ = try self.program.emit0(self.allocator, .sub);
                    return;
                }
                if (std.mem.eql(u8, op_name, "even?")) {
                    // (even? n) => n 2 rem 0 =
                    try self.compileForm(items[1]);
                    _ = try self.program.emit(self.allocator, .push_int, 2);
                    _ = try self.program.emit0(self.allocator, .rem);
                    _ = try self.program.emit(self.allocator, .push_int, 0);
                    _ = try self.program.emit0(self.allocator, .eq);
                    return;
                }
                if (std.mem.eql(u8, op_name, "odd?")) {
                    // (odd? n) => n 2 rem 0 = not
                    try self.compileForm(items[1]);
                    _ = try self.program.emit(self.allocator, .push_int, 2);
                    _ = try self.program.emit0(self.allocator, .rem);
                    _ = try self.program.emit(self.allocator, .push_int, 0);
                    _ = try self.program.emit0(self.allocator, .eq);
                    _ = try self.program.emit0(self.allocator, .not);
                    return;
                }
                if (std.mem.eql(u8, op_name, "identity")) {
                    // (identity x) => just x
                    try self.compileForm(items[1]);
                    return;
                }
                if (std.mem.eql(u8, op_name, "abs")) {
                    // (abs n) => if (n < 0) (0 - n) n
                    try self.compileAbs(items[1]);
                    return;
                }
                if (std.mem.eql(u8, op_name, "boolean")) {
                    // (boolean x) => if x true false
                    try self.compileBoolean(items[1]);
                    return;
                }
            }

            // count: (count coll) => push coll, count
            if (effective_all_simple and std.mem.eql(u8, op_name, "count")) {
                if (items.len == 2) {
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, .count);
                    return;
                }
            }

            // first: (first coll) => push coll, first
            if (effective_all_simple and std.mem.eql(u8, op_name, "first")) {
                if (items.len == 2) {
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, .first);
                    return;
                }
            }

            // rest: (rest coll) => push coll, rest
            if (effective_all_simple and std.mem.eql(u8, op_name, "rest")) {
                if (items.len == 2) {
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, .rest);
                    return;
                }
            }

            // nth: (nth coll index) => push coll, push index, nth
            if (effective_all_safe and std.mem.eql(u8, op_name, "nth")) {
                if (items.len == 3) {
                    try self.compileForm(items[1]);
                    try self.compileForm(items[2]);
                    _ = try self.program.emit0(self.allocator, .nth);
                    return;
                }
            }

            // get: (get map key) => push map, push key, get
            if (effective_all_safe and std.mem.eql(u8, op_name, "get")) {
                if (items.len == 3) {
                    try self.compileForm(items[1]);
                    try self.compileForm(items[2]);
                    _ = try self.program.emit0(self.allocator, .get);
                    return;
                }
            }

            // conj: (conj coll item) => push coll, push item, conj
            if (effective_all_safe and std.mem.eql(u8, op_name, "conj")) {
                if (items.len == 3) {
                    try self.compileForm(items[1]);
                    try self.compileForm(items[2]);
                    _ = try self.program.emit0(self.allocator, .conj);
                    return;
                }
            }

            // assoc: (assoc map key val) => push map, push key, push val, assoc
            if (effective_all_safe and std.mem.eql(u8, op_name, "assoc")) {
                if (items.len == 4) {
                    try self.compileForm(items[1]);
                    try self.compileForm(items[2]);
                    try self.compileForm(items[3]);
                    _ = try self.program.emit0(self.allocator, .assoc);
                    return;
                }
            }

            // compare: (compare a b) => push a, push b, compare
            if (effective_all_safe and std.mem.eql(u8, op_name, "compare")) {
                if (items.len == 3) {
                    try self.compileForm(items[1]);
                    try self.compileForm(items[2]);
                    _ = try self.program.emit0(self.allocator, .compare);
                    return;
                }
            }

            // seq: (seq coll) => push coll, seq
            if (effective_all_simple and std.mem.eql(u8, op_name, "seq")) {
                if (items.len == 2) {
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, .seq);
                    return;
                }
            }

            // cons: (cons head tail) => push tail, push head, cons
            if (effective_all_safe and std.mem.eql(u8, op_name, "cons")) {
                if (items.len == 3) {
                    try self.compileForm(items[2]);
                    try self.compileForm(items[1]);
                    _ = try self.program.emit0(self.allocator, .cons);
                    return;
                }
            }

            // list: (list arg1 arg2 ...) => compile args, list_n
            if (effective_all_safe and std.mem.eql(u8, op_name, "list")) {
                const n = items.len - 1;
                var li: usize = 1;
                while (li < items.len) : (li += 1) {
                    try self.compileForm(items[li]);
                }
                _ = try self.program.emit(self.allocator, .list_n, n);
                return;
            }

            // contains?: (contains? coll key) => compile coll, compile key, contains
            if (effective_all_safe and std.mem.eql(u8, op_name, "contains?") and items.len == 3) {
                try self.compileForm(items[1]);
                try self.compileForm(items[2]);
                _ = try self.program.emit0(self.allocator, .contains);
                return;
            }

            // str: (str arg1 arg2 ...) => compile args, str_n
            if (effective_all_safe and std.mem.eql(u8, op_name, "str")) {
                const n = items.len - 1;
                var si: usize = 1;
                while (si < items.len) : (si += 1) {
                    try self.compileForm(items[si]);
                }
                _ = try self.program.emit(self.allocator, .str_n, n);
                return;
            }

            // Phase 12: peek: (peek coll) => push coll, peek
            if (effective_all_safe and std.mem.eql(u8, op_name, "peek") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .peek);
                return;
            }

            // Phase 12: pop: (pop coll) => push coll, pop
            if (effective_all_safe and std.mem.eql(u8, op_name, "pop") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .pop);
                return;
            }

            // Phase 13: reduced: (reduced val) => push val, make_reduced
            if (effective_all_safe and std.mem.eql(u8, op_name, "reduced") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .make_reduced);
                return;
            }

            // Phase 13: reduced?: (reduced? val) => push val, is_reduced
            if (effective_all_safe and std.mem.eql(u8, op_name, "reduced?") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .is_reduced);
                return;
            }

            // Phase 13: unreduced: (unreduced val) => push val, unreduced
            if (effective_all_safe and std.mem.eql(u8, op_name, "unreduced") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .unreduced);
                return;
            }

            // Phase 14: meta: (meta val) => push val, get_meta
            if (effective_all_safe and std.mem.eql(u8, op_name, "meta") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .get_meta);
                return;
            }

            // Phase 14: with-meta: (with-meta val meta) => push val, push meta, set_meta
            if (effective_all_safe and std.mem.eql(u8, op_name, "with-meta") and items.len == 3) {
                try self.compileForm(items[1]);
                try self.compileForm(items[2]);
                _ = try self.program.emit0(self.allocator, .set_meta);
                return;
            }

            // Phase 15: keyword: (keyword name) or (keyword ns name)
            if (effective_all_safe and std.mem.eql(u8, op_name, "keyword")) {
                const n = items.len - 1;
                if (n == 1 or n == 2) {
                    var ki: usize = 1;
                    while (ki < items.len) : (ki += 1) {
                        try self.compileForm(items[ki]);
                    }
                    _ = try self.program.emit(self.allocator, .make_keyword, n);
                    return;
                }
            }

            // Phase 15: symbol: (symbol name) or (symbol ns name)
            if (effective_all_safe and std.mem.eql(u8, op_name, "symbol")) {
                const n = items.len - 1;
                if (n == 1 or n == 2) {
                    var si: usize = 1;
                    while (si < items.len) : (si += 1) {
                        try self.compileForm(items[si]);
                    }
                    _ = try self.program.emit(self.allocator, .make_symbol, n);
                    return;
                }
            }

            // Phase 4: range: (range end) or (range start end) or (range start end step)
            if (effective_all_safe and std.mem.eql(u8, op_name, "range")) {
                const n = items.len - 1;
                if (n >= 1 and n <= 3) {
                    // Push args in order: start first (or just end for 1-arg)
                    var ri: usize = 1;
                    while (ri < items.len) : (ri += 1) {
                        try self.compileForm(items[ri]);
                    }
                    _ = try self.program.emit(self.allocator, .range, n);
                    return;
                }
            }

            // Phase 4: vec: (vec coll)
            if (effective_all_safe and std.mem.eql(u8, op_name, "vec") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .vec);
                return;
            }

            // Phase 5: sort: (sort coll)
            if (effective_all_safe and std.mem.eql(u8, op_name, "sort") and items.len == 2) {
                try self.compileForm(items[1]);
                _ = try self.program.emit0(self.allocator, .sort);
                return;
            }

            // Phase 5: sort-by: (sort-by key-fn coll)
            if (effective_all_safe and std.mem.eql(u8, op_name, "sort-by") and items.len == 3) {
                try self.compileForm(items[1]);  // key-fn
                try self.compileForm(items[2]);  // coll
                _ = try self.program.emit0(self.allocator, .sort_by);
                return;
            }

            // Phase 5: merge: (merge map1 map2) or (merge map1 map2 map3 ...)
            if (effective_all_safe and std.mem.eql(u8, op_name, "merge")) {
                const n = items.len - 1;
                if (n >= 2) {
                    // Push in forward order: m1 first, m2 second, etc.
                    // VM will pop and reverse to get [m1, m2, ...]
                    var mi: usize = 1;
                    while (mi < items.len) : (mi += 1) {
                        try self.compileForm(items[mi]);
                    }
                    _ = try self.program.emit(self.allocator, .merge, n);
                    return;
                }
            }

            // Phase 6: map: (map fn coll)
            if (effective_all_safe and std.mem.eql(u8, op_name, "map") and items.len == 3) {
                try self.compileForm(items[1]);  // fn
                try self.compileForm(items[2]);  // coll
                _ = try self.program.emit0(self.allocator, .map_fn);
                return;
            }

            // Phase 6: reduce: (reduce fn coll) or (reduce fn init coll)
            if (effective_all_safe and std.mem.eql(u8, op_name, "reduce")) {
                const n = items.len - 1;
                if (n == 2 or n == 3) {
                    if (n == 2) {
                        try self.compileForm(items[1]);  // fn
                        try self.compileForm(items[2]);  // coll
                    } else {
                        try self.compileForm(items[1]);  // fn
                        try self.compileForm(items[2]);  // init
                        try self.compileForm(items[3]);  // coll
                    }
                    _ = try self.program.emit(self.allocator, .reduce_fn, n);
                    return;
                }
            }

            // Phase 7: apply: (apply fn args-coll)
            if (effective_all_safe and std.mem.eql(u8, op_name, "apply") and items.len == 3) {
                try self.compileForm(items[1]);  // fn
                try self.compileForm(items[2]);  // args-coll
                _ = try self.program.emit0(self.allocator, .apply_fn);
                return;
            }

            // Phase 9: concat: (concat coll1 coll2 ...)
            if (effective_all_safe and std.mem.eql(u8, op_name, "concat")) {
                const n = items.len - 1;
                if (n >= 1) {
                    var ci: usize = 1;
                    while (ci < items.len) : (ci += 1) {
                        try self.compileForm(items[ci]);
                    }
                    _ = try self.program.emit(self.allocator, .concat_n, n);
                    return;
                }
            }
        }

        // Not a known operator — compile as regular function call
        const n = items.len - 1;
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            try self.compileForm(items[i]);
        }

        // Check for self-recursive call
        if (std.meta.activeTag(items[0]) == .symbol) {
            if (self.fn_name) |fname| {
                const op_name = items[0].symbol;
                if (std.mem.eql(u8, op_name, fname)) {
                    _ = try self.program.emit(self.allocator, .call_self, n);
                    return;
                }
            }
        }

        if (std.meta.activeTag(items[0]) == .symbol) {
            const op_name = items[0].symbol;
            if (!try self.tryResolveAndEmitLoad(op_name)) {
                const sym_idx = try self.program.addSymbol(self.allocator, op_name);
                _ = try self.program.emit(self.allocator, .load_var, sym_idx);
            }
        } else {
            try self.compileForm(items[0]);
        }

        _ = try self.program.emit(self.allocator, .call_n, n);
    }

    /// Compile a variadic arithmetic operation: chain binary ops.
    fn compileArithmeticOp(self: *Compiler, args: []const Value, opcode: OpCode) anyerror!void {
        if (args.len == 0) return;
        try self.compileForm(args[0]);
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            try self.compileForm(args[i]);
            _ = try self.program.emit0(self.allocator, opcode);
        }
    }

    /// Compile a 2-arg comparison operation.
    fn compileComparisonOp(self: *Compiler, args: []const Value, opcode: OpCode) anyerror!void {
        try self.compileForm(args[0]);
        try self.compileForm(args[1]);
        _ = try self.program.emit0(self.allocator, opcode);
    }

    /// Compile variadic equality: (= a b c ...) => (and (= a b) (= b c) ...)
    /// Uses short-circuit and logic: compile each (= x y), store in tmp,
    /// jump to end if falsy. Load tmp at end.
    fn compileMultiArgEq(self: *Compiler, args: []const Value) anyerror!void {
        if (args.len == 0) {
            _ = try self.program.emit0(self.allocator, .push_true);
            return;
        }
        if (args.len == 1) {
            _ = try self.program.emit0(self.allocator, .push_true);
            return;
        }
        if (args.len == 2) {
            return self.compileComparisonOp(args, .eq);
        }
        // Compile pairwise comparisons with short-circuit and logic
        const tmp_idx = try self.program.addSymbol(self.allocator, "__eq_tmp");
        var jump_nil_pcs: std.ArrayListUnmanaged(usize) = .empty;
        defer jump_nil_pcs.deinit(self.allocator);

        var i: usize = 0;
        while (i < args.len - 1) : (i += 1) {
            // Compile (= args[i] args[i+1])
            try self.compileForm(args[i]);
            try self.compileForm(args[i + 1]);
            _ = try self.program.emit0(self.allocator, .eq);
            // Store result
            _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
            // Load and check
            _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
            const jnil_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
            try jump_nil_pcs.append(self.allocator, jnil_pc);
        }
        // All comparisons passed — load final result
        const end_pc = self.program.instructions.items.len;
        _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
        // Patch all jump targets
        for (jump_nil_pcs.items) |pc| {
            self.program.instructions.items[pc].operand = end_pc;
        }
    }

    /// Compile variadic inequality: (!= a b c ...) => (not (and (= a b) (= b c) ...))
    fn compileMultiArgNe(self: *Compiler, args: []const Value) anyerror!void {
        if (args.len == 0) {
            _ = try self.program.emit0(self.allocator, .push_true);
            return;
        }
        if (args.len == 1) {
            _ = try self.program.emit0(self.allocator, .push_true);
            return;
        }
        if (args.len == 2) {
            return self.compileComparisonOp(args, .ne);
        }
        // Same as multi-arg eq, then negate
        const tmp_idx = try self.program.addSymbol(self.allocator, "__ne_tmp");
        var jump_nil_pcs: std.ArrayListUnmanaged(usize) = .empty;
        defer jump_nil_pcs.deinit(self.allocator);

        var i: usize = 0;
        while (i < args.len - 1) : (i += 1) {
            try self.compileForm(args[i]);
            try self.compileForm(args[i + 1]);
            _ = try self.program.emit0(self.allocator, .eq);
            _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
            _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
            const jnil_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
            try jump_nil_pcs.append(self.allocator, jnil_pc);
        }
        const end_pc = self.program.instructions.items.len;
        _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
        for (jump_nil_pcs.items) |pc| {
            self.program.instructions.items[pc].operand = end_pc;
        }
        // Negate the result
        _ = try self.program.emit0(self.allocator, .not);
    }

    /// Try to expand a macro call.
    fn tryExpandMacro(self: *Compiler, l: list.List, env: *vm.Env) anyerror!?list.List {
        if (l.items.len == 0) return null;
        const first = l.items[0];
        if (std.meta.activeTag(first) != .symbol) return null;

        const op_val = env.get(first.symbol);
        if (op_val == null) return null;
        if (std.meta.activeTag(op_val.?) != .function) return null;
        if (!op_val.?.function.is_macro) return null;

        var macro_args: list.List = .empty;
        defer macro_args.deinit(self.allocator);
        var i: usize = 1;
        while (i < l.items.len) : (i += 1) {
            try macro_args.append(self.allocator, try vm.shallowClone(&l.items[i], self.allocator));
        }

        const macro_ptr = try eval_mod.callWithEnvV(self.allocator, &op_val.?, &macro_args, env, 0);
        defer vm.valueDeinit(macro_ptr, self.allocator);

        const cloned = try vm.shallowClone(macro_ptr, self.allocator);
        var expanded: list.List = .empty;
        errdefer expanded.deinit(self.allocator);
        try expanded.append(self.allocator, cloned);
        return expanded;
    }
};

// ============================================================
// Public compile entry point
// ============================================================

/// Compile a Clojure AST (list.List) to bytecode.
/// The AST is a list where the first element is the operator and the rest are arguments.
/// env is optional — needed for macro expansion.
/// fn_name is the name of the enclosing function (for call_self support).
/// Returns a BytecodeProgram that can be executed by the VM.
pub fn compile(allocator: Allocator, ast: list.List, source_file: []const u8, env: ?*vm.Env, fn_name: ?[]const u8) anyerror!BytecodeProgram {
    var program = BytecodeProgram.init(allocator);
    errdefer program.deinit(allocator);
    program.source_file = source_file;

    var compiler = Compiler{
        .allocator = allocator,
        .program = &program,
        .env = env,
        .fn_name = fn_name,
    };

    var forms = ast.items;
    if (forms.len > 0 and std.meta.activeTag(forms[0]) == .symbol and
        std.mem.eql(u8, forms[0].symbol, "do"))
    {
        forms = forms[1..];
    }
    for (forms) |form| {
        try compiler.compileForm(form);
    }
    _ = try program.emit0(allocator, .stop);

    return program;
}
