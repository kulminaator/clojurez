# Clojure VM in Zig

A minimalistic Clojure virtual machine written in Zig. Supports core data types, special forms, threading macros, sequence operations, destructuring, and a subset of Clojure's standard library — bootstrapped from Clojure source files.

## Features

### Data Types
- `nil`, `true`, `false`
- Integers and floats
- **BigInt** — arbitrary precision integers (literal `123456789012345678901234567890N`)
- **Ratio** — exact rational numbers (`(/ 22 7)` → `22/7`)
- **BigDecimal** — arbitrary precision decimals (literal `123.456M`)
- Strings (with escape sequences: `\n`, `\t`, `\\`, `\"`, `\uXXXX`, `\u{XXXXXX}`)
- Symbols (`x`, `foo-bar`, `my-var?`) — supports Unicode characters
- Keywords (`:foo`, `:bar-baz`) — supports Unicode characters
- Lists (`(1 2 3)`)
- Vectors (`[1 2 3]`)
- Maps (`{:a 1 :b 2}`)
- Sets (`#{1 2 3}`)
- Queues (`#queue(1 2 3)`)
- Atoms (`(atom 5)`)
- Lazy sequences (`(lazy-seq ...)`)
- Cons cells (`(cons 1 (list 2 3))`)

### Garbage Collection
- **Mark-and-sweep GC** — automatic memory management for all runtime values
- Tracked allocations with header-based block management
- Eliminates manual memory management for Clojure values

### Operating system support
- Our code is expected to run the same on every major platform Linux, macOS, Windows
- Do not use functionality or libraries that do not work cross platform
- Always prefer cross platform functions over if-ing around os types and using special methods

### UTF-8 Support
- All strings are validated as UTF-8 on creation
- `count` on strings returns Unicode code point count (not byte length)
- `nth` on strings indexes by code point (not byte offset)
- `utf8-valid?` checks if a string is valid UTF-8
- Unicode escape sequences: `\uXXXX` (BMP) and `\u{XXXXXX}` (supplementary)
- Symbols and keywords accept Unicode characters
- Full support for Estonian (õäö), emoji (😀😃), Japanese (古池や), and all UTF-8 text

### Special Forms
- `def` — define a var in the current namespace
- `defn` — define a named function in the current namespace (supports multi-arity)
- `defmacro` — define a macro (full macro expansion support)
- `fn` — create an anonymous function (supports multi-arity)
- `if` — conditional (`(if test then else)`)
- `when` — shorthand for `(if test (do body...))`
- `when-not` — shorthand for `(if (not test) (do body...))`
- `if-not` — if test is false, evaluate then
- `cond` — multi-way conditional
- `case` — multi-way constant dispatch
- `let` — local bindings
- `if-let` — conditional with binding
- `when-let` — when test is truthy, bind and evaluate body
- `when-some` — when test is not nil, bind and evaluate body
- `do` — evaluate a sequence of forms
- `quote` / `'` — prevent evaluation
- `quasiquote` / `` ` `` — template with unquote (`unquote` / `~`) and unquote-splicing (`unquote-splicing` / `~@`)
- `set!` — modify a variable
- `and` / `or` — short-circuit logic
- `loop` / `recur` — tail recursion (simplified)
- `binding` — dynamic variable binding
- `var` — create a mutable var
- `deref` / `@` — get the value of a var
- `lazy-seq` — create a lazy sequence
- `ns` — namespace declaration (with `:require` and `:as` support)

### Threading Macros
- `->` — thread-first: inserts value as second argument
- `->>` — thread-last: inserts value as last argument
- `cond->` — conditional thread-first
- `cond->>` — conditional thread-last

### Sequence Functions
- `iterate` — repeatedly apply a function, collecting results
- `map` — apply a function to each element
- `mapcat` — map and concat
- `take` — take first n elements
- `take-while` — take while predicate is true
- `take-last` — take last n elements
- `drop` — drop first n elements
- `drop-last` — drop last n elements
- `drop-while` — drop while predicate is true
- `partition` — partition a collection into chunks of n
- `cycle` — repeat collection infinitely (lazy)
- `repeat` / `replicate` — repeat value n times (lazy)
- `split-at` — split collection at index
- `split-with` — split while predicate is true
- `count`, `first`, `rest`, `nth`, `concat`, `list`, `vec`
- `next`, `nthnext`, `last`, `reverse`, `flatten`, `distinct?`
- `dorun`, `doall` — force lazy sequence evaluation
- `sort`, `sort-by` — sort collection (with optional key function)
- `shuffle` — random permutation
- `interpose`, `interleave` — interleave collections

### Destructuring
- Vector destructuring in function parameters: `(fn [[a b]] (+ a b))`
- Nested destructuring: `(fn [[[a b] c]] (+ a b c))`
- Destructuring in `let` with `& rest`: `(let [[a b & rest] [1 2 3 4]] (list a b rest))` → `(1 2 (3 4))`

### Built-in Functions
- **Arithmetic:** `+`, `-`, `*`, `/`, `rem`, `mod`, `quot`, `rationalize`
- **Comparison:** `=`, `!=`, `not=`, `==`, `<`, `>`, `<=`, `>=`, `compare`, `identical?`
- **Boolean:** `not`, `boolean`
- **Predicates:** `nil?`, `some?`, `true?`, `false?`, `zero?`, `pos?`, `neg?`, `even?`, `odd?`, `number?`, `string?`, `list?`, `symbol?`, `keyword?`, `vector?`, `map?`, `queue?`, `set?`, `coll?`, `sequential?`, `fn?`, `empty?`, `not-empty`, `utf8-valid?`
- **Sequence predicates:** `some`, `every?`, `not-any?`
- **Strings:** `str`, `utf8-valid?`
- **I/O:** `print`, `println`, `read-line`, `spit`, `slurp`
- **Maps:** `get`, `assoc`, `keys`, `vals`, `dissoc`, `merge`, `contains?`, `hash-map`, `zipmap`, `get-in`, `assoc-in`, `select-keys`
- **Sets:** `set`, `set?`, `disj`, `contains?`, `union`, `intersection`, `difference`, `subset?`, `superset?`, `hash-set`
- **Collections:** `conj`, `pop`, `last`, `reverse`, `range`, `peek`, `empty?`, `not-empty`, `seq`, `count`, `empty`
- **Sequence operations:** `reduce`, `flatten`, `filter`, `remove`, `every?`, `some`, `distinct?`, `next`, `nthnext`, `drop`, `drop-last`, `drop-while`, `dorun`, `doall`, `partition`, `interpose`, `take-while`, `take-last`, `cycle`, `repeat`, `replicate`, `split-at`, `split-with`, `sort`, `sort-by`, `shuffle`
- **Random:** `rand`, `rand-int`, `rand-nth`
- **Comparator:** `comparator` — create comparator from fn
- **Functional tools:** `apply`, `if-not`, `partial`, `comp`, `fnil`, `juxt`, `trampoline`, `constantly`, `complement`
- **Metaprogramming:** `gensym`
- **Time:** `nano-time`
- **Atoms:** `atom`, `swap!`, `reset!`

### Clojure Core Library
Many common functions are implemented in Clojure source, keeping the Zig VM lean:
- `even?`, `odd?`, `zero?`, `pos?`, `neg?`
- `identity`, `inc`, `dec`, `abs`, `max`, `min`
- `cons`, `second`, `third`
- `into`, `keep`, `update`
- `key`, `val`, `into-array`
- `hash-set` — create set from args
- `when-not`, `when-some`, `when-let`, `when-first` (macros)
- `if-let` (macro), `time` (macro), `doseq` (macro), `for` (macro)

## Build

```bash
# Build all 3 variants (copies core.clj automatically)
zig build

# Binaries are placed in zig-out/bin/:
#   clojurez          — Debug build (full, ~14MB)
#   clojurez-medium   — ReleaseSmall (~400KB)
#   clojurez-mini     — ReleaseSmall + stripped (~400KB)
```

## Usage

### REPL

```bash
./zig-out/bin/clojurez
```

or explicitly:

```bash
./zig-out/bin/clojurez --repl
```

Type `(quit)` or `(exit)` or `CTRL+D` to exit.

### Evaluate an Expression

```bash
./zig-out/bin/clojurez -e '(+ 1 2 3 4)'
./zig-out/bin/clojurez -e '(defn square [n] (* n n))'
```

### Run a File

```bash
./zig-out/bin/clojurez my_script.clj
```

### Namespaces and Classpath

Support for Clojure-style namespaces with classpath-based file loading:

```bash
# Run with classpath and main function
./zig-out/bin/clojurez -cp src -m main
```

This is equivalent to Clojure's:
```bash
java -cp src clojure.main -m main
```

The `-cp` flag accepts colon-separated directories (Unix) or semicolon-separated (Windows).
Namespaces are resolved to files: `hello.hello` → `hello/hello.clj`.

Example with `:require`:
```clojure
;; main.clj
(ns main
  (:require [hello.hello :as h]
            [hello.world :as w]))

(defn -main []
  (println (str (h/get-hello) " " (w/get-world))))
```

### Namespace Architecture

The VM follows Clojure's namespace model. There are no "global" functions — everything lives in a namespace:

- **`user`** — the default namespace. REPL, `-e`, and file execution start here.
- **`clojure.core`** — the public API namespace. All built-in functions and `core.clj` definitions live here. `user` inherits from `clojure.core` by default, so all functions are available without qualification.
- **`zig.core`** — internal implementation namespace. Raw Zig builtins live here. Clojure wrappers in `clojure.core` delegate to `zig.core/` internally.

**Symbol resolution chain:**
```
(+ 1 2) from user namespace:
  user → (not found) → clojure.core → (+ wrapper) → (apply zig.core/+ args) → zig.core → (+ builtin) → 3
```

Qualified names work as expected:
```clojure
user/x          ;; looks up x in user namespace
clojure.core/+  ;; looks up + in clojure.core namespace
zig.core/+      ;; looks up + in zig.core namespace (raw Zig builtin)
```

### Core Functions

Core functions (`inc`, `dec`, `into`, `even?`, `odd?`, `cons`, `update`, etc.) are baked into the binary and always available — no need to load a separate file:

```bash
./zig-out/bin/clojurez -e '(even? 42)'       ;; => true
./zig-out/bin/clojurez -e '(inc 5)'          ;; => 6
./zig-out/bin/clojurez -e '(into [] (list 1 2 3))'  ;; => [1 2 3]
```

### Memory Tracing

The VM includes a built-in memory trace allocator for debugging memory issues. Toggle it via the `CLJVM_MEM_TRACE` environment variable. Off by default with zero overhead.

**Trace to stderr:**
```bash
CLJVM_MEM_TRACE=1 ./zig-out/bin/clojurez -e '(+ 1 2 3)'
```

**Trace to a file:**
```bash
CLJVM_MEM_TRACE=/tmp/mem.log ./zig-out/bin/clojurez -e '(+ 1 2 3)'
```

Each allocation, free, resize, and remap is logged with size, pointer address, and running live memory count. At program exit a summary is printed:

```
=== Memory trace summary ===
  Allocations:     1234
  Frees:           1200
  Net allocs:       34
  Total allocated: 98765 bytes
  Total freed:     95000 bytes
  Peak memory:     12000 bytes
  Current memory:  3765 bytes
=== Memory trace ended ===
```

This is useful for verifying that `def` rebindings, `let` scopes, and function calls properly free unreachable values.

## Examples

```bash
./zig-out/bin/clojurez
```

```clojure
;; Arithmetic
(+ 1 2 3 4)           ;; => 10
(* 6 7)               ;; => 42

;; BigInt arithmetic
(+ 123456789012345678901234567890 987654321098765432109876543210)  ;; => 1111111110111111111011111111100

;; Ratios (exact rational arithmetic)
(/ 22 7)              ;; => 22/7
(+ (/ 1 3) (/ 1 6))   ;; => 1/2

;; Modulo and quotient
(mod -7 3)            ;; => 2  (sign follows divisor)
(rem -7 3)            ;; => -1 (sign follows dividend)
(quot -7 3)           ;; => -2 (truncates toward zero)

;; Numeric equality (type-independent)
(== 1 1.0)            ;; => true
(compare 1 2)         ;; => -1

;; Rationalize
(rationalize 1.5)     ;; => 3/2
(rationalize 0.25)    ;; => 1/4

;; Definitions
(defn factorial [n]
  (if (<= n 1)
    1
    (* n (factorial (- n 1)))))

(factorial 10)        ;; => 3628800

;; Lists and sequences
(def xs (list 1 2 3 4 5))
(first xs)            ;; => 1
(rest xs)             ;; => (2 3 4 5)
(count xs)            ;; => 5

;; Quote
'(1 2 3)              ;; => (1 2 3)

;; Conditionals
(if (> 5 3) "yes" "no")  ;; => "yes"

(cond
  (= 1 2) "no"
  (= 1 1) "yes"
  :else "maybe")         ;; => "yes"

;; Threading macros
(->> [0 1]
     (iterate (fn [[a b]] [b (+ a b)]))
     (map first)
     (take 10))
;; => (0 1 1 2 3 5 8 13 21 34)

;; Destructuring
((fn [[a b]] (+ a b)) [3 4])  ;; => 7
(let [[a b & rest] [1 2 3 4 5]] (list a b rest))  ;; => (1 2 (3 4 5))

;; Sequences
(partition 2 (list 1 2 3 4 5 6))  ;; => ((1 2) (3 4) (5 6)) (lazy)
(doall (partition 2 (list 1 2 3 4 5 6)))  ;; => ((1 2) (3 4) (5 6))

;; Metaprogramming
(gensym)           ;; => G__1
(gensym "tmp")     ;; => tmpG__2

;; Maps
(get {:a 1 :b 2} :a)          ;; => 1
(assoc {:a 1} :b 2)           ;; => {:a 1 :b 2}
(merge {:a 1} {:b 2})         ;; => {:a 1 :b 2}
(get-in {:a {:b 3}} [:a :b])  ;; => 3

;; Sets
(conj #{1 2} 3)               ;; => #{1 2 3}
(disj #{1 2 3} 2)             ;; => #{1 3}
(union #{1 2} #{2 3})         ;; => #{1 2 3}

;; Sequence Operations
(reduce + 0 (list 1 2 3 4))   ;; => 10
(filter (fn [x] (> x 2)) (list 1 2 3 4))  ;; => (3 4)

;; Atoms
(def a (atom 5))              ;; => #atom(5)
(swap! a inc)                 ;; => 6

;; File I/O
(spit "hello.txt" "Hello, World!")  ;; => nil
(slurp "hello.txt")                  ;; => "Hello, World!"
```

## Samples

### Fibonacci
```bash
./zig-out/bin/clojurez tests/complex-samples/sample_1_fibonacci/core.clj
```
Output: `(0 1 1 2 3 5 8 13 21 34)`

### Tower of Hanoi
```bash
./zig-out/bin/clojurez tests/complex-samples/sample_2_hanoi/hanoi/core.clj
```

## Project Structure

```
src/
├── clj/              — Clojure source (core.clj, baked into binary at compile time)
└── zig/
    ├── clj/          — Copy of core.clj for @embedFile (auto-generated)
    ├── namespaces/
    │   └── core/     — Zig builtin implementations (arithmetic, comparison, maps, etc.)
    ├── *.zig         — Core VM modules (eval, lexer, parser, value, gc, etc.)
    └── ...

tests/
├── helpers.sh        — Shared test infrastructure
├── test_*.sh         — Integration test suites (domain-based)
└── complex-samples/  — Sample programs (fibonacci, hanoi, etc.)

run_tests.sh          — Test runner
GUIDELINES.md         — Development & testing guidelines
```

## Testing

**Whenever you make changes to the codebase, you must run BOTH test suites.** Each covers a different layer and neither alone is sufficient to verify correctness.

### 1. Zig Unit Tests

Tests individual functions and modules in isolation:

```bash
zig test -fsingle-threaded src/zig/all_tests.zig
```

### 2. CLI / Integration Tests

Tests the full pipeline — lexer, parser, evaluator, and runtime — through the CLI interface. This script also copies `core.clj` and builds the binary automatically:

```bash
./run_tests.sh
```

### Always Run Both

| Change type | Run Zig tests | Run integration tests |
| ----------- | :-----------: | :-------------------: |
| Lexer / Parser changes | ✅ | ✅ |
| Evaluator / special forms | ✅ | ✅ |
| Core built-in functions | ✅ | ✅ |
| GC / memory management | ✅ | ✅ |
| `core.clj` (Clojure library) | — | ✅ (still run Zig tests too) |
| Any other change | ✅ | ✅ |

```bash
# Quick way to run both in sequence:
zig test -fsingle-threaded src/zig/all_tests.zig && ./run_tests.sh
```

### Build

```bash
# Build all 3 variants (copies core.clj automatically)
zig build
```

See [GUIDELINES.md](GUIDELINES.md) for testing standards and detailed coverage requirements.

## What Works

- Core data types (nil, bool, int, float, bigint, ratio, decimal, string, symbol, keyword, list, vector, map, set, queue, atom, lazy-seq, cons)
- **Garbage collection** (mark-and-sweep, automatic memory management)
- Special forms (def, defn, defmacro, fn, if, when, cond, case, let, do, quote, quasiquote, set!, and, or, loop, recur, binding, var, deref, lazy-seq, ns)
- **Namespaces** (`user` default namespace, `clojure.core` public API, `zig.core` raw builtins, `ns` with `:require` and `:as` aliases, classpath via `-cp`, main function via `-m`)
- **Macros** (`defmacro` with full macro expansion support, when-not, when-some, when-let, when-first, if-let, for, doseq, time)
- Threading macros (`->`, `->>`, `cond->`, `cond->>`)
- Sequence operations (iterate, map, mapcat, take, take-while, take-last, drop, drop-last, drop-while, partition, interpose, reduce, flatten, filter, remove, every?, some, distinct?, next, nthnext, dorun, doall, cycle, repeat, replicate, split-at, split-with, sort, sort-by, shuffle)
- Random functions (rand, rand-int, rand-nth)
- Comparator (comparator)
- Vector destructuring in function parameters and `let` (including `& rest`)
- Metaprogramming (`gensym`)
- Arithmetic (+, -, *, /, rem, mod, quot, rationalize) with bigint/ratio/decimal support
- Comparison (=, !=, not=, ==, <, >, <=, >=, compare, identical?)
- Boolean, type check, string, I/O functions (including `spit`/`slurp` for file I/O)
- Map operations (get, assoc, keys, vals, dissoc, merge, contains?, hash-map, zipmap, get-in, assoc-in, select-keys)
- Set operations (set, set?, disj, union, intersection, difference, subset?, superset?, hash-set)
- Collection operations (conj, pop, last, reverse, range, peek, empty?, not-empty, seq, count, empty)
- Functional tools (apply, if-not, partial, comp, fnil, juxt, trampoline, constantly, complement)
- Atoms (atom, swap!, reset!)
- Time functions (nano-time)
- Clojure core library bootstrapped from `.clj` files

## What's Missing

- **Transients** (mutable versions of persistent data structures)
- **Shorthand syntax** (`~` for unquote, `~@` for unquote-splicing, backtick for quasiquote, `@` for deref — use full names instead)
- **Java interop** (not applicable for a standalone VM)
- **JIT compilation** (we are a parsing/interpreting VM)
- **Chunked sequences** (simpler sequence implementation)
- **Full spec system** (no `s/def`, `s/valid?`, etc.)
- **Protocol/multimethod system**

## Design Philosophy

- **Lean VM:** Keep the Zig core minimal — only implement what can't be expressed in Clojure
- **Bootstrap from Clojure:** Build library functions in `.clj` files when possible
- **Small steps:** Incremental development with tests after every change
- **10s timeout:** All tests complete within 10 seconds
- **80%+ coverage:** Target minimum line coverage
- **GC-managed memory:** All Clojure runtime values managed by garbage collector
