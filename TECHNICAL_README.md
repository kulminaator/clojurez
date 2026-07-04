# ClojureZ - Technical Reference

A Clojure interpreter written in Zig. Supports core data types, special forms, macros, namespaces, protocols, records, lazy sequences, bytecode compilation, multithreading, filesystem operations, process I/O, and a bootstrapped Clojure standard library.

## Architecture

```
src/
├── clj/               - Clojure source libraries (baked into binary at compile time)
│   ├── core.clj       - clojure.core: bootstrapped functions, macros, threading helpers
│   ├── string.clj     - clojure.string: string manipulation functions
│   └── io.clj         - zig.io: protocol-based I/O abstractions, subprocess, streams
├── zig/               - main.zig, eval*.zig etc. - entry point, essential zig code for the language implementation
│   ├── bytecode.zig   - bytecode compiler and stack-based VM
│   ├── eval.zig       - main evaluator (AST interpreter + bytecode dispatch)
│   ├── eval_thread.zig - threading macros (->, ->>, cond->, cond->>)
│   ├── eval_macro.zig - macro expansion
│   ├── eval_ns.zig    - namespace evaluation
│   ├── gc.zig         - mark-and-sweep garbage collector (thread-safe)
│   ├── gc_scan.zig    - type-aware GC scanning
│   ├── slab_allocator.zig - thread-safe slab allocator (per-slab spinlocks)
│   ├── value.zig      - Value tagged union and all value constructors
│   └── namespaces/    - built-in namespace function implementations
│       └── core/      - domain-specific modules (arithmetic, io, threading, etc.)
│           ├── io.zig          - basic I/O: print, println, read-line, spit, slurp, load-file
│           ├── io_fs.zig       - filesystem ops: stat, list-dir, walk-dir, make-dir, delete, rename, copy
│           ├── io_shell.zig    - subprocess: sh-execute (sync), sh-execute-stream (async)
│           ├── io_stream.zig   - stream I/O: input/output streams, readers, writers
│           ├── threading.zig   - multithreading: sleep, future-call, promise, deliver, realized
│           └── ...
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
| `chunk` | internal | ChunkData — batch of values (IChunk equivalent) |
| `chunked_cons` | internal | ChunkedConsData — chunk + lazy tail |
| `reduced` | `(reduced val)` | early reduction termination |
| `record` | `(defrecord Person [name age])` | named data type |
| `future` | `(future ...)` | computation running in another thread |
| `promise` | `(promise)` | one-time writable container |
| `wrapped` | internal | raw pointer wrapper — streams, process handles, etc. |

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
4. **`zig.io`** - protocol-based I/O namespace. Provides `Closeable`, `IOFactory`, `Readable`, `Writable` protocols, path utilities, `with-open`, `copy`, `line-seq`, and subprocess helpers (`sh`, `sh-stream`, etc.). Loaded via `(require '[zig.io :as io])`.

**Symbol resolution chain:**
```
(+ 1 2) from user namespace:
  user → (not found) → clojure.core → (+ wrapper) → zig.core/+ builtin → 3
```

## Bytecode Compilation

`bytecode.zig` implements a stack-based bytecode compiler and VM for faster repeated execution of eligible functions.

### When Bytecode Is Used

During `defn` evaluation, each arity's body is analyzed. If the body contains **only** arithmetic operators, comparison operators, and bytecode-supported special forms (no "real" function calls, no destructuring), it is compiled to bytecode:

```clojure
;; This function is compiled to bytecode (pure arithmetic + comparison):
(defn compute [a b]
  (+ (* a b) (- a b)))

;; This function uses the AST interpreter (contains function calls):
(defn mixed [a b]
  (println (+ a b)))
```

### Instruction Set

The bytecode VM uses a stack-based instruction set with a constant pool:

| Category | Opcodes |
|----------|---------|
| Constants | `push_nil`, `push_true`, `push_false`, `push_int`, `push_float`, `push_const` |
| Variables | `load_var`, `store_var` |
| Calls | `call_n` |
| Control flow | `jump`, `jump_if_nil`, `jump_if_not_nil` |
| Comparison | `eq`, `ne`, `lt`, `gt`, `le`, `ge` |
| Arithmetic | `add`, `sub`, `mul`, `div`, `rem`, `neg` |
| Type checks | `is_nil`, `is_truthy`, `not` |
| Collections | `cons`, `list_n`, `vector_n`, `map_n`, `get`, `assoc` |
| Special forms | `if`, `let`, `loop`, `recur`, `do`, `call_user_fn` |

### Bytecode Program Structure

A `BytecodeProgram` contains:
- **Instructions** — array of `Instruction { opcode, operand }`
- **Constants** — constant pool (strings, symbols, keywords, bigints, ratios, decimals, regex, chars)
- **Symbols** — symbol pool for variable lookups
- **Source markers** — mapping from bytecode PC to source line numbers (for debugging)
- **Function pool** — references to user-defined functions called from bytecode

### GC Integration

Bytecode programs are tracked by the GC with `GCObjectType.bytecode_program`. The constant pool, symbol pool, and function pool are all scanned during GC marking.

## Multithreading

### Thread Safety Architecture

The entire VM is designed for thread safety. Key mechanisms:

1. **GC thread safety**: The block list is protected by an atomic spinlock (`block_mutex`). A `gc_lock` prevents collection while child threads are active. The `active_thread_count` atomic tracks running detached threads.
2. **Slab allocator thread safety**: Each size class (slab) has its own per-slab spinlock for concurrent alloc/free.
3. **Future/Promise atomics**: `FutureData.state` and `PromiseData.state` use `std.atomic.Value(u32)` with release/acquire ordering for lock-free state transitions.

### Threading Primitives

| Function | Description |
|----------|-------------|
| `sleep` | Block the current thread for N milliseconds |
| `future` / `future-call` | Execute a function in a detached thread, return a future |
| `promise` / `deliver` | One-time writable container (thread-safe) |
| `realized?` | Check if a future/promise has completed |
| `deref` / `@` | Block and retrieve the result of a future/promise |

### Future Lifecycle

1. `future-call` allocates `FutureData` via GC, acquires the `gc_lock`, and spawns a detached thread via `std.Thread.spawn`.
2. The child thread clones the function's captured environment, evaluates the body, stores the result, and transitions state to `done` via atomic store.
3. On completion, the child thread calls `threadDone()` which releases the `gc_lock` and decrements `active_thread_count`.
4. `deref-future` polls the atomic state; if `pending`, it sleeps and retries; if `done`, it returns the cached result.

### Promise Lifecycle

1. `promise` allocates `PromiseData` via GC with state `pending`.
2. `deliver` uses atomic `cmpxchg` to transition from `pending` to `delivered`. First deliver wins; subsequent delivers are no-ops.
3. `deref-promise` blocks until state is `delivered`, then returns the stored value.

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

### Basic I/O (`io.zig`)
`print`, `println`, `read-line`, `spit`, `slurp`, `nano-time`, `read-string`, `eval`, `load-file`, `temp-dir`

### Filesystem Operations (`io_fs.zig`)
`stat`, `list-dir`, `walk-dir`, `make-dir`, `make-parents`, `delete`, `delete-tree`, `rename`, `copy-file`, `copy-dir`, `file-exists?`, `is-file?`, `is-directory?`, `is-symlink?`, `is-readable?`, `is-writable?`, `read-symbolic-link`, `create-symbolic-link`

### Stream I/O (`io_stream.zig`)
`open-input-stream`, `open-output-stream`, `open-reader`, `open-writer`, `close-stream`, `read-line-stream`, `read-byte-stream`, `write-string`, `write-bytes`, `flush-stream`

### Process I/O (`io_shell.zig`)
`sh-execute` (synchronous subprocess), `sh-execute-stream` (async subprocess handle), `sh-read-output`, `sh-read-error`, `sh-write-input`, `sh-close-input`, `sh-wait`, `sh-kill`

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

### Threading (`threading.zig`)
`sleep`, `future-call`, `deref-future`, `deref-promise`, `promise`, `deliver`, `realized`, `future?`, `promise?`

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

### Multithreading
`future` (macro), `future-call`, `future?`, `future-done?`, `promise`, `deliver`, `realized?`, `promise?`, `deref` (extended for futures/promises), `sleep`

## Clojure String Library (`src/clj/string.clj`)

Functions in `clojure.string` namespace (loaded via `:require`):

`upper-case`, `lower-case`, `capitalize`, `trim`, `triml`, `trimr`, `trim-newline`, `blank?`, `starts-with?`, `ends-with?`, `includes?`, `reverse`, `join`, `escape`, `index-of`, `last-index-of`, `split`, `split-lines`, `re-quote-replacement`, `replace`, `replace-first`

## Clojure I/O Library (`src/clj/io.clj`)

Functions in `zig.io` namespace (loaded via `(require '[zig.io :as io])`):

### Protocols
`Closeable` (`-close`), `IOFactory` (`make-reader`, `make-writer`, `make-input-stream`, `make-output-stream`), `Coercions` (`as-file`), `Readable` (`read-chunk`), `Writable` (`write-chunk`, `flush`)

### Path Utilities
`file`, `as-file`, `as-relative-path`

### Stream Creation
`reader`, `writer`, `input-stream`, `output-stream`

### Data Operations
`copy`, `line-seq`

### Resource Management
`with-open` (macro)

### Subprocess Execution
`sh` (synchronous), `sh-stream` (async handle), `sh-in`, `sh-out`, `sh-err`, `sh-close-in`, `sh-wait`, `sh-kill`, `with-sh-dir`, `with-sh-env`

## Garbage Collection

Mark-and-sweep GC in `gc.zig` with type-aware scanning in `gc_scan.zig`.

- All Clojure runtime values are allocated through the GC allocator
- Each allocation has a header with type tag for correct child pointer scanning
- Auto-GC triggers when memory grows by max(20% of last collected, 1MB)
- Generational protection: blocks from current generation are never swept
- Deferred sweep: `gc-sweep` called during evaluation defers actual freeing to safe points
- **Thread-safe**: block list protected by atomic spinlock (`block_mutex`); GC collection blocked while child threads are active via `gc_lock`; slab allocator uses per-slab spinlocks for concurrent alloc/free; `active_thread_count` tracks running detached threads

**GC-tracked object types** (`GCObjectType`):
- `value_array`, `map_entries`, `set_items`, `queue_items` — collection data
- `env`, `namespace_manager` — evaluation environment
- `lazy_seq_thunk`, `atom_data`, `future_data`, `promise_data` — runtime objects
- `fn_data`, `fn_arities` — function definitions
- `cons_data`, `hash_map_node`, `hash_map_kvp_array`, `hash_map_sub_nodes` — HAMT internals
- `record_data`, `list_data`, `vector_data`, `map_data`, `set_data`, `queue_data` — collection structures
- `string_data`, `bigint_limbs`, `bigint_data`, `ratio_data`, `decimal_data` — scalar data
- `bytecode_program` — compiled bytecode
- `chunk_data`, `chunked_cons_data` — chunked sequences

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
2. **Slab allocator** (`slab_allocator.zig`) - batches small allocations into large pages, reduces syscalls; thread-safe via per-slab spinlocks
3. **GC allocator** (`gc.zig`) - mark-and-sweep on top of slab

## Testing

### Clojure-based tests (`tests/clj/test_*.clj`)

Clojure test suites using the `check`/`check-true`/`check-false` helper. Run via the VM:

```bash
./run_tests.sh                    # all tests
./run_tests.sh test_arithmetics   # specific suite
```

Key test suites:
- `test_bytecode.clj` — bytecode compiler and VM
- `test_multithreading.clj` — futures, promises, sleep
- `test_zig_io.clj` — filesystem, streams, subprocess, zig.io namespace
- `test_thread_macros.clj` — `->`, `->>`, `cond->`, `cond->>`

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
zig test src/zig/all_tests.zig
```

### Running all tests

```bash
zig test src/zig/all_tests.zig && ./run_tests.sh
```

## Build

```bash
zig build                          # all 3 variants
zig build -Doptimize=ReleaseSmall  # specific optimize mode
```

Build copies `src/clj/core.clj` → `src/zig/namespaces/core/clj/core.clj`, `src/clj/string.clj` → `src/zig/namespaces/core/clj/string.clj`, and `src/clj/io.clj` → `src/zig/namespaces/core/clj/io.clj` for `@embedFile`.

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
- **JIT compilation** - we are an interpreting VM (bytecode compilation used for eligible functions)
- **Chunked sequences** - simpler sequence implementation (basic chunk support exists)
- **Full regex in `clojure.string`** - `split`, `replace`, `replace-first` use regex via the built-in engine but some edge cases may differ from JVM Clojure
