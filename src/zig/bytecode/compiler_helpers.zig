// Compiler helper functions: form checking, operator recognition, param parsing.
const std = @import("std");
const vm = @import("../value.zig");
const Value = vm.Value;
const list = @import("../list.zig");
const vec = @import("../vector.zig");

const Allocator = std.mem.Allocator;
const bc = @import("instructions.zig");

/// Check if a value is a "simple" form that the bytecode compiler can handle
/// as an argument to arithmetic/comparison opcodes. Simple forms are literals,
/// symbols, vectors of simple forms, and maps of simple forms. Lists (function
/// calls) are NOT simple.
pub fn isSimpleBytecodeForm(form: Value) bool {
    return switch (form) {
        .nil, .bool, .integer, .float, .string, .keyword, .symbol,
        .bigint, .ratio, .decimal, .regex, .character => true,
        .function, .builtin_fn, .atom, .lazy_seq, .cons, .reduced,
        .future, .promise, .record, .chunk, .chunked_cons, .wrapped, .exception,
        .ref, .multimethod => true,
        .list => false,
        .vector => {
            for (form.vector.items.items) |item| {
                if (!isSimpleBytecodeForm(item)) return false;
            }
            return true;
        },
        .map => {
            for (form.map.entries.items) |entry| {
                if (!isSimpleBytecodeForm(entry.key)) return false;
                if (!isSimpleBytecodeForm(entry.value)) return false;
            }
            return true;
        },
        .set => {
            for (form.set.items.items) |item| {
                if (!isSimpleBytecodeForm(item)) return false;
            }
            return true;
        },
        .queue => {
            for (form.queue.items.items) |item| {
                if (!isSimpleBytecodeForm(item)) return false;
            }
            return true;
        },
    };
}

/// Check if a form is safe to compile as an argument to a recognized bytecode
/// operator. Unlike isSimpleBytecodeForm, this allows nested calls to recognized
/// bytecode operators and special forms. This enables (first (rest xs)) to compile
/// because both first and rest are recognized operators.
pub fn isSafeBytecodeArg(form: Value) bool {
    return switch (form) {
        .nil, .bool, .integer, .float, .string, .keyword, .symbol,
        .bigint, .ratio, .decimal, .regex, .character => true,
        .function, .builtin_fn, .atom, .lazy_seq, .cons, .reduced,
        .future, .promise, .record, .chunk, .chunked_cons, .wrapped, .exception,
        .ref, .multimethod => true,
        .list => {
            const lst_items = form.list.items.items;
            if (lst_items.len == 0) return true;
            if (std.meta.activeTag(lst_items[0]) == .symbol) {
                const op = lst_items[0].symbol;
                if (isBytecodeOptimizableOperator(op) or isBytecodeSpecialForm(op)) {
                    for (lst_items) |item| {
                        if (!isSafeBytecodeArg(item)) return false;
                    }
                    return true;
                }
            }
            return false;
        },
        .vector => {
            for (form.vector.items.items) |item| {
                if (!isSafeBytecodeArg(item)) return false;
            }
            return true;
        },
        .map => {
            for (form.map.entries.items) |entry| {
                if (!isSafeBytecodeArg(entry.key)) return false;
                if (!isSafeBytecodeArg(entry.value)) return false;
            }
            return true;
        },
        .set => {
            for (form.set.items.items) |item| {
                if (!isSafeBytecodeArg(item)) return false;
            }
            return true;
        },
        .queue => {
            for (form.queue.items.items) |item| {
                if (!isSafeBytecodeArg(item)) return false;
            }
            return true;
        },
    };
}

/// Check if a symbol is a known arithmetic/comparison operator that the
/// bytecode compiler can emit as direct opcodes (not function calls).
pub fn isBytecodeOptimizableOperator(sym: []const u8) bool {
    if (std.mem.eql(u8, sym, "+") or
        std.mem.eql(u8, sym, "-") or
        std.mem.eql(u8, sym, "*") or
        std.mem.eql(u8, sym, "/") or
        std.mem.eql(u8, sym, "rem") or
        std.mem.eql(u8, sym, "quot") or
        std.mem.eql(u8, sym, "mod"))
    {
        return true;
    }
    if (std.mem.eql(u8, sym, "=") or
        std.mem.eql(u8, sym, "!=") or
        std.mem.eql(u8, sym, "not=") or
        std.mem.eql(u8, sym, "<") or
        std.mem.eql(u8, sym, ">") or
        std.mem.eql(u8, sym, "<=") or
        std.mem.eql(u8, sym, ">="))
    {
        return true;
    }
    if (std.mem.eql(u8, sym, "not")) return true;
    if (std.mem.eql(u8, sym, "nth") or
        std.mem.eql(u8, sym, "get") or
        std.mem.eql(u8, sym, "assoc") or
        std.mem.eql(u8, sym, "conj") or
        std.mem.eql(u8, sym, "count") or
        std.mem.eql(u8, sym, "first") or
        std.mem.eql(u8, sym, "rest"))
    {
        return true;
    }
    if (std.mem.eql(u8, sym, "compare")) return true;
    if (std.mem.eql(u8, sym, "seq") or
        std.mem.eql(u8, sym, "cons") or
        std.mem.eql(u8, sym, "list"))
    {
        return true;
    }
    if (std.mem.eql(u8, sym, "nil?")) return true;
    // Type predicates
    if (std.mem.eql(u8, sym, "number?") or
        std.mem.eql(u8, sym, "int?") or
        std.mem.eql(u8, sym, "float?") or
        std.mem.eql(u8, sym, "double?") or
        std.mem.eql(u8, sym, "string?") or
        std.mem.eql(u8, sym, "boolean?") or
        std.mem.eql(u8, sym, "list?") or
        std.mem.eql(u8, sym, "vector?") or
        std.mem.eql(u8, sym, "map?") or
        std.mem.eql(u8, sym, "set?") or
        std.mem.eql(u8, sym, "symbol?") or
        std.mem.eql(u8, sym, "keyword?"))
    {
        return true;
    }
    // Collection predicates
    if (std.mem.eql(u8, sym, "empty?") or
        std.mem.eql(u8, sym, "not-empty"))
    {
        return true;
    }
    // Collection constructors
    if (std.mem.eql(u8, sym, "empty"))
    {
        return true;
    }
    // Collection containment
    if (std.mem.eql(u8, sym, "contains?"))
    {
        return true;
    }
    // String concatenation
    if (std.mem.eql(u8, sym, "str"))
    {
        return true;
    }
    // Shorthand operators (compile to opcode sequences)
    if (std.mem.eql(u8, sym, "inc") or
        std.mem.eql(u8, sym, "dec") or
        std.mem.eql(u8, sym, "even?") or
        std.mem.eql(u8, sym, "odd?") or
        std.mem.eql(u8, sym, "abs") or
        std.mem.eql(u8, sym, "identity") or
        std.mem.eql(u8, sym, "boolean"))
    {
        return true;
    }
    // Phase 12: peek/pop
    if (std.mem.eql(u8, sym, "peek") or
        std.mem.eql(u8, sym, "pop"))
    {
        return true;
    }
    // Phase 13: reduced ops
    if (std.mem.eql(u8, sym, "reduced") or
        std.mem.eql(u8, sym, "reduced?") or
        std.mem.eql(u8, sym, "unreduced"))
    {
        return true;
    }
    // Phase 14: meta ops
    if (std.mem.eql(u8, sym, "meta") or
        std.mem.eql(u8, sym, "with-meta"))
    {
        return true;
    }
    // Phase 15: keyword/symbol constructors
    if (std.mem.eql(u8, sym, "keyword") or
        std.mem.eql(u8, sym, "symbol"))
    {
        return true;
    }
    // Phase 4: range and vec
    if (std.mem.eql(u8, sym, "range") or
        std.mem.eql(u8, sym, "vec"))
    {
        return true;
    }
    // Phase 5: sort and merge
    if (std.mem.eql(u8, sym, "sort") or
        std.mem.eql(u8, sym, "sort-by") or
        std.mem.eql(u8, sym, "merge"))
    {
        return true;
    }
    // Phase 6: map and reduce
    if (std.mem.eql(u8, sym, "map") or
        std.mem.eql(u8, sym, "reduce"))
    {
        return true;
    }
    // Phase 7: apply
    if (std.mem.eql(u8, sym, "apply"))
    {
        return true;
    }
    return false;
}

/// Check if a symbol is a special form that the bytecode compiler handles.
pub fn isBytecodeSpecialForm(sym: []const u8) bool {
    if (std.mem.eql(u8, sym, "quote") or
        std.mem.eql(u8, sym, "if") or
        std.mem.eql(u8, sym, "do") or
        std.mem.eql(u8, sym, "let") or
        std.mem.eql(u8, sym, "var") or
        std.mem.eql(u8, sym, "deref") or
        std.mem.eql(u8, sym, "@") or
        std.mem.eql(u8, sym, "set!") or
        std.mem.eql(u8, sym, "fn") or
        std.mem.eql(u8, sym, "and") or
        std.mem.eql(u8, sym, "or") or
        std.mem.eql(u8, sym, "cond") or
        std.mem.eql(u8, sym, "when") or
        std.mem.eql(u8, sym, "when-not") or
        std.mem.eql(u8, sym, "when-first") or
        std.mem.eql(u8, sym, "if-let") or
        std.mem.eql(u8, sym, "when-let") or
        std.mem.eql(u8, sym, "when-some") or
        std.mem.eql(u8, sym, "loop") or
        std.mem.eql(u8, sym, "recur") or
        std.mem.eql(u8, sym, "case") or
        std.mem.eql(u8, sym, "letfn") or
        std.mem.eql(u8, sym, "->") or
        std.mem.eql(u8, sym, "->>"))
    {
        return true;
    }
    return false;
}

/// Check if a list contains any REAL function calls (not arithmetic/comparison).
/// fn_name is the enclosing function name — self-calls are not "real" function calls.
pub fn containsRealFunctionCallsInList(l: list.List, fn_name: ?[]const u8) bool {
    return containsRealFunctionCallsInItems(l.items, fn_name);
}

fn containsRealFunctionCallsInItems(items: []const Value, fn_name: ?[]const u8) bool {
    for (items) |item| {
        if (containsRealFunctionCallsHelper(item, fn_name)) return true;
    }
    return false;
}

fn containsRealFunctionCallsHelper(form: Value, fn_name: ?[]const u8) bool {
    switch (form) {
        .list => {
            const lst_items = form.list.items.items;
            if (lst_items.len == 0) return false;
            if (std.meta.activeTag(lst_items[0]) == .symbol) {
                if (isBytecodeOptimizableOperator(lst_items[0].symbol)) {
                    for (lst_items[1..]) |arg| {
                        if (containsRealFunctionCallsHelper(arg, fn_name)) return true;
                    }
                    return false;
                }
                if (isBytecodeSpecialForm(lst_items[0].symbol)) {
                    for (lst_items[1..]) |arg| {
                        if (containsRealFunctionCallsHelper(arg, fn_name)) return true;
                    }
                    return false;
                }
                // Self-recursive call — not a "real" function call
                if (fn_name) |fname| {
                    if (std.mem.eql(u8, lst_items[0].symbol, fname)) {
                        for (lst_items[1..]) |arg| {
                            if (containsRealFunctionCallsHelper(arg, fn_name)) return true;
                        }
                        return false;
                    }
                }
            }
            return true;
        },
        .vector => {
            for (form.vector.items.items) |item| {
                if (containsRealFunctionCallsHelper(item, fn_name)) return true;
            }
            return false;
        },
        .map => {
            for (form.map.entries.items) |entry| {
                if (containsRealFunctionCallsHelper(entry.key, fn_name)) return true;
                if (containsRealFunctionCallsHelper(entry.value, fn_name)) return true;
            }
            return false;
        },
        .cons => {
            if (containsRealFunctionCallsHelper(form.cons.head, fn_name)) return true;
            if (containsRealFunctionCallsHelper(form.cons.tail, fn_name)) return true;
            return false;
        },
        else => return false,
    }
}

/// Check if a params list contains destructuring patterns (vectors/lists).
pub fn containsDestructuring(params: list.List) bool {
    for (params.items) |param| {
        switch (std.meta.activeTag(param)) {
            .vector, .list => return true,
            else => {},
        }
    }
    return false;
}

/// Check if a list contains any special forms that the bytecode compiler
/// does not yet handle.
pub fn containsUnhandledSpecialFormInList(l: list.List) bool {
    return containsUnhandledSpecialFormInItems(l.items);
}

fn containsUnhandledSpecialFormInItems(items: []const Value) bool {
    for (items) |item| {
        if (containsUnhandledSpecialFormHelper(item)) return true;
    }
    return false;
}

pub fn containsUnhandledSpecialFormHelper(form: Value) bool {
    switch (form) {
        .list => {
            const lst_items = form.list.items.items;
            if (lst_items.len == 0) return false;
            if (std.meta.activeTag(lst_items[0]) == .symbol) {
                const sym = lst_items[0].symbol;
                if (std.mem.eql(u8, sym, "quasiquote") or
                    std.mem.eql(u8, sym, "binding") or
                    std.mem.eql(u8, sym, "lazy-seq") or
                    std.mem.eql(u8, sym, "dorun") or
                    std.mem.eql(u8, sym, "doall") or
                    std.mem.eql(u8, sym, "cond->") or
                    std.mem.eql(u8, sym, "cond->>"))
                {
                    return true;
                }
            }
            for (lst_items) |item| {
                if (containsUnhandledSpecialFormHelper(item)) return true;
            }
            return false;
        },
        .vector => {
            for (form.vector.items.items) |item| {
                if (containsUnhandledSpecialFormHelper(item)) return true;
            }
            return false;
        },
        .map => {
            for (form.map.entries.items) |entry| {
                if (containsUnhandledSpecialFormHelper(entry.key)) return true;
                if (containsUnhandledSpecialFormHelper(entry.value)) return true;
            }
            return false;
        },
        .cons => {
            if (containsUnhandledSpecialFormHelper(form.cons.head)) return true;
            if (containsUnhandledSpecialFormHelper(form.cons.tail)) return true;
            return false;
        },
        else => return false,
    }
}

/// Export the helper used by compileFn


pub fn listFromVector(allocator: Allocator, v: vec.Vector) anyerror!list.List {
    var l: list.List = .empty;
    errdefer l.deinit(allocator);
    for (v.items) |item| {
        try l.append(allocator, try vm.shallowClone(&item, allocator));
    }
    return l;
}

pub fn looksLikeParamList(form: Value) bool {
    const items = switch (std.meta.activeTag(form)) {
        .vector => form.vector.items.items,
        .list => form.list.items.items,
        else => return false,
    };
    if (items.len == 0) return false;
    var found_amp = false;
    for (items) |item| {
        if (std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.symbol, "&")) {
            if (found_amp) return false;
            found_amp = true;
            continue;
        }
        if (std.meta.activeTag(item) != .symbol) return false;
    }
    return true;
}

pub const ParsedParams = struct {
    params: list.List,
    rest_name: ?[]const u8,
};

pub fn parseParams(allocator: Allocator, params: list.List) anyerror!ParsedParams {
    var regular_params: list.List = .empty;
    errdefer regular_params.deinit(allocator);
    var rest_name: ?[]const u8 = null;

    var i: usize = 0;
    var found_amp = false;
    while (i < params.items.len) : (i += 1) {
        const item = params.items[i];
        if (!found_amp and std.meta.activeTag(item) == .symbol and std.mem.eql(u8, item.symbol, "&")) {
            found_amp = true;
            continue;
        }
        if (found_amp) {
            if (std.meta.activeTag(item) != .symbol) return error.TypeError;
            rest_name = try allocator.dupe(u8, item.symbol);
            break;
        } else {
            try regular_params.append(allocator, try vm.shallowClone(&item, allocator));
        }
    }

    return ParsedParams{ .params = regular_params, .rest_name = rest_name };
}

/// Function signature for the compile entry point.
/// Used to break circular dependency between compiler.zig and compiler_special_forms.zig.
pub const CompileFnType = fn (allocator: Allocator, ast: list.List, source_file: []const u8, env: ?*vm.Env, fn_name: ?[]const u8) anyerror!bc.BytecodeProgram;
