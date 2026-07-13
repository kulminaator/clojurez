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
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        const val = bind_items[i + 1];
        try self.compileForm(val);
        if (std.meta.activeTag(sym) == .symbol) {
            const sym_idx = try self.program.addSymbol(self.allocator, sym.symbol);
            _ = try self.program.emit(self.allocator, .store_var, sym_idx);
        }
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
        fn_name = try self.allocator.dupe(u8, items[idx].symbol);
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
            std.mem.eql(u8, cond_test.keyword, "else");
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
        const target = clause_starts.items[j + 1];
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

    const binding_count = bind_items.len / 2;
    var sym_indices: []usize = try self.allocator.alloc(usize, binding_count);

    var i: usize = 0;
    while (i < bind_items.len) : (i += 2) {
        const sym = bind_items[i];
        const val = bind_items[i + 1];
        if (std.meta.activeTag(sym) == .symbol) {
            sym_indices[i / 2] = try self.program.addSymbol(self.allocator, sym.symbol);
        }
        try self.compileForm(val);
        if (std.meta.activeTag(sym) == .symbol) {
            _ = try self.program.emit(self.allocator, .store_var, sym_indices[i / 2]);
        }
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
            std.mem.eql(u8, test_form.keyword, "else");

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
        std.mem.eql(u8, clauses[clauses.len - 2].keyword, "else");
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

        const sym_idx = try self.program.addSymbol(self.allocator, fname.symbol);
        _ = try self.program.emit(self.allocator, .store_var, sym_idx);
    }

    for (body) |form| {
        try self.compileForm(form);
    }
}

// Forward reference to compile function (defined in compiler.zig)
