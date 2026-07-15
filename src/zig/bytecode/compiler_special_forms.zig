// Compiler special forms: if, let, fn, and, or, cond, when, loop, recur, case, letfn.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;
const list = @import("../list.zig");
const vec = @import("../vector.zig");
const eval_mod = @import("../eval.zig");
const bc = @import("instructions.zig");
const vmt = @import("vm_types.zig");
const ch = @import("compiler_helpers.zig");

const Allocator = std.mem.Allocator;

// Forward declaration of Compiler struct (defined in compiler.zig)
const Compiler = @import("compiler.zig").Compiler;

// Re-export types used by these functions
pub const OpCode = bc.OpCode;
pub const BytecodeProgram = bc.BytecodeProgram;
pub const FnAridity = vmt.FnAridity;
pub const FnMetadata = vmt.FnMetadata;

/// Compile (if test then else?).
pub fn compileIf(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) return;

    try self.compileForm(items[1]);
    const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
    try self.compileForm(items[2]);
    const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);

    const else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_to_else_pc].operand = else_pc;

    if (items.len >= 4) {
        try self.compileForm(items[3]);
    } else {
        _ = try self.program.emit0(self.allocator, .push_nil);
    }

    const past_else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
}

/// Compile (let [bindings] body...).
pub fn compileLet(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) return;

    const bindings = items[1];
    const body = items[2..];

    const bind_items: []const Value = switch (std.meta.activeTag(bindings)) {
        .list => bindings.list.items.items,
        .vector => bindings.vector.items.items,
        else => return,
    };

    var i: usize = 0;
    while (i < bind_items.len) {
        const elem = bind_items[i];
        // Skip type hint symbols (starting with ^)
        if (std.meta.activeTag(elem) == .symbol) {
            const s = elem.symbol.slice();
            if (s.len > 0 and s[0] == '^') {
                i += 1;
                continue;
            }
        }
        if (i + 1 >= bind_items.len) return;
        const val = bind_items[i + 1];
        try self.compileForm(val);
        if (std.meta.activeTag(elem) == .symbol) {
            const sym_idx = try self.program.addSymbol(self.allocator, elem.symbol.slice());
            _ = try self.program.emit(self.allocator, .store_var, sym_idx);
        }
        i += 2;
    }

    for (body) |form| {
        try self.compileForm(form);
    }
}

/// Compile (fn name? ([params] body...)+).
pub fn compileFn(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) return;
    var idx: usize = 1;
    var fn_name: ?[]const u8 = null;

    if (std.meta.activeTag(items[idx]) == .symbol) {
        fn_name = try self.allocator.dupe(u8, items[idx].symbol.slice());
        idx += 1;
    }

    var fn_arities: std.ArrayListUnmanaged(FnAridity) = .empty;
    errdefer {
        for (fn_arities.items) |*a| {
            a.params.deinit(self.allocator);
            if (a.bytecode) |bc_prog| {
                bc_prog.deinit(self.allocator);
                self.allocator.destroy(bc_prog);
            }
            if (a.rest_name) |rn| self.allocator.free(rn);
        }
        fn_arities.deinit(self.allocator);
    }

    while (idx < items.len) {
        const form = items[idx];
        idx += 1;

        var params_list: list.List = undefined;
        var body_forms: []const Value = undefined;

        if (std.meta.activeTag(form) == .vector) {
            params_list = try ch.listFromVector(self.allocator, form.vector.items);
            const body_start = idx;
            while (idx < items.len) {
                const next = items[idx];
                if (ch.looksLikeParamList(next) and idx + 1 < items.len) break;
                idx += 1;
            }
            body_forms = items[body_start..idx];
        } else if (std.meta.activeTag(form) == .list) {
            if (form.list.items.items.len == 0) return;
            const inner_first = form.list.items.items[0];
            if (std.meta.activeTag(inner_first) == .vector) {
                params_list = try ch.listFromVector(self.allocator, inner_first.vector.items);
                body_forms = form.list.items.items[1..];
            } else {
                params_list = form.list.items;
                const body_start = idx;
                while (idx < items.len) {
                    const next = items[idx];
                    if (ch.looksLikeParamList(next) and idx + 1 < items.len) break;
                    idx += 1;
                }
                body_forms = items[body_start..idx];
            }
        } else {
            continue;
        }

        var parsed = try ch.parseParams(self.allocator, params_list);
        defer {
            parsed.params.deinit(self.allocator);
            if (parsed.rest_name) |rn| self.allocator.free(rn);
        }

        var skip_bytecode = false;
        for (body_forms) |bf| {
            if (ch.containsUnhandledSpecialFormHelper(bf)) { skip_bytecode = true; break; }
        }
        if (!skip_bytecode) {
            var pi: usize = 0;
            while (pi < parsed.params.items.len) : (pi += 1) {
                switch (std.meta.activeTag(parsed.params.items[pi])) {
                    .vector, .list => { skip_bytecode = true; break; },
                    else => {},
                }
            }
        }

        var bc_ptr: ?*BytecodeProgram = null;
        if (!skip_bytecode) {
            var body_list: list.List = .empty;
            errdefer body_list.deinit(self.allocator);
            try body_list.append(self.allocator, try vm.symValue(self.allocator, "do"));
            for (body_forms) |bf| {
                try body_list.append(self.allocator, try vm.shallowClone(&bf, self.allocator));
            }
            const bc_prog = try self.compile_fn(self.allocator, body_list, "<fn>", self.env, null);
            const bc_created = try self.allocator.create(BytecodeProgram);
            bc_created.* = bc_prog;
            bc_ptr = bc_created;
        }

        const cloned_params = try list.clone(&parsed.params, self.allocator);
        const cloned_rest = if (parsed.rest_name) |rn| try self.allocator.dupe(u8, rn) else null;
        try fn_arities.append(self.allocator, FnAridity{
            .params = cloned_params,
            .bytecode = bc_ptr,
            .rest_name = cloned_rest,
        });
    }

    const meta = try self.allocator.create(FnMetadata);
    meta.* = .{
        .arities = fn_arities,
        .name = fn_name,
        .allocator = self.allocator,
    };

    if (self.program.fn_pool == null) {
        self.program.fn_pool = try self.allocator.alloc(*FnMetadata, 1);
        self.program.fn_pool.?[0] = meta;
    } else {
        const old_pool = self.program.fn_pool.?;
        const new_pool = try self.allocator.realloc(old_pool, old_pool.len + 1);
        new_pool[old_pool.len] = meta;
        self.program.fn_pool = new_pool;
    }
    const meta_idx = self.program.fn_pool.?.len - 1;

    _ = try self.program.emit(self.allocator, .make_fn, meta_idx);
}

/// Compile (and exprs...) — short-circuit logical and.
pub fn compileAnd(self: *Compiler, items: []const Value) anyerror!void {
    const forms = items[1..];
    if (forms.len == 0) {
        _ = try self.program.emit0(self.allocator, .push_true);
        return;
    }
    if (forms.len == 1) {
        try self.compileForm(forms[0]);
        return;
    }
    const tmp_idx = try self.program.addSymbol(self.allocator, "__and_tmp");
    for (forms) |form| {
        try self.compileForm(form);
        _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
        _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
        _ = try self.program.emit(self.allocator, .jump_if_nil, 0);
    }
    const end_pc = self.program.instructions.items.len;
    _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
    var i: usize = end_pc;
    while (i > 0) : (i -= 1) {
        if (self.program.instructions.items[i].opcode == .jump_if_nil) {
            self.program.instructions.items[i].operand = end_pc;
        }
    }
    if (end_pc > 0 and self.program.instructions.items[0].opcode == .jump_if_nil) {
        self.program.instructions.items[0].operand = end_pc;
    }
}

/// Compile (or exprs...) — short-circuit logical or.
pub fn compileOr(self: *Compiler, items: []const Value) anyerror!void {
    const forms = items[1..];
    if (forms.len == 0) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    if (forms.len == 1) {
        try self.compileForm(forms[0]);
        return;
    }
    const tmp_idx = try self.program.addSymbol(self.allocator, "__or_tmp");
    for (forms) |form| {
        try self.compileForm(form);
        _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
        _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
        _ = try self.program.emit(self.allocator, .jump_if_not_nil, 0);
    }
    const end_pc = self.program.instructions.items.len;
    _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
    var i: usize = end_pc;
    while (i > 0) : (i -= 1) {
        if (self.program.instructions.items[i].opcode == .jump_if_not_nil) {
            self.program.instructions.items[i].operand = end_pc;
        }
    }
    if (end_pc > 0 and self.program.instructions.items[0].opcode == .jump_if_not_nil) {
        self.program.instructions.items[0].operand = end_pc;
    }
}

/// Compile (cond test1 result1 test2 result2 ... :else default).
pub fn compileCond(self: *Compiler, items: []const Value) anyerror!void {
    const clauses = items[1..];
    if (clauses.len == 0) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    var clause_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer clause_starts.deinit(self.allocator);
    var jump_nil_pcs: std.ArrayListUnmanaged(usize) = .empty;
    defer jump_nil_pcs.deinit(self.allocator);
    var jump_end_pcs: std.ArrayListUnmanaged(usize) = .empty;
    defer jump_end_pcs.deinit(self.allocator);
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const cond_test = clauses[i];
        const is_else = std.meta.activeTag(cond_test) == .keyword and
            std.mem.eql(u8, cond_test.keyword.slice(), "else");
        try clause_starts.append(self.allocator, self.program.instructions.items.len);
        if (is_else) {
            if (i + 1 < clauses.len) {
                try self.compileForm(clauses[i + 1]);
            }
        } else {
            try self.compileForm(cond_test);
            const jnil_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
            try jump_nil_pcs.append(self.allocator, jnil_pc);
            if (i + 1 < clauses.len) {
                try self.compileForm(clauses[i + 1]);
            }
            const jump_pc = try self.program.emit(self.allocator, .jump, 0);
            try jump_end_pcs.append(self.allocator, jump_pc);
        }
    }
    const end_pc = self.program.instructions.items.len;
    var j: usize = 0;
    while (j < jump_nil_pcs.items.len) : (j += 1) {
        // Last non-else clause: jump to end (no next clause to fall through to)
        const target = if (j + 1 < clause_starts.items.len)
            clause_starts.items[j + 1]
        else
            end_pc;
        self.program.instructions.items[jump_nil_pcs.items[j]].operand = target;
    }
    for (jump_end_pcs.items) |pc| {
        self.program.instructions.items[pc].operand = end_pc;
    }
}

/// Compile (when test body...) — sugar for (if test (do body...) nil).
pub fn compileWhen(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    try self.compileForm(items[1]);
    const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
    for (items[2..]) |form| {
        try self.compileForm(form);
    }
    const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);
    const else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_to_else_pc].operand = else_pc;
    _ = try self.program.emit0(self.allocator, .push_nil);
    const past_else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
}

/// Compile (when-not test body...) — desugars to (if (not test) (do body...) nil)
pub fn compileWhenNot(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    // Compile test
    try self.compileForm(items[1]);
    // Negate
    _ = try self.program.emit0(self.allocator, .not);
    // jump_if_nil to end (test was truthy, skip body)
    const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
    // body
    for (items[2..]) |form| {
        try self.compileForm(form);
    }
    // jump past nil
    const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);
    const else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_to_else_pc].operand = else_pc;
    _ = try self.program.emit0(self.allocator, .push_nil);
    const past_else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
}

/// Compile (when-first [sym coll] body...)
/// Desugars to: (let [sym (first coll)] (if sym (do body...) nil))
pub fn compileWhenFirst(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const binding = items[1];
    const body = items[2..];
    // binding is a vector/list [sym coll]
    const bind_items: []const Value = switch (std.meta.activeTag(binding)) {
        .vector => binding.vector.items.items,
        .list => binding.list.items.items,
        else => { _ = try self.program.emit0(self.allocator, .push_nil); return; },
    };
    if (bind_items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const sym = bind_items[0];
    const coll = bind_items[1];

    // Compile (first coll) and store in sym
    try self.compileForm(coll);
    _ = try self.program.emit0(self.allocator, .first);
    const sym_idx = try self.program.addSymbol(self.allocator, sym.symbol.slice());
    _ = try self.program.emit(self.allocator, .store_var, sym_idx);

    // if sym then body else nil
    _ = try self.program.emit(self.allocator, .load_var, sym_idx);
    const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
    for (body) |form| {
        try self.compileForm(form);
    }
    const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);
    const else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_to_else_pc].operand = else_pc;
    _ = try self.program.emit0(self.allocator, .push_nil);
    const past_else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
}

/// Compile (loop [bindings] body...).
pub fn compileLoop(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }

    const bindings = items[1];
    const body = items[2..];

    const bind_items: []const Value = switch (std.meta.activeTag(bindings)) {
        .list => bindings.list.items.items,
        .vector => bindings.vector.items.items,
        else => {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        },
    };

    // Collect binding pairs, skipping type hints (symbols starting with ^).
    // The parser does not attach type hints as metadata, so ^long i 0 becomes
    // three elements [^long, i, 0] instead of [i-with-meta, 0].
    var binding_pairs: std.ArrayListUnmanaged(struct { sym: []const u8, val: Value }) = .empty;
    defer binding_pairs.deinit(self.allocator);

    var i: usize = 0;
    while (i < bind_items.len) {
        const elem = bind_items[i];
        // Skip type hint symbols (starting with ^)
        if (std.meta.activeTag(elem) == .symbol) {
            const hint = elem.symbol.slice();
            if (hint.len > 0 and hint[0] == '^') {
                i += 1;
                continue;
            }
        }
        // This should be a symbol (binding name)
        if (std.meta.activeTag(elem) != .symbol) {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        }
        if (i + 1 >= bind_items.len) {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        }
        const sym_name = elem.symbol.slice();
        const val = bind_items[i + 1];
        try binding_pairs.append(self.allocator, .{ .sym = sym_name, .val = val });
        i += 2;
    }

    var sym_indices: []usize = try self.allocator.alloc(usize, binding_pairs.items.len);
    var bi: usize = 0;
    while (bi < binding_pairs.items.len) : (bi += 1) {
        const pair = binding_pairs.items[bi];
        sym_indices[bi] = try self.program.addSymbol(self.allocator, pair.sym);
        try self.compileForm(pair.val);
        _ = try self.program.emit(self.allocator, .store_var, sym_indices[bi]);
    }

    const loop_info_idx = try self.program.addLoopInfo(self.allocator, self.program.instructions.items.len + 1, sym_indices);
    _ = try self.program.emit(self.allocator, .loop_start, loop_info_idx);

    for (body) |form| {
        try self.compileForm(form);
    }
}

/// Compile (recur val1 val2 ...).
pub fn compileRecur(self: *Compiler, items: []const Value) anyerror!void {
    const args = items[1..];
    var i: usize = args.len;
    while (i > 0) : (i -= 1) {
        try self.compileForm(args[i - 1]);
    }
    _ = try self.program.emit0(self.allocator, .recur);
}

/// Compile (case expr test1 result1 test2 result2 ... :else default).
pub fn compileCase(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }

    const expr_form = items[1];
    const clauses = items[2..];

    try self.compileForm(expr_form);
    const expr_tmp_idx = try self.program.addSymbol(self.allocator, "__case_expr");
    _ = try self.program.emit(self.allocator, .store_var, expr_tmp_idx);

    var clause_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer clause_starts.deinit(self.allocator);
    var jump_nil_pcs: std.ArrayListUnmanaged(usize) = .empty;
    defer jump_nil_pcs.deinit(self.allocator);
    var jump_end_pcs: std.ArrayListUnmanaged(usize) = .empty;
    defer jump_end_pcs.deinit(self.allocator);

    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const test_form = clauses[i];
        const is_else = std.meta.activeTag(test_form) == .keyword and
            std.mem.eql(u8, test_form.keyword.slice(), "else");

        try clause_starts.append(self.allocator, self.program.instructions.items.len);

        if (is_else) {
            if (i + 1 < clauses.len) {
                try self.compileForm(clauses[i + 1]);
            }
        } else {
            try self.compileForm(test_form);
            _ = try self.program.emit(self.allocator, .load_var, expr_tmp_idx);
            _ = try self.program.emit0(self.allocator, .eq);
            const jnil_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
            try jump_nil_pcs.append(self.allocator, jnil_pc);
            if (i + 1 < clauses.len) {
                try self.compileForm(clauses[i + 1]);
            }
            const jump_pc = try self.program.emit(self.allocator, .jump, 0);
            try jump_end_pcs.append(self.allocator, jump_pc);
        }
    }

    const has_else = clauses.len >= 2 and
        std.meta.activeTag(clauses[clauses.len - 2]) == .keyword and
        std.mem.eql(u8, clauses[clauses.len - 2].keyword.slice(), "else");
    const nil_pc: ?usize = if (!has_else) blk: {
        const pc = self.program.instructions.items.len;
        _ = try self.program.emit0(self.allocator, .push_nil);
        break :blk pc;
    } else null;

    const end_pc = self.program.instructions.items.len;
    var j: usize = 0;
    while (j < jump_nil_pcs.items.len) : (j += 1) {
        var target: usize = end_pc;
        if (j + 1 < clause_starts.items.len) {
            target = clause_starts.items[j + 1];
        } else if (nil_pc) |np| {
            target = np;
        }
        self.program.instructions.items[jump_nil_pcs.items[j]].operand = target;
    }
    for (jump_end_pcs.items) |pc| {
        self.program.instructions.items[pc].operand = end_pc;
    }
}

/// Compile (if-let [sym test] then else?)
/// Desugars to: (let [sym test] (if sym then else?))
/// Uses truthiness check (nil and false are both falsy).
pub fn compileIfLet(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const binding = items[1];
    const then_form = items[2];
    const else_form = if (items.len >= 4) items[3] else null;

    const bind_items: []const Value = switch (std.meta.activeTag(binding)) {
        .vector => binding.vector.items.items,
        .list => binding.list.items.items,
        else => { _ = try self.program.emit0(self.allocator, .push_nil); return; },
    };
    if (bind_items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const sym = bind_items[0];
    const test_form = bind_items[1];

    // Compile test value and store in sym
    try self.compileForm(test_form);
    const sym_idx = try self.program.addSymbol(self.allocator, sym.symbol.slice());
    _ = try self.program.emit(self.allocator, .store_var, sym_idx);

    // if sym then then_form else else_form
    _ = try self.program.emit(self.allocator, .load_var, sym_idx);
    const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
    try self.compileForm(then_form);
    const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);
    const else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_to_else_pc].operand = else_pc;
    if (else_form) |ef| {
        try self.compileForm(ef);
    } else {
        _ = try self.program.emit0(self.allocator, .push_nil);
    }
    const past_else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
}

/// Compile (when-let [sym test] body...)
/// Desugars to: (if-let [sym test] (do body...))
/// Uses truthiness check (nil and false are both falsy).
pub fn compileWhenLet(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const binding = items[1];
    const body = items[2..];

    const bind_items: []const Value = switch (std.meta.activeTag(binding)) {
        .vector => binding.vector.items.items,
        .list => binding.list.items.items,
        else => { _ = try self.program.emit0(self.allocator, .push_nil); return; },
    };
    if (bind_items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const sym = bind_items[0];
    const test_form = bind_items[1];

    // Compile test value and store in sym
    try self.compileForm(test_form);
    const sym_idx = try self.program.addSymbol(self.allocator, sym.symbol.slice());
    _ = try self.program.emit(self.allocator, .store_var, sym_idx);

    // if sym then body else nil
    _ = try self.program.emit(self.allocator, .load_var, sym_idx);
    const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_nil, 0);
    for (body) |form| {
        try self.compileForm(form);
    }
    const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);
    const else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_to_else_pc].operand = else_pc;
    _ = try self.program.emit0(self.allocator, .push_nil);
    const past_else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
}

/// Compile (when-some [sym test] body...)
/// Like when-let but checks for nil only (false is considered truthy).
/// Desugars to: (let [sym test] (if (not (nil? sym)) (do body...)))
pub fn compileWhenSome(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const binding = items[1];
    const body = items[2..];

    const bind_items: []const Value = switch (std.meta.activeTag(binding)) {
        .vector => binding.vector.items.items,
        .list => binding.list.items.items,
        else => { _ = try self.program.emit0(self.allocator, .push_nil); return; },
    };
    if (bind_items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    const sym = bind_items[0];
    const test_form = bind_items[1];

    // Compile test value and store in sym
    try self.compileForm(test_form);
    const sym_idx = try self.program.addSymbol(self.allocator, sym.symbol.slice());
    _ = try self.program.emit(self.allocator, .store_var, sym_idx);

    // if (not (nil? sym)) then body else nil
    // Load sym, check is_nil, jump if nil
    _ = try self.program.emit(self.allocator, .load_var, sym_idx);
    _ = try self.program.emit0(self.allocator, .is_nil);
    const jump_to_else_pc = try self.program.emit(self.allocator, .jump_if_not_nil, 0);
    for (body) |form| {
        try self.compileForm(form);
    }
    const jump_past_else_pc = try self.program.emit(self.allocator, .jump, 0);
    const else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_to_else_pc].operand = else_pc;
    _ = try self.program.emit0(self.allocator, .push_nil);
    const past_else_pc = self.program.instructions.items.len;
    self.program.instructions.items[jump_past_else_pc].operand = past_else_pc;
}

/// Compile (letfn [(f [params] body...) (g [params] body...)] usage...).
pub fn compileLetFn(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 3) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }

    const bindings = items[1];
    const body = items[2..];

    const bind_items: []const Value = switch (std.meta.activeTag(bindings)) {
        .list => bindings.list.items.items,
        .vector => bindings.vector.items.items,
        else => {
            _ = try self.program.emit0(self.allocator, .push_nil);
            return;
        },
    };

    for (bind_items) |binding| {
        if (std.meta.activeTag(binding) != .list) continue;
        const b = binding.list;
        if (b.items.items.len < 2) continue;

        const fname = b.items.items[0];
        if (std.meta.activeTag(fname) != .symbol) continue;

        var fn_form: list.List = .empty;
        errdefer fn_form.deinit(self.allocator);
        try fn_form.append(self.allocator, try vm.symValue(self.allocator, "fn"));
        try fn_form.append(self.allocator, try vm.shallowClone(&fname, self.allocator));
        var arity_form: list.List = .empty;
        errdefer arity_form.deinit(self.allocator);
        for (b.items.items[1..]) |form_item| {
            try arity_form.append(self.allocator, try vm.shallowClone(&form_item, self.allocator));
        }
        try fn_form.append(self.allocator, try vm.listValue(self.allocator, arity_form));

        try self.compileForm(try vm.listValue(self.allocator, fn_form));

        const sym_idx = try self.program.addSymbol(self.allocator, fname.symbol.slice());
        _ = try self.program.emit(self.allocator, .store_var, sym_idx);
    }

    for (body) |form| {
        try self.compileForm(form);
    }
}

// Forward reference to compile function (defined in compiler.zig)

// ============================================================
// Phase 10: lazy-seq
// ============================================================

/// Compile (lazy-seq body...)
/// Creates a lazy-seq whose thunk body is compiled as bytecode.
/// When forced, the bytecode is executed in the captured environment.
pub fn compileLazySeq(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }

    // Build a "do" body from the lazy-seq body forms
    var body_list: list.List = .empty;
    errdefer body_list.deinit(self.allocator);
    try body_list.append(self.allocator, try vm.symValue(self.allocator, "do"));
    for (items[1..]) |form| {
        try body_list.append(self.allocator, try vm.shallowClone(&form, self.allocator));
    }

    // Compile the body as bytecode
    const bc_prog = try self.compile_fn(
        self.allocator,
        body_list,
        "<lazy-seq>",
        self.env,
        null,
    );

    // Add to the lazy_seq_bytecodes pool
    const bc_idx = try self.program.addLazySeqBytecode(self.allocator, bc_prog);

    // Emit make_lazy_seq with the bytecode index
    // At runtime, this creates a LazySeqThunk with the bytecode and current env
    _ = try self.program.emit(self.allocator, .make_lazy_seq, bc_idx);
}

/// Compile (-> expr form1 form2 ...)
/// Desugars at compile time: each form gets the result of previous as first arg.
/// (-> x (f a) (g b)) => (g (f x a) b)
pub fn compileThreadingRight(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }

    // Use a temp variable to hold the current threaded value.
    // Build synthetic call lists with correct arg order and use skip_special_ops
    // to avoid the bytecode compiler reordering args for map/reduce/etc.
    const tmp_idx = try self.program.addSymbol(self.allocator, "__thread_right_tmp");

    // Compile the initial expression and store in temp
    try self.compileForm(items[1]);
    _ = try self.program.emit(self.allocator, .store_var, tmp_idx);

    // Temporarily disable special operator compilation
    const prev_skip = self.skip_special_ops;
    self.skip_special_ops = true;

    var i: usize = 2;
    while (i < items.len) : (i += 1) {
        const form = items[i];

        // Build synthetic call list: (fn __thread_right_tmp arg1 arg2 ...)
        var call_list: list.List = .empty;
        errdefer call_list.deinit(self.allocator);

        if (std.meta.activeTag(form) == .list and form.list.items.items.len > 0) {
            const lst = form.list;
            const first = lst.items.items[0];
            const rest = lst.items.items[1..];

            try call_list.append(self.allocator, try vm.shallowClone(&first, self.allocator));
            // Insert the temp symbol as first argument
            try call_list.append(self.allocator, try vm.symValue(self.allocator, "__thread_right_tmp"));
            for (rest) |arg| {
                try call_list.append(self.allocator, try vm.shallowClone(&arg, self.allocator));
            }
        } else {
            // Not a list — treat as function: (form prev-result)
            try call_list.append(self.allocator, try vm.shallowClone(&form, self.allocator));
            try call_list.append(self.allocator, try vm.symValue(self.allocator, "__thread_right_tmp"));
        }

        // Compile the synthetic call (skip_special_ops ensures correct arg order)
        try self.compileForm(try vm.listValue(self.allocator, call_list));

        // Store result back in temp for next iteration
        _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
    }

    self.skip_special_ops = prev_skip;

    // Load final result from temp
    _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
}

/// Compile (->> expr form1 form2 ...)
/// Desugars at compile time: each form gets the result of previous as LAST arg.
/// (->> x (f a) (g b)) => (g b (f a x))
pub fn compileThreadingLeft(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }

    // Use a temp variable to hold the current threaded value.
    // Build synthetic call lists with correct arg order and use skip_special_ops
    // to avoid the bytecode compiler reordering args for map/reduce/etc.
    const tmp_idx = try self.program.addSymbol(self.allocator, "__thread_left_tmp");

    // Compile the initial expression and store in temp
    try self.compileForm(items[1]);
    _ = try self.program.emit(self.allocator, .store_var, tmp_idx);

    // Temporarily disable special operator compilation
    const prev_skip = self.skip_special_ops;
    self.skip_special_ops = true;

    var i: usize = 2;
    while (i < items.len) : (i += 1) {
        const form = items[i];

        // Build synthetic call list: (fn arg1 arg2 ... __thread_left_tmp)
        var call_list: list.List = .empty;
        errdefer call_list.deinit(self.allocator);

        if (std.meta.activeTag(form) == .list and form.list.items.items.len > 0) {
            const lst = form.list;
            const first = lst.items.items[0];
            const rest = lst.items.items[1..];

            try call_list.append(self.allocator, try vm.shallowClone(&first, self.allocator));
            for (rest) |arg| {
                try call_list.append(self.allocator, try vm.shallowClone(&arg, self.allocator));
            }
        } else {
            // Not a list — treat as function: (form prev-result)
            try call_list.append(self.allocator, try vm.shallowClone(&form, self.allocator));
        }

        // Add the temp symbol as last argument
        try call_list.append(self.allocator, try vm.symValue(self.allocator, "__thread_left_tmp"));

        // Compile the synthetic call (skip_special_ops ensures correct arg order)
        try self.compileForm(try vm.listValue(self.allocator, call_list));

        // Store result back in temp for next iteration
        _ = try self.program.emit(self.allocator, .store_var, tmp_idx);
    }

    self.skip_special_ops = prev_skip;

    // Load final result from temp
    _ = try self.program.emit(self.allocator, .load_var, tmp_idx);
}

// ============================================================
// Phase 9: Quasiquote
// ============================================================

/// Compile (quasiquote form) — the backtick operator.
/// `x => quote x (constant)
/// `(~x) => compile x (unquote)
/// `(~@x) => compile x (unquote-splicing)
/// `(a b c) => (list a b c) with unquote handling
pub fn compileQuasiquote(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len < 2) {
        _ = try self.program.emit0(self.allocator, .push_nil);
        return;
    }
    try compileQuasiquoteForm(self, items[1]);
}

/// Compile a single quasiquote form.
fn compileQuasiquoteForm(self: *Compiler, form: Value) anyerror!void {
    switch (form) {
        .list => {
            const lst_items = form.list.items.items;
            if (lst_items.len == 0) {
                _ = try self.program.emit(self.allocator, .list_n, 0);
                return;
            }
            // Check for nested quasiquote: (quasiquote x)
            // e.g. `(~`(a b)) — the inner `(a b)` is a quasiquote
            if (std.meta.activeTag(lst_items[0]) == .symbol and
                std.mem.eql(u8, lst_items[0].symbol.slice(), "quasiquote"))
            {
                if (lst_items.len >= 2) {
                    try compileQuasiquoteForm(self, lst_items[1]);
                    return;
                }
            }
            // Check for unquote-splicing at top level: (~@ x)
            const first = lst_items[0];
            if (std.meta.activeTag(first) == .symbol and
                std.mem.eql(u8, first.symbol.slice(), "unquote-splicing"))
            {
                if (lst_items.len >= 2) {
                    try self.compileForm(lst_items[1]);
                    return;
                }
            }
            // Regular list — process elements
            try compileQuasiquoteList(self, lst_items);
        },
        .vector => {
            // Compile vector as a vector, handling ~ and ~@
            try compileQuasiquoteVector(self, form.vector.items.items);
        },
        .map => {
            // Compile map as (hash-map ...)
            const n = form.map.entries.items.len;
            for (form.map.entries.items) |entry| {
                try compileQuasiquoteForm(self, entry.key);
                try compileQuasiquoteForm(self, entry.value);
            }
            _ = try self.program.emit(self.allocator, .map_n, n);
        },
        else => {
            // Literal — push as constant
            const idx = try self.program.addConstant(self.allocator, try vm.shallowClone(&form, self.allocator));
            _ = try self.program.emit(self.allocator, .push_const, idx);
        },
    }
}

/// Check if a list form is (unquote-splicing x).
fn isUnquoteSplicing(form: Value) bool {
    if (std.meta.activeTag(form) != .list) return false;
    const lst_items = form.list.items.items;
    if (lst_items.len < 2) return false;
    if (std.meta.activeTag(lst_items[0]) != .symbol) return false;
    return std.mem.eql(u8, lst_items[0].symbol.slice(), "unquote-splicing");
}

/// Check if a list form is (unquote x).
fn isUnquote(form: Value) bool {
    if (std.meta.activeTag(form) != .list) return false;
    const lst_items = form.list.items.items;
    if (lst_items.len < 2) return false;
    if (std.meta.activeTag(lst_items[0]) != .symbol) return false;
    return std.mem.eql(u8, lst_items[0].symbol.slice(), "unquote");
}

/// Compile a quasiquote list's elements, handling ~ and ~@.
/// Uses concat for splicing: (concat (list 1 2) spliced (list 3))
fn compileQuasiquoteList(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len == 0) {
        _ = try self.program.emit(self.allocator, .list_n, 0);
        return;
    }

    // Check if any element is unquote-splicing
    const has_splice = blk: {
        for (items) |item| {
            if (isUnquoteSplicing(item)) break :blk true;
        }
        break :blk false;
    };

    if (!has_splice) {
        // No splicing — simple case, compile each element and build list
        for (items) |item| {
            if (isUnquote(item) and item.list.items.items.len >= 2) {
                // ~expr — compile expr directly
                try self.compileForm(item.list.items.items[1]);
            } else {
                try compileQuasiquoteForm(self, item);
            }
        }
        _ = try self.program.emit(self.allocator, .list_n, items.len);
        return;
    }

    // Has splicing — use concat approach.
    // Accumulate non-splice elements into a list, then concat with splice results.
    var current_list_count: usize = 0;
    var concat_count: usize = 0;

    for (items) |item| {
        if (isUnquoteSplicing(item)) {
            // Emit accumulated list if any
            if (current_list_count > 0) {
                _ = try self.program.emit(self.allocator, .list_n, current_list_count);
                concat_count += 1;
                current_list_count = 0;
            }
            // Compile the splice expression (should produce a seq)
            if (item.list.items.items.len >= 2) {
                try self.compileForm(item.list.items.items[1]);
            } else {
                _ = try self.program.emit0(self.allocator, .push_nil);
            }
            concat_count += 1;
        } else {
            // Regular element or unquote
            if (isUnquote(item) and item.list.items.items.len >= 2) {
                try self.compileForm(item.list.items.items[1]);
            } else {
                try compileQuasiquoteForm(self, item);
            }
            current_list_count += 1;
        }
    }

    // Emit remaining accumulated list
    if (current_list_count > 0) {
        _ = try self.program.emit(self.allocator, .list_n, current_list_count);
        concat_count += 1;
    }

    // If we had any splicing, concat all pieces together
    if (concat_count > 0) {
        _ = try self.program.emit(self.allocator, .concat_n, concat_count);
    }
}

/// Compile a quasiquote vector's elements, handling ~ and ~@.
/// Produces a vector (not a list) when no splicing.
/// With splicing, produces a vector from the concatenated result.
fn compileQuasiquoteVector(self: *Compiler, items: []const Value) anyerror!void {
    if (items.len == 0) {
        _ = try self.program.emit(self.allocator, .vector_n, 0);
        return;
    }

    // Check if any element is unquote-splicing
    const has_splice = blk: {
        for (items) |item| {
            if (isUnquoteSplicing(item)) break :blk true;
        }
        break :blk false;
    };

    if (!has_splice) {
        // No splicing — compile each element and build vector
        for (items) |item| {
            if (isUnquote(item) and item.list.items.items.len >= 2) {
                try self.compileForm(item.list.items.items[1]);
            } else {
                try compileQuasiquoteForm(self, item);
            }
        }
        _ = try self.program.emit(self.allocator, .vector_n, items.len);
        return;
    }

    // Has splicing — use concat then vec approach.
    // First concat all pieces, then convert to vector.
    var current_list_count: usize = 0;
    var concat_count: usize = 0;

    for (items) |item| {
        if (isUnquoteSplicing(item)) {
            if (current_list_count > 0) {
                _ = try self.program.emit(self.allocator, .list_n, current_list_count);
                concat_count += 1;
                current_list_count = 0;
            }
            if (item.list.items.items.len >= 2) {
                try self.compileForm(item.list.items.items[1]);
            } else {
                _ = try self.program.emit0(self.allocator, .push_nil);
            }
            concat_count += 1;
        } else {
            if (isUnquote(item) and item.list.items.items.len >= 2) {
                try self.compileForm(item.list.items.items[1]);
            } else {
                try compileQuasiquoteForm(self, item);
            }
            current_list_count += 1;
        }
    }

    if (current_list_count > 0) {
        _ = try self.program.emit(self.allocator, .list_n, current_list_count);
        concat_count += 1;
    }

    if (concat_count > 0) {
        _ = try self.program.emit(self.allocator, .concat_n, concat_count);
    }

    // Convert the resulting sequence to a vector
    _ = try self.program.emit0(self.allocator, .vec);
}

// Forward reference to compile function (defined in compiler.zig)
