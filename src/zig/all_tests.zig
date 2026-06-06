// Test runner — imports all modules so their test blocks are discovered.
// Usage: zig test -fsingle-threaded src/zig/all_tests.zig

const test_value = @import("value.zig");
const test_list = @import("list.zig");
const test_vector = @import("vector.zig");
const test_lexer = @import("lexer.zig");
const test_parser = @import("parser.zig");
const test_core = @import("core.zig");
const test_helpers = @import("core/helpers.zig");
const test_arithmetic = @import("core/arithmetic.zig");
const test_comparison = @import("core/comparison.zig");
const test_type_predicates = @import("core/type_predicates.zig");
const test_strings = @import("core/strings.zig");
const test_sequences = @import("core/sequences.zig");
const test_seq_ops = @import("core/seq_ops.zig");
const test_maps = @import("core/maps.zig");
const test_sets = @import("core/sets.zig");
const test_collections = @import("core/collections.zig");
const test_io = @import("core/io.zig");
const test_atoms = @import("core/atoms.zig");
const test_eval_helpers = @import("core/eval_helpers.zig");
const test_slab = @import("slab_allocator.zig");
const test_debug_alloc = @import("debug_allocator.zig");
const test_eval = @import("eval.zig");
const test_eval_macro = @import("eval_macro.zig");
const test_eval_ns = @import("eval_ns.zig");
const test_eval_thread = @import("eval_thread.zig");
const test_repl = @import("repl.zig");

// Suppress unused import warnings
comptime {
    _ = test_value;
    _ = test_list;
    _ = test_vector;
    _ = test_lexer;
    _ = test_parser;
    _ = test_core;
    _ = test_helpers;
    _ = test_arithmetic;
    _ = test_comparison;
    _ = test_type_predicates;
    _ = test_strings;
    _ = test_sequences;
    _ = test_seq_ops;
    _ = test_maps;
    _ = test_sets;
    _ = test_collections;
    _ = test_io;
    _ = test_atoms;
    _ = test_eval_helpers;
    _ = test_slab;
    _ = test_debug_alloc;
    _ = test_eval;
    _ = test_eval_macro;
    _ = test_eval_ns;
    _ = test_eval_thread;
    _ = test_repl;
}
