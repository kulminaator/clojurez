# Clojure VM in Zig

A minimalistic Clojure virtual machine written in Zig. Supports core data types, special forms, threading macros, sequence operations, destructuring, and a subset of Clojure's standard library — bootstrapped from Clojure source files.

## Features

### Data Types
- `nil`, `true`, `false`
- Integers and floats
- Strings (with escape sequences: `\n`, `\t`, `\\`, `\"`, `\uXXXX`, `\u{XXXXXX}`)
- Symbols (`x`, `foo-bar`, `my-var?`) — supports Unicode characters
- Keywords (`:foo`, `:bar-baz`) — supports Unicode characters
- Lists (`(1 2 3)`)
- Vectors (`[1 2 3]`)
- Maps (`{:a 1 :b 2}`)
- Sets (`#{1 2 3}`)
- Queues (`#queue(1 2 3)`)
- Atoms (`(atom 5)`)

### UTF-8 Support
- All strings are validated as UTF-8 on creation
- `count` on strings returns Unicode code point count (not byte length)
- `nth` on strings indexes by code point (not byte offset)
- `utf8-valid?` checks if a string is valid UTF-8
- Unicode escape sequences: `\uXXXX` (BMP) and `\u{XXXXXX}` (supplementary)
- Symbols and keywords accept Unicode characters
- Full support for Estonian (õäö), emoji (😀😃), Japanese (古池や), and all UTF-8 text

### Special Forms
- `def` — define a global variable
- `defn` — define a named function
- `fn` — create an anonymous function
- `if` — conditional (`(if test then else)`)
- `when` — shorthand for `(if test (do body...))`
- `when-not` — shorthand for `(if (not test) (do body...))`
- `if-not` — if test is false, evaluate then
- `cond` — multi-way conditional
- `case` — multi-way constant dispatch
- `let` — local bindings
- `if-let` — conditional with binding
- `when-let` — when test is truthy, bind and evaluate body
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
- `ns` — namespace declaration (no-op)

### Threading Macros
- `->` — thread-first: inserts value as second argument
- `->>` — thread-last: inserts value as last argument
- `cond->` — conditional thread-first
- `cond->>` — conditional thread-last

### Sequence Functions
- `iterate` — repeatedly apply a function, collecting results
- `map` — apply a function to each element
- `take` — take first n elements
- `partition` — partition a collection into chunks of n
- `count`, `first`, `rest`, `nth`, `concat`, `list`, `vec`

### Destructuring
- Vector destructuring in function parameters: `(fn [[a b]] (+ a b))`
- Nested destructuring: `(fn [[[a b] c]] (+ a b c))`
- Destructuring in `let` with `& rest`: `(let [[a b & rest] [1 2 3 4]] (list a b rest))` → `(1 2 (3 4))`

### Built-in Functions
- **Arithmetic:** `+`, `-`, `*`, `/`, `rem`
- **Comparison:** `=`, `!=`, `not=`, `<`, `>`, `<=`, `>=`, `identical?`
- **Boolean:** `not`, `boolean`
- **Predicates:** `nil?`, `some?`, `zero?`, `pos?`, `neg?`, `even?`, `odd?`, `number?`, `string?`, `list?`, `symbol?`, `keyword?`, `true?`, `false?`, `vector?`, `map?`, `queue?`, `set?`, `coll?`, `sequential?`
- **Sequence predicates:** `some`, `every?`, `not-any?`
- **Strings:** `str`, `utf8-valid?`
- **I/O:** `print`, `println`, `read-line`, `spit`, `slurp`
- **Maps:** `get`, `assoc`, `keys`, `vals`, `dissoc`, `merge`, `contains?`
- **Sets:** `set`, `set?`, `disj`, `contains?`
- **Collections:** `conj`, `pop`, `last`, `reverse`, `range`, `peek`, `empty?`, `not-empty`, `seq`, `count`
- **Sequence operations:** `reduce`, `flatten`, `filter`, `remove`, `every?`, `some`, `distinct?`, `next`, `nthnext`, `drop`, `dorun`, `doall`, `partition`
- **Functional tools:** `apply`, `if-not`, `partial`, `comp`, `fnil`, `juxt`
- **Metaprogramming:** `gensym`
- **Time:** `nano-time`
- **Atoms:** `atom`, `swap!`, `reset!`

### Clojure Core Library
Many common functions are implemented in `core.clj` itself, keeping the Zig VM lean:
- `even?`, `odd?`, `zero?`, `pos?`, `neg?`
- `identity`
- `inc`, `dec`, `abs`, `max`, `min`
- `cons`, `second`, `third`
- `union`, `intersection`, `difference`, `subset?`, `superset?`
- `select-keys`
- `into`, `keep`, `update`
- `when-let` (macro), `time` (macro)

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

;; Sets
(conj #{1 2} 3)               ;; => #{1 2 3}
(disj #{1 2 3} 2)             ;; => #{1 3}

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
├── clj/
│   └── core.clj   — Clojure core library (baked into binary at compile time)
└── zig/
    ├── clj/
    │   └── core.clj   — Copy of core.clj for @embedFile (auto-generated)
    ├── main.zig       — CLI entry point, argument handling
    ├── core_clj.zig   — Embeds core.clj source at compile time
    ├── value.zig      — Core value types and environment
    ├── list.zig       — List implementation
    ├── vector.zig     — Vector implementation
    ├── lexer.zig      — Tokenizer
    ├── parser.zig     — S-expression parser
    ├── eval.zig       — Evaluator / VM core (special forms, threading, sequences)
    ├── core.zig       — Built-in functions (Zig)
    ├── debug_allocator.zig — Memory trace allocator (CLJVM_MEM_TRACE)
    └── repl.zig       — Read-Eval-Print loop

run_tests.sh       — Test runner
GUIDELINES.md      — Development & testing guidelines
```

## Testing

```bash
# Run CLI/integration tests (230 tests, all must complete within 10s each)
# (automatically copies core.clj and builds)
./run_tests.sh

# Run Zig unit tests (10 parser tests)
zig test -fsingle-threaded src/zig/parser.zig

# Build all 3 variants
zig build
```

See [GUIDELINES.md](GUIDELINES.md) for testing standards.

## What Works

- Core data types (nil, bool, int, float, string, symbol, keyword, list, vector, map, set, queue, atom)
- Special forms (def, defn, fn, if, when, cond, let, do, quote, quasiquote, set!, and, or, loop, recur, binding, var, deref, lazy-seq, ns)
- **Namespaces** (`ns` with `:require` and `:as` aliases, classpath via `-cp`, main function via `-m`)
- Macros (`defmacro` with full macro expansion support)
- Threading macros (`->`, `->>`)
- Sequence operations (iterate, map, take, partition, reduce, flatten, filter, remove, every?, some, distinct?, next, nthnext, drop, dorun, doall)
- Vector destructuring in function parameters and `let` (including `& rest`)
- Metaprogramming (`gensym`)
- Arithmetic, comparison, boolean, type check, string, I/O functions (including `spit`/`slurp` for file I/O)
- Map operations (get, assoc, keys, vals, dissoc, merge, contains?)
- Set operations (set, set?, disj)
- Collection operations (conj, pop, last, reverse, range, peek, empty?, not-empty, seq, count)
- Functional tools (apply, if-not, partial, comp, fnil, juxt)
- Atoms (atom, swap!, reset!)
- Time functions (nano-time)
- Clojure core library bootstrapped from `.clj` files (includes when-let, time macros)

## What's Missing

- **Transients** (mutable versions of persistent data structures)
- **Shorthand syntax** (`~` for unquote, `~@` for unquote-splicing, backtick for quasiquote, `@` for deref — use full names instead)
- **Java interop** (not applicable for a standalone VM)

## Design Philosophy

- **Lean VM:** Keep the Zig core minimal — only implement what can't be expressed in Clojure
- **Bootstrap from Clojure:** Build library functions in `.clj` files when possible
- **Small steps:** Incremental development with tests after every change
- **10s timeout:** All tests complete within 10 seconds
- **80%+ coverage:** Target minimum line coverage
