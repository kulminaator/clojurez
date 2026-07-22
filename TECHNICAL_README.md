# ClojureZ - Technical Reference

A Clojure interpreter written in Zig. Supports core data types, special forms, macros, namespaces, protocols, records, lazy sequences, bytecode compilation, multithreading, filesystem operations, process I/O, and a bootstrapped Clojure standard library.

## Architecture

```
src/
├── clj/               - Clojure source libraries (baked into binary at compile time)
│   ├── core.clj       - clojure.core: bootstrapped functions, macros, threading helpers
│   ├── string.clj     - clojure.string: string manipulation functions
│   ├── math.clj       - clojure.math: trigonometric, exponential, rounding, IEEE operations
│   ├── io.clj         - zig.io: protocol-based I/O abstractions, subprocess, streams
│   ├── test.clj       - clojure.test: testing framework (deftest, is, testing, fixtures)
│   ├── walk.clj       - clojure.walk: tree walking utilities (postwalk, prewalk, replace)
│   └── template.clj   - clojure.template: template utilities (apply-template, do-template)
├── zig/               - main.zig, eval*.zig etc. - entry point, essential zig code for the language implementation
│   ├── bytecode.zig   - bytecode compiler and stack-based VM
│   ├── eval.zig       - main evaluator (AST interpreter + bytecode dispatch)
│   ├── eval_try.zig   - try/catch/finally special form implementation
│   ├── eval_thread.zig - threading macros (->, ->>, cond->, cond->>)
│   ├── eval_macro.zig - macro expansion
│   ├── eval_ns.zig    - namespace evaluation
│   ├── eval_meta.zig  - alter-meta! special form (metadata mutation)
│   ├── eval_multi.zig - multimethod special forms (defmulti, defmethod)
│   ├── ref.zig        - STM system (ref, dosync, alter, commute, ref-set)
│   ├── exception.zig   - exception types, hierarchy, and exception values
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
│           ├── math.zig        - clojure.math: trig, hyperbolic, exp/log, rounding, IEEE, exact arithmetic
│           ├── threading.zig   - multithreading: sleep, future-call, promise, deliver, realized
│           └── ...
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
| `exception` | `(ex-info "msg" {})` | exception with type, message, data map, cause |
| `ref` | `(ref 42)` | STM reference with version counter |
| `multimethod` | `(defmulti mm :type)` | multimethod dispatch with method table |

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
| `try` / `catch` / `finally` | exception handling (`try body* (catch Type sym body*)* (finally cleanup*)?`) |
| `throw` | throw an exception |
| `alter-meta!` | modify var metadata in-place (`alter-meta! sym f & args`) |
| `dosync` | transactional execution — retry loop for STM refs (`dosync body*`) |
| `defmulti` | define a multimethod (`defmulti name docstring? dispatch-fn & options`) |
| `defmethod` | add a method to a multimethod (`defmethod mm dispatch-val [params] body`) |
| `quit` / `exit` | exit the REPL |

## Namespace Architecture

Three namespace layers:

1. **`user`** - default namespace. REPL, `-e`, and file execution start here. Inherits from `clojure.core`.
2. **`clojure.core`** - public API namespace. Built-in functions and `core.clj` definitions live here.
3. **`clojure.math`** - mathematical functions and constants. Provides `E`, `PI`, trigonometric, hyperbolic, exponential/logarithmic, rounding, IEEE, and exact integer arithmetic functions. Loaded via `(require '[clojure.math :as math])`.
4. **`clojure.test`** - testing framework. Provides `deftest`, `is`, `testing`, `use-fixtures`, `run-tests`, `run-all-tests`, `are`, `thrown?`, `thrown-with-msg?`. Embedded at compile time.
5. **`clojure.walk`** - tree walking utilities. Provides `walk`, `postwalk`, `prewalk`, `postwalk-replace`, `prewalk-replace`, `keywordize-keys`, `stringify-keys`. Loaded via `(require '[clojure.walk :as walk])`.
6. **`clojure.template`** - template utilities. Provides `apply-template`, `do-template`. Loaded via `(require '[clojure.template :as template])`.
7. **`zig.core`** - internal implementation namespace. Raw Zig builtins live here. Clojure wrappers in `clojure.core` delegate to `zig.core/` internally.
8. **`zig.io`** - protocol-based I/O namespace. Provides `Closeable`, `IOFactory`, `Readable`, `Writable` protocols, path utilities, `with-open`, `copy`, `line-seq`, and subprocess helpers (`sh`, `sh-stream`, etc.). Loaded via `(require '[zig.io :as io])`.

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

## Exception Handling

Implemented in `eval_try.zig` and `exception.zig`.

### `try`/`catch`/`finally` Special Form

```
(try body* (catch Type sym body*)* (finally cleanup*)?)
```

- Evaluates body forms.
- On exception, matches against `catch` clauses in order using the exception type hierarchy (`isa?` check).
- The first matching `catch` binds the exception to `sym` and evaluates its body.
- `finally` always runs, regardless of whether an exception was thrown or caught.
- If no `catch` matches, the exception propagates up.

### Exception Types

Exception values are `Value` tagged unions with `.exception` type containing:
- `type_kw` — exception type string (e.g. `"clojure.lang/ArithmeticException"`)
- `message` — error message string
- `data` — optional data map (for `ex-info`)
- `cause` — optional cause exception

### Built-in Hierarchy

Defined in `exception.zig` with `derive` calls:

```
Throwable
└── Exception
    ├── RuntimeException
    │   ├── ArithmeticException
    │   ├── IllegalArgumentException
    │   ├── IllegalStateException
    │   ├── NullPointerException
    │   └── IndexOutOfBoundsException
    ├── IOException
    │   └── FileNotFoundException
    └── TimeoutException
        └── SocketTimeoutException
```

### Automatic Exceptions

- **Division by zero**: `( / 1 0 )` throws `ArithmeticException`
- **Exact arithmetic overflow**: `(add-exact MOST_POSITIVE_INT 1)` throws `ArithmeticException`

### Custom Hierarchy

`derive`, `parents`, `isa?` allow defining custom type hierarchies for exception dispatch and multimethod routing.

## Multimethods

Implemented in `eval_multi.zig` as special forms `defmulti` and `defmethod`.

### `defmulti` / `defmethod`

```clojure
(defmulti report :type)        ; dispatch on :type key
(defmethod report :pass [m]    ; method for :pass dispatch value
  (println "PASS"))
(defmethod report :fail [m]    ; method for :fail dispatch value
  (println "FAIL"))
(report {:type :pass})         ; → prints "PASS"
```

### Multimethod Value Type

`MultimethodData` struct contains:
- `dispatch_fn` — the dispatch function
- `method_table` — ArrayList of MapEntry (dispatch-value → method-fn)
- `pref_table` — preference pairs for dispatch resolution
- `default_dispatch` — default dispatch value (from `:default` option)

### Multimethod Invocation

When a multimethod value is called as a function:
1. Call `dispatch_fn` with the arguments to get the dispatch value
2. Look up the dispatch value in `method_table`
3. If found, invoke the matching method with the original arguments
4. If not found, try the `:default` dispatch value, then `:default` keyword

### Multimethod Functions

| Function | Description |
|----------|-------------|
| `defmulti` | Define a multimethod (special form) |
| `defmethod` | Add a method to a multimethod (special form) |
| `prefer-method` | Add a preference pair (preferred dispatch > less preferred) |
| `preferences` | Return preference map `{preferred -> #{less-preferred...}}` |
| `get-method` | Get method function for a dispatch value |
| `methods` | Return method table as a map |
| `dispatch-fn` | Return the dispatch function |

## STM (Software Transactional Memory)

Implemented in `ref.zig` with `dosync` as a special form and `ref`, `alter`, `commute`, `ref-set`, `ensure` as builtins.

### Design

Simple optimistic STM with single-writer semantics:
- `RefData` struct: `value`, `version` counter, optional `validator`, optional `meta` (for `:commutative`)
- Transaction state: thread-local write-set (ref → new value)
- `dosync`: retry loop — evaluate body, apply write-set, commit
- No MVCC — simple version counter per ref

### Usage

```clojure
(def r (ref 0))              ; Create a ref with initial value 0
(dosync (alter r + 10))      ; Non-commutative update inside transaction
(dosync (commute r + 5))     ; Commutative update inside transaction
(dosync (ref-set r 100))     ; Set ref value inside transaction
@r                           ; → 100 (deref)
```

### STM Functions

| Function | Description |
|----------|-------------|
| `ref` | Create an STM reference (`ref initial-value & opts`) |
| `dosync` | Transactional execution (special form) |
| `alter` | Non-commutative ref update inside dosync |
| `commute` | Commutative ref update inside dosync |
| `ref-set` | Set ref value inside dosync |
| `ensure` | Add ref to transaction read-set (no-op in simple STM) |
| `ref?` | Check if value is a ref |
| `commutative?` | Check if ref has `:commutative` metadata |

### Ref Metadata

Refs support optional metadata via `:commutative` option:
```clojure
(def r (ref 0 :commutative true))
(commutative? r)  ; → true
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
`count`, `first`, `rest`, `nth`, `concat`, `list`, `vec`, `vector`, `seq`, `range`, `subvec`, `cons`, `gensym`, `take`, `map`, `mapcat`, `reduce`, `flatten`, `filter`, `remove`, `every?`, `some`, `distinct?`, `next`, `nthnext`, `drop`, `iterate`, `cycle`, `reduced`, `reduced?`, `ensure-reduced`, `unreduced`, `sort`, `sort-by`, `reductions`, `map-indexed`, `keep-indexed`, `bounded-count`, `group-by`, `distinct`, `replace`

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

### Math (`math.zig`)
`E`, `PI`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `to-radians`, `to-degrees`, `sinh`, `cosh`, `tanh`, `exp`, `log`, `log10`, `sqrt`, `cbrt`, `expm1`, `log1p`, `pow`, `hypot`, `ceil`, `floor`, `rint`, `round`, `IEEE-remainder`, `signum`, `copy-sign`, `add-exact`, `subtract-exact`, `multiply-exact`, `increment-exact`, `decrement-exact`, `negate-exact`, `floor-div`, `floor-mod`, `ulp`, `get-exponent`, `scalb`, `next-after`, `next-up`, `next-down`, `random`

### Exception (`exception.zig`)
`ex-info`, `ex-data`, `ex-message`, `ex-cause`, `exception?`, `derive`, `parents`, `isa?`

### Namespace (`namespace.zig`)
`find-ns`, `create-ns`, `all-ns`, `the-ns`, `ns-resolve`, `resolve`, `refer`, `alias`, `ns-aliases`, `ns-unalias`, `require`, `loaded-libs`, `ns-publics`, `ns-interns`, `ns-refers`, `ns-map`, `ns-unmap`, `intern`, `load-string`

### GC (`gc.zig`)
`gc-sweep`, `gc-stats`

### System (`cpu_stats.zig`)
`cpu-stats`

### Protocols (`protocols.zig`)
`defprotocol`, `extend`, `extend-type`, `extend-protocol`, `satisfies?`, `extends?`, `extenders`

### Records (`records.zig`)
`defrecord`, `record-ctor`

### Regex (`regexp.zig`, `regexp/`)
`re-matches`, `re-find`, `re-seq`, `re-pattern`, `re-groups`

### Core helpers (`core.zig`)
`empty?`, `not-empty`, `apply`, `trampoline`, `partial`, `comp`, `fnil`, `juxt`, `constantly`, `complement`, `comparator`, `if-not`

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

### Parsing
`parse-boolean`, `parse-long`, `parse-double`

### Metadata & Introspection
`vary-meta`, `doto`, `prn`, `merge-with`, `update-in`, `namespace`, `instance?`, `class`, `long`, `find-var`

### Macros
`when-not`, `when-some`, `if-let`, `when-let`, `time`, `doseq`, `when-first`, `for`, `defonce`

### Multithreading
`future` (macro), `future-call`, `future?`, `future-done?`, `promise`, `deliver`, `realized?`, `promise?`, `deref` (extended for futures/promises), `sleep`, `pmap`, `pcalls`, `pvalues` (macro)

### Exception Support
`ex-info`, `ex-data`, `ex-message`, `ex-cause`, `exception?`, `derive`, `parents`, `isa?`, `IExceptionInfo` protocol

Built-in exception hierarchy:
- `Throwable` (root)
  - `Exception`
    - `RuntimeException`
      - `ArithmeticException` (division by zero, exact arithmetic overflow)
      - `IllegalArgumentException`
      - `IllegalStateException`
      - `NullPointerException`
      - `IndexOutOfBoundsException`
    - `IOException`
      - `FileNotFoundException`
    - `TimeoutException`
      - `SocketTimeoutException`

### Hierarchy
`derive`, `parents`, `isa?` — custom type hierarchy support for exception dispatch and multimethods

## Clojure String Library (`src/clj/string.clj`)

Functions in `clojure.string` namespace (loaded via `:require`):

`upper-case`, `lower-case`, `capitalize`, `trim`, `triml`, `trimr`, `trim-newline`, `blank?`, `starts-with?`, `ends-with?`, `includes?`, `reverse`, `join`, `escape`, `index-of`, `last-index-of`, `split`, `split-lines`, `re-quote-replacement`, `replace`, `replace-first`

## Clojure Math Library (`src/clj/math.clj`)

Functions in `clojure.math` namespace (loaded via `(require '[clojure.math :as math])`). All functions delegate to `zig.core` builtins:

### Constants
`E` — Euler's number (≈2.71828), `PI` — π (≈3.14159)

### Trigonometric Functions
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`

### Angle Conversion
`to-radians`, `to-degrees`

### Hyperbolic Functions
`sinh`, `cosh`, `tanh`

### Exponential / Logarithmic Functions
`exp`, `log`, `log10`, `sqrt`, `cbrt`, `expm1`, `log1p`, `pow`, `hypot`

### Rounding Functions
`ceil`, `floor`, `rint`, `round`

### IEEE Remainder + Sign Functions
`IEEE-remainder`, `signum`, `copy-sign`

### Exact Integer Arithmetic (throw `ArithmeticException` on overflow)
`add-exact`, `subtract-exact`, `multiply-exact`, `increment-exact`, `decrement-exact`, `negate-exact`

### Floor Division / Modulus
`floor-div`, `floor-mod`

### Floating-Point Bit Operations
`ulp`, `get-exponent`, `scalb`, `next-after`, `next-up`, `next-down`

### Random
`random` — pseudorandom double in [0.0, 1.0)

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

## Clojure Test Library (`src/clj/test.clj`)

Functions in `clojure.test` namespace (embedded at compile time, loaded via `(require '[clojure.test :as t])`):

### Test Definition
`deftest`, `deftest-`, `testing`, `with-test`, `set-test`

### Assertions
`is` (generic assertion macro), `assert-expr` (multimethod), `assert-predicate`, `assert-any`

### Assertion Helpers
`thrown?` (exception testing), `thrown-with-msg?` (exception + message regex testing), `instance?` (type checking)

### Fixtures
`use-fixtures` (`:each` and `:once`), `compose-fixtures`, `join-fixtures`

### Test Execution
`test-var`, `test-vars`, `test-all-vars`, `test-ns`, `run-tests`, `run-all-tests`, `run-test-var`, `run-test`, `successful?`

### Reporting
`report` (multimethod dispatched on `:type`), `do-report`, `inc-report-counter`

### Dynamic Vars
`*load-tests*`, `*report-counters*`, `*initial-report-counters*`, `*testing-vars*`, `*testing-contexts*`, `*test-out*`, `*stack-trace-depth*`

### Tabular Testing
`are` (tabular test data with template expression)

## Clojure Walk Library (`src/clj/walk.clj`)

Functions in `clojure.walk` namespace (loaded via `(require '[clojure.walk :as walk])`):

`walk`, `postwalk`, `prewalk`, `postwalk-replace`, `prewalk-replace`, `keywordize-keys`, `stringify-keys`

## Clojure Template Library (`src/clj/template.clj`)

Functions in `clojure.template` namespace (loaded via `(require '[clojure.template :as template])`):

`apply-template`, `do-template`

## Garbage Collection

Mark-and-sweep GC in `gc.zig` with type-aware scanning in `gc_scan.zig`.

- All Clojure runtime values are allocated through the GC allocator
- Each allocation has a header with type tag for correct child pointer scanning
- Auto-GC triggers when memory grows by max(20% of last collected, 1MB)
- Generational protection: blocks from current generation are never swept
- Deferred sweep: `gc-sweep` called during evaluation defers actual freeing to safe points
- **Thread-safe**: block list protected by atomic spinlock (`block_mutex`); GC collection blocked while child threads are active via `gc_lock`; slab allocator uses per-slab spinlocks for concurrent alloc/free; `active_thread_count` tracks running detached threads
- If we implement new clojure data types then design them in a way that would force them to be allocated from the GC (like strings and symbols), this way we can't accidentally allocate them from stack or other odd places.

**GC-tracked object types** (`GCObjectType`):
- `value_cache` — pre-cached singleton values (nil, bool, small int, latin char, empty collections, E, PI)
- `value_array`, `map_entries`, `set_items`, `queue_items` — collection data
- `env`, `namespace_manager` — evaluation environment
- `lazy_seq_thunk`, `atom_data`, `future_data`, `promise_data`, `ref_data`, `multimethod_data` — runtime objects
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

## Pre-cached Values

`value.zig` implements a `ValueCache` that provides singleton Value pointers for commonly used values, avoiding repeated allocations:

- **`nil`** — single shared nil value
- **Booleans** — single shared `true` and `false` values
- **Small integers** — cached integer values for frequently used small numbers
- **Latin characters** — cached character values for ASCII/latin code points
- **Empty collections** — single shared empty list `()`, empty vector `[]`, empty map `{}`, empty set `#{}`
- **Mathematical constants** — pre-computed `E` and `PI` float values

The cache is scanned during GC marking (`GCObjectType.value_cache`) to ensure cached pointers are never collected. Functions like `cachedE()`, `cachedPI()`, `cachedEmptyList()`, etc. return the cached pointers when available.

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

### Test Structure

```
tests/
├── run_all.clj              # Entry point for Clojure shell test suites
├── test_debug.sh            # CLJVM_DEBUG env var tests (bash, cannot be in Clojure yet)
├── README.md                # Test documentation
├── complex-samples/         # End-to-end sample programs
└── clj/
    ├── clj_test_helper.clj  # check/check-true/check-false for in-VM tests
    ├── test_runner.clj      # def-suite, test, check, run-all framework
    ├── shell_test_runner.clj # run-cmd, test-cmd, test-repl, test-file, test-main
    ├── test_smoke.clj       # Fast smoke test (runs first, aborts on failure)
    ├── test_*.clj           # In-VM test suites (run directly in clojurez)
    └── test_shell_*.clj     # Shell test suites (spawn subprocesses via io/sh)
```

### Test Categories

**1. Zig Unit Tests** (`src/zig/all_tests.zig`) — ~470 tests
```bash
zig test src/zig/all_tests.zig
```

**2. Clojure In-VM Suites** (`tests/clj/test_*.clj`, excluding `shell_*`) — ~50 suites
Run directly inside a single clojurez process. Use `check`/`check-true`/`check-false` from `clj_test_helper.clj`.

Key suites: `test_bytecode.clj`, `test_math.clj`, `test_exceptions.clj`, `test_multithreading.clj`, `test_zig_io.clj`, `test_thread_macros.clj`, and many more.

**3. Clojure Shell Suites** (`tests/clj/test_shell_*.clj`) — 7 suites, ~59 tests
Spawn child clojurez processes to test features requiring process isolation: stdout capture, REPL interaction, file execution, `-cp`/`-m`, complex samples.

Run all: `clojurez --timeout 120 tests/run_all.clj`

**4. Bash Debug Tests** (`tests/test_debug.sh`) — 4 tests
CLJVM_DEBUG environment variable tests. Cannot be migrated to Clojure because `io/sh` does not yet support the `:env` option.

### Built-in `--timeout` Flag

The clojurez VM has a built-in `--timeout N` flag (N in seconds) that:
- Terminates execution after N seconds
- Kills child threads and subprocesses (no zombie processes)
- Exits with code 124 (GNU timeout convention)
- Example: `clojurez --timeout 2 -e '(sleep 30000)'` exits within ~3 seconds

### Running All Tests

```bash
# Full test run (Zig unit tests + all Clojure tests)
zig test src/zig/all_tests.zig && ./run_tests.sh

# Clojure tests only (builds VM first)
./run_tests.sh

# Without rebuilding
NOBUILD=1 ./run_tests.sh

# Specific Clojure in-VM suite
./run_tests.sh test_arithmetics
```

### Test Output Formats

| Outcome | Meaning |
|---------|---------|
| **PASS** | VM exited cleanly, no `FAIL:` lines in output |
| **FAIL** | VM exited cleanly, but one or more `FAIL:` lines present in output |
| **TIMEOUT** | VM did not exit within the time limit (15s default) |
| **CRASH** | VM exited with non-zero exit code (segfault, assertion failure, etc.) |

When debugging test failures, **do not grep only for `FAIL`** — a test suite can fail via TIMEOUT or CRASH without any `FAIL:` lines in its output. Use:
```bash
./run_tests.sh 2>&1 | grep -E "CRASH|TIMEOUT|FAIL:"
```

Individual `FAIL:` lines inside a suite output look like:
```
FAIL: test description expected=X got=Y
```

### Allowed Testing Methods

All tests must be written in Clojure executed with clojurez or in Zig code. Absolutely forbidden is using perl, python3, JVM-based Clojure, or nodejs in test suites. For integration suite orchestration, bash is allowed.

### Complex Samples (`tests/complex-samples/`)

End-to-end programs with expected output verification:
- Fibonacci (lazy sequences)
- Tower of Hanoi (recursion)
- Namespaces (`-cp -m` usage)
- GC stress test
- Regex GC test

## Build

```bash
zig build                          # all 3 variants
zig build -Doptimize=ReleaseSmall  # specific optimize mode
```

Build copies `src/clj/core.clj` → `src/zig/namespaces/core/clj/core.clj`, `src/clj/string.clj` → `src/zig/namespaces/core/clj/string.clj`, `src/clj/math.clj` → `src/zig/namespaces/core/clj/math.clj`, `src/clj/io.clj` → `src/zig/namespaces/core/clj/io.clj`, `src/clj/test.clj` → `src/zig/namespaces/core/clj/test.clj`, `src/clj/walk.clj` → `src/zig/namespaces/core/clj/walk.clj`, and `src/clj/template.clj` → `src/zig/namespaces/core/clj/template.clj` for `@embedFile`.

## Debugging

### Parse debug

```bash
./zig-out/bin/clojurez --parse-debug myfile.clj
```

Runs the file through the parser only (no evaluation). Reports form nesting, open/close events, and syntax errors. Use this first when a `.clj` file fails to load to isolate syntax errors from runtime errors. For bytecode-level debugging, see `--generate-bytecode` below.

### Bytecode disassembly

```bash
./zig-out/bin/clojurez --generate-bytecode -e '(defn add [a b] (+ a b))'
./zig-out/bin/clojurez --generate-bytecode my_file.clj
```

Compiles Clojure source to bytecode and prints a human-readable disassembly **without executing any code**. This is useful for:

- **Debugging bytecode compilation issues** — see exactly which instructions are generated for a given form
- **Inspecting generated instructions** — verify the bytecode compiler produces correct sequences for arithmetic, comparisons, control flow, and special forms
- **Learning about the bytecode VM** — understand how Clojure expressions map to stack-based opcodes

**Usage examples:**

```bash
# Disassemble a simple function
./zig-out/bin/clojurez --generate-bytecode -e '(defn add [a b] (+ a b))'

# Disassemble an entire file
./zig-out/bin/clojurez --generate-bytecode my_file.clj

# Disassemble an expression
./zig-out/bin/clojurez --generate-bytecode -e '(+ 1 2 3)'

# Multi-arity function (each arity gets its own section)
./zig-out/bin/clojurez --generate-bytecode -e '(defn foo ([] 0) ([x] x) ([x y] (+ x y)))'
```

**Output format:**

Each compiled function or expression produces a section with the following structure:

```
=== Function: add (arity 0, params: [a b]) ===
Constants: 0, Symbols: 2, Instructions: 4
Constant Pool: (empty)
Symbol Pool:
0: a
1: b
Disassembly:
0000: LOAD_VAR\t'a'
0001: LOAD_VAR\t'b'
0002: ADD\t
0003: STOP
```

- **Header** — function name (or "Anonymous function" / "Expression N"), arity index, and parameter list
- **Summary line** — counts of constants, symbols, and instructions
- **Constant Pool** — indexed list of literal values (integers, floats, strings, keywords, etc.) referenced by the bytecode. Integer literals for `PUSH_INT` are shown directly, not via pool indices.
- **Symbol Pool** — indexed list of variable names used by `LOAD_VAR` and `STORE_VAR` instructions
- **Disassembly** — instruction listing with program counter (PC), opcode name, and operand. Jump targets show the destination PC. Constant pool references show both the index and the resolved value.

**When bytecode is generated:**

Only functions with bodies containing bytecode-supported constructs are compiled. Supported constructs include: arithmetic operators (`+`, `-`, `*`, `/`, `rem`, `neg`), comparison operators (`=`, `!=`, `<`, `>`, `<=`, `>=`), and bytecode-supported special forms (`if`, `let`, `loop`/`recur`, `do`).

Functions with unsupported constructs (real function calls like `println`, destructuring, `map`, `filter`, etc.) are skipped with a message:

```
Skipping defn mixed (arity 0, params: [x]): body contains constructs not supported by bytecode compiler
```

Multi-arity functions compile each arity independently — eligible arities are disassembled, ineligible arities are skipped.

**Incompatible options:**

- `--generate-bytecode` cannot be combined with `-m` (main namespace execution)
- `--generate-bytecode` requires either `-e` or a filename as input

### Debug output

```bash
CLJVM_DEBUG=1 ./zig-out/bin/clojurez -e '(+ 1 2 3)'
CLJVM_DEBUG=gc,eval ./zig-out/bin/clojurez -e '(+ 1 2 3)'
```

Categories: `gc`, `eval`, or `all`/`1`/`true` for everything.

### Related debugging tools

| Tool | Purpose |
|------|---------|
| `--parse-debug` | Syntax-level debugging — isolate parser errors from runtime errors |
| `--generate-bytecode` | Bytecode-level debugging — inspect compiled instructions without execution |
| `CLJVM_DEBUG` | Runtime debugging — trace GC, evaluation, and other VM operations |
| `CLJVM_GC_VERBOSE=1` | Verbose GC logging — track allocation and collection |
| `CLJVM_GC_SWEEP=0` | Disable GC sweep — useful for debugging use-after-free issues |

## Documentation Requirements

**Every new function must include a docstring.** The docstring is used to auto-generate API documentation in `doc/`.

### For Clojure functions (`src/clj/core.clj`, `src/clj/string.clj`, `src/clj/io.clj`)

Use the standard Clojure docstring convention — the first string literal after the parameter vector:

```clojure
(defn my-func
  "Returns the result of doing something with x and y.
   Second line provides additional details.
   "
  [x y]
  (+ x y))
```

### For Zig builtins (`src/zig/namespaces/core/`)

Zig builtins don't have docstrings directly — they are wrapped by Clojure functions in `core.clj`/`string.clj`/`io.clj` that carry the docstring. Always add a Clojure wrapper with a docstring:

```clojure
;; In src/clj/core.clj:
(defn my-new-func
  "Description of what the function does.
   "
  [arg1 arg2]
  (zig.core/my-new-func arg1 arg2))
```

### Docstring conventions

- **First line**: Brief one-line description of what the function does
- **Additional lines**: Detailed explanation, parameter descriptions, edge cases
- **No docstring**: Functions without docstrings are excluded from generated documentation
- **Private functions**: Names starting with `-` or ending with `-helper` or `*` are excluded from docs

### Regenerating documentation

Documentation is regenerated automatically on every `zig build`. To regenerate manually:
```bash
./zig-out/bin/clojurez doc/gen_docs.clj
```

## What's Missing

- **Transients** - mutable versions of persistent data structures
- **Spec system** - no `clojure.spec`
- **Java interop** - not applicable for a standalone VM
- **JIT compilation** - we are an interpreting VM (bytecode compilation used for eligible functions)
- **Chunked sequences** - simpler sequence implementation (basic chunk support exists)
- **Full regex in `clojure.string`** - `split`, `replace`, `replace-first` use regex via the built-in engine but some edge cases may differ from JVM Clojure
