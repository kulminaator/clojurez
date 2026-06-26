# ClojureZ - Technical Reference

A Clojure interpreter written in Zig. Supports core data types, special forms, macros, namespaces, protocols, records, lazy sequences, and a bootstrapped Clojure standard library.

## Architecture

```
src/
├── clj/               - Clojure source libraries (baked into binary at compile time)
├── zig/               - main.zig, eval*.zig  etc. - entry point, essential zig code for the language implementation
│   └── namespaces/    - built-in namespaces functions implementations
└── tests/
    ├── clj/             - Clojure-based test suites (test_*.clj)
    ├── test_*.sh        - shell-based integration tests
    └── complex-samples/ - end-to-end sample programs
```

## Data Types

All values are represented by the `Value` tagged union in `value.zig`:

| Type | Literal / Constructor | Notes |
|------|----------------------|-------|
| `nil` | `nil` | |
| `bool` | `true`, `false` | |
| `integer` | `42` | i64 |
| `float` | `3.14` | f64 |
| `bigint` | `123456789012345678901234567890N` | arbitrary precision |
| `ratio` | `(/ 22 7)` → `22/7` | exact rational |
| `decimal` | `123.456M` | arbitrary precision decimal |
| `string` | `"hello"` | UTF-8, escape sequences |
| `regex` | `#"pattern"` | compiled regex |
| `character` | `\a`, `\newline`, `\u0041` | single Unicode code point |
| `symbol` | `x`, `foo-bar`, `my-var?` | UTF-8 |
| `keyword` | `:foo`, `:bar-baz` | UTF-8 |
| `list` | `(1 2 3)` | |
| `vector` | `[1 2 3]` | |
| `map` | `{:a 1 :b 2}` | |
| `set` | `#{1 2 3}` | |
| `queue` | `#queue(1 2 3)` | |
| `atom` | `(atom 5)` | mutable reference |
| `function` | `(fn [x] ...)`, `#(%)` | user-defined, multi-arity |
| `lazy_seq` | `(lazy-seq ...)` | deferred computation |
| `cons` | `(cons 1 (list 2 3))` | cons cell |
| `reduced` | `(reduced val)` | early reduction termination |
| `record` | `(defrecord Person [name age])` | named data type |

## Special Forms

Implemented in `eval.zig` and related modules via a dispatch table:

| Form | Description |
|------|-------------|
| `def` | define a var in current namespace |
| `defn` / `defn-` | define a named function (multi-arity) |
| `defmacro` | define a macro |
| `fn` | anonymous function (multi-arity, `#(%)` shorthand) |
| `if` | conditional |
| `when` / `when-not` / `when-let` / `when-some` / `when-first` | conditionals with body |
| `if-let` | conditional with binding |
| `cond` | multi-way conditional |
| `case` | multi-way constant dispatch |
| `let` / `letfn` | local bindings |
| `do` | evaluate sequence of forms |
| `quote` / `'` | prevent evaluation |
| `quasiquote` / `` ` `` | template with unquote (`~`) and unquote-splicing (`~@`) |
| `set!` | modify a variable |
| `and` / `or` | short-circuit logic |
| `loop` / `recur` | tail recursion |
| `binding` | dynamic variable binding |
| `var` / `deref` / `@` | mutable var |
| `lazy-seq` | create a lazy sequence |
| `dorun` / `doall` | force lazy sequence evaluation |
| `ns` / `in-ns` | namespace declaration |
| `defprotocol` | define a protocol |
| `extend` / `extend-type` / `extend-protocol` | implement protocols |
| `defrecord` | define a record type |
| `->` / `->>` / `cond->` / `cond->>` | threading macros |
| `quit` / `exit` | exit the REPL |

## Namespace Architecture

Three namespace layers:

1. **`user`** - default namespace. REPL, `-e`, and file execution start here. Inherits from `clojure.core`.
2. **`clojure.core`** - public API namespace. Built-in functions and `core.clj` definitions live here.
3. **`zig.core`** - internal implementation namespace. Raw Zig builtins live here. Clojure wrappers in `clojure.core` delegate to `zig.core/` internally.

**Symbol resolution chain:**
```
(+ 1 2) from user namespace:
  user → (not found) → clojure.core → (+ wrapper) → zig.core/+ builtin → 3
```

## Built-in Functions (zig.core)

Built-in functions are registered in `src/zig/namespaces/core/` across domain-specific modules. They are exposed through `zig.core` and wrapped by `clojure.core` Clojure functions.

### Arithmetic (`arithmetic.zig`)
`+`, `-`, `*`, `/`, `rem`, `mod`, `quot`, `rationalize`, `numerator`, `denominator`, `num`, `denom`

### Comparison (`comparison.zig`)
`=`, `!=`, `not=`, `==`, `<`, `>`, `<=`, `>=`, `compare`, `identical?`, `not`

### Type Predicates (`type_predicates.zig`)
`nil?`, `number?`, `string?`, `regex?`, `list?`, `symbol?`, `keyword?`, `true?`, `false?`, `fn?`, `vector?`, `map?`, `record?`, `queue?`, `coll?`, `sequential?`, `boolean?`, `char?`, `int?`, `integer?`, `double?`, `float?`, `NaN?`, `infinite?`, `type`, `meta`, `with-meta`

Plus type coercions: `char`, `int`, `integer`, `float`, `double`, `bigint`, `bigdec`, `byte`, `short`, `keyword`

### String Operations (`strings.zig`)
`str`, `utf8-valid?`, `subs`, `upper-case`, `lower-case`, `capitalize`, `trim`, `triml`, `trimr`, `trim-newline`, `blank?`, `index-of`, `last-index-of`, `starts-with?`, `ends-with?`, `includes?`

### Map Operations (`maps.zig`)
`get`, `assoc`, `keys`, `vals`, `dissoc`, `merge`, `hash-map`

### Set Operations (`sets.zig`)
`set`, `set?`, `disj`

### Collection Operations (`collections.zig`)
`conj`, `pop`, `last`, `reverse`, `peek`, `contains?`

### Sequence Functions (`sequences.zig`, `seq_ops.zig`, `seq_sort.zig`)
`count`, `first`, `rest`, `nth`, `concat`, `list`, `vec`, `seq`, `range`, `subvec`, `cons`, `gensym`, `take`, `map`, `mapcat`, `reduce`, `flatten`, `filter`, `remove`, `every?`, `some`, `distinct?`, `next`, `nthnext`, `drop`, `iterate`, `cycle`, `reduced`, `reduced?`, `ensure-reduced`, `unreduced`, `sort`, `sort-by`, `reductions`, `map-indexed`, `keep-indexed`, `bounded-count`, `group-by`, `distinct`, `replace`

### I/O (`io.zig`)
`print`, `println`, `read-line`, `spit`, `slurp`, `nano-time`, `read-string`, `eval`, `load-file`, `temp-dir`

### Atoms (`atoms.zig`)
`atom`, `deref`, `swap!`, `reset!`

### Bitwise (`bitwise.zig`)
`bit-not`, `bit-and`, `bit-or`, `bit-xor`, `bit-and-not`, `bit-clear`, `bit-set`, `bit-flip`, `bit-test`, `bit-shift-left`, `bit-shift-right`, `unsigned-bit-shift-right`

### Random (`random.zig`)
`rand`, `rand-int`

### Namespace (`namespace.zig`)
`find-ns`, `create-ns`, `all-ns`, `the-ns`, `ns-resolve`, `resolve`, `refer`, `alias`, `ns-aliases`, `ns-unalias`, `require`, `loaded-libs`, `ns-publics`, `ns-interns`, `ns-refers`, `ns-map`, `ns-unmap`, `intern`, `load-string`

### GC (`gc.zig`)
`gc-sweep`, `gc-stats`

### Protocols (`protocols.zig`)
`defprotocol`, `extend`, `extend-type`, `extend-protocol`, `satisfies?`, `extends?`, `extenders`

### Records (`records.zig`)
`defrecord`, `record-ctor`

### Regex (`regexp.zig`, `regexp/`)
`re-matches`, `re-find`, `re-seq`, `re-pattern`, `re-groups`

### Core helpers (`core.zig`)
`empty?`, `not-empty`, `apply`, `trampoline`, `partial`, `comp`, `fnil`, `juxt`, `constantly`, `complement`, `comparator`

## Clojure Core Library (`src/clj/core.clj`)

Functions implemented in Clojure (bootstrapped from `core.clj`, embedded at compile time):

### Predicates
`even?`, `odd?`, `zero?`, `pos?`, `neg?`, `pos-int?`, `neg-int?`, `nat-int?`

### Math
`identity`, `inc`, `dec`, `abs`, `max`, `min`

### Sequences
`cons`, `second`, `third`, `into`, `keep`, `filterv`, `mapv`, `keepv`, `reducev`, `completing`, `dedupe`, `frequencies`, `repeatedly`, `replace`, `shuffle`, `interleave`, `interpose`, `repeat`, `replicate`

### Sets
`union`, `intersection`, `difference`, `subset?`, `superset?`

### Maps
`select-keys`, `key`, `val`, `find`, `zipmap`, `get-in`, `assoc-in`, `update`

### Misc
`memoize`, `constantly`, `complement`, `into-array`, `doall`

### Macros
`when-not`, `when-some`, `if-let`, `when-let`, `time`, `doseq`, `when-first`, `for`, `defonce`

## Clojure String Library (`src/clj/string.clj`)

Functions in `clojure.string` namespace (loaded via `:require`):

`upper-case`, `lower-case`, `capitalize`, `trim`, `triml`, `trimr`, `trim-newline`, `blank?`, `starts-with?`, `ends-with?`, `includes?`, `reverse`, `join`, `escape`, `index-of`, `last-index-of`, `split`, `split-lines`, `re-quote-replacement`, `replace`, `replace-first`

## Garbage Collection

Mark-and-sweep GC in `gc.zig` with type-aware scanning in `gc_scan.zig`.

- All Clojure runtime values are allocated through the GC allocator
- Each allocation has a header with type tag for correct child pointer scanning
- Auto-GC triggers when memory grows by max(20% of last collected, 1MB)
- Generational protection: blocks from current generation are never swept
- Deferred sweep: `gc-sweep` called during evaluation defers actual freeing to safe points

**Debug controls:**
- `CLJVM_GC_SWEEP=0` - disable sweep (objects accumulate, useful for debugging)
- `CLJVM_GC_VERBOSE=1` - verbose GC logging
- `CLJVM_MEM_TRACE=1` - trace allocations to stderr
- `CLJVM_MEM_TRACE=/tmp/mem.log` - trace allocations to file

## Persistent HashMap (HAMT)

`persistent_hash_map.zig` implements a 32-way branching Hash Array Mapped Trie:

- **BitmapIndexedNode** - sparse, bitmap tracks occupied slots (≤16 entries)
- **ArrayNode** - dense, fixed 32 slots (16+ entries)
- **HashCollisionNode** - all keys share the same full hash
- Path copying for structural sharing - mutations return new maps sharing unchanged subtrees
- Nil keys handled separately via `has_null` flag

`persistent_string_hash_map.zig` wraps the HAMT for `[]const u8` keys (VM infrastructure).

## Memory Management

Three-layer allocator stack:
1. **Page allocator** - OS memory allocation
2. **Slab allocator** (`slab_allocator.zig`) - batches small allocations into large pages, reduces syscalls
3. **GC allocator** (`gc.zig`) - mark-and-sweep on top of slab

## Testing

### Clojure-based tests (`tests/clj/test_*.clj`)

Clojure test suites using the `check`/`check-true`/`check-false` helper. Run via the VM:

```bash
./run_tests.sh                    # all tests
./run_tests.sh test_arithmetics   # specific suite
```

### Shell-based tests (`tests/test_*.sh`)

Integration tests for I/O, namespaces, samples, and REPL behavior.

### Complex samples (`tests/complex-samples/`)

End-to-end programs with expected output verification:
- Fibonacci (lazy sequences)
- Tower of Hanoi (recursion)
- Namespaces (`-cp -m` usage)
- GC stress test
- Regex GC test

### Zig unit tests (`src/zig/all_tests.zig`)

Tests individual modules:

```bash
zig test -fsingle-threaded src/zig/all_tests.zig
```

### Running all tests

```bash
zig test -fsingle-threaded src/zig/all_tests.zig && ./run_tests.sh
```

## Build

```bash
zig build                          # all 3 variants
zig build -Doptimize=ReleaseSmall  # specific optimize mode
```

Build copies `src/clj/core.clj` → `src/zig/namespaces/core/clj/core.clj` and `src/clj/string.clj` → `src/zig/namespaces/core/clj/string.clj` for `@embedFile`.

## Debugging

### Parse debug

```bash
./zig-out/bin/clojurez --parse-debug myfile.clj
```

Runs the file through the parser only (no evaluation). Reports form nesting, open/close events, and syntax errors.

### Debug output

```bash
CLJVM_DEBUG=1 ./zig-out/bin/clojurez -e '(+ 1 2 3)'
CLJVM_DEBUG=gc,eval ./zig-out/bin/clojurez -e '(+ 1 2 3)'
```

Categories: `gc`, `eval`, or `all`/`1`/`true` for everything.

## What's Missing

- **Transients** - mutable versions of persistent data structures
- **Multimethods** - `defmulti`, `defmethod`
- **Spec system** - no `clojure.spec`
- **Java interop** - not applicable for a standalone VM
- **JIT compilation** - we are an interpreting VM
- **Chunked sequences** - simpler sequence implementation
- **Full regex in `clojure.string`** - `split`, `replace`, `replace-first` use regex via the built-in engine but some edge cases may differ from JVM Clojure
