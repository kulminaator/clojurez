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
- `cond` — multi-way conditional
- `let` — local bindings
- `do` — evaluate a sequence of forms
- `quote` / `'` — prevent evaluation
- `set!` — modify a variable
- `and` / `or` — short-circuit logic
- `loop` / `recur` — tail recursion
- `binding` — dynamic variable binding

### Threading Macros
- `->` — thread-first: inserts value as second argument
- `->>` — thread-last: inserts value as last argument

### Sequence Functions
- `iterate` — repeatedly apply a function, collecting results
- `map` — apply a function to each element
- `take` — take first n elements
- `count`, `first`, `rest`, `nth`, `concat`, `list`, `vec`

### Destructuring
- Vector destructuring in function parameters: `(fn [[a b]] (+ a b))`
- Nested destructuring: `(fn [[[a b] c]] (+ a b c))`

### Built-in Functions
- **Arithmetic:** `+`, `-`, `*`, `/`, `rem`
- **Comparison:** `=`, `!=`, `<`, `>`, `<=`, `>=`
- **Boolean:** `not`
- **Type checks:** `nil?`, `number?`, `string?`, `list?`, `symbol?`, `keyword?`, `true?`, `false?`
- **Strings:** `str`, `utf8-valid?`
- **I/O:** `print`, `println`, `read-line`

### Clojure Core Library
Many common functions are implemented in `core.clj` itself, keeping the Zig VM lean:
- `even?`, `odd?`, `zero?`, `pos?`, `neg?`
- `identity`
- `inc`, `dec`, `abs`, `max`, `min`
- `cons`, `second`, `third`

## Build

```bash
zig build-exe -fsingle-threaded src/main.zig
```

## Usage

### REPL

```bash
./main
```

or explicitly:

```bash
./main --repl
```

Type `:quit` or `:exit` to exit.

### Evaluate an Expression

```bash
./main -e '(+ 1 2 3 4)'
./main -e '(defn square [n] (* n n))'
```

### Run a File

```bash
./main my_script.clj
```

### Load Core Library + Run

```bash
./main core.clj -e '(even? 42)'
```

## Examples

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
```

## Samples

### Fibonacci
```bash
./main samples/sample_1_fibonacci/core.clj
```
Output: `(0 1 1 2 3 5 8 13 21 34)`

### Tower of Hanoi
```bash
./main samples/sample_2_hanoi/hanoi/core.clj
```
_(Requires maps, `ns`, `get`, `assoc`, `conj`, `pop`, `last`, `reverse`, `range` — not yet implemented)_

## Project Structure

```
src/
├── main.zig       — CLI entry point, argument handling
├── value.zig      — Core value types and environment
├── list.zig       — List implementation
├── vector.zig     — Vector implementation
├── lexer.zig      — Tokenizer
├── parser.zig     — S-expression parser
├── eval.zig       — Evaluator / VM core (special forms, threading, sequences)
├── core.zig       — Built-in functions (Zig)
└── repl.zig       — Read-Eval-Print loop

core.clj           — Clojure core library (bootstrapped)
run_tests.sh       — Test runner
GUIDELINES.md      — Development & testing guidelines
samples/           — Sample programs
├── sample_1_fibonacci/    — Fibonacci sequence (✓ working)
└── sample_2_hanoi/        — Tower of Hanoi (needs more features)
```

## Testing

```bash
# Run CLI/integration tests (47 tests, all must complete within 10s each)
./run_tests.sh

# Run Zig unit tests (10 parser tests)
zig test -fsingle-threaded src/parser.zig
```

See [GUIDELINES.md](GUIDELINES.md) for testing standards.

## What Works

- Core data types (nil, bool, int, float, string, symbol, keyword, list, vector)
- Special forms (def, defn, fn, if, when, cond, let, do, quote, set!, and, or, loop, recur)
- Threading macros (`->`, `->>`)
- Sequence operations (iterate, map, take)
- Vector destructuring in function parameters
- Arithmetic, comparison, boolean, type check, string, I/O functions
- Clojure core library bootstrapped from `.clj` files

## What's Missing

- **Namespaces** (`ns` declaration with full support)
- **Transients** (mutable versions of persistent data structures)
- **Macros** (code generation at compile time)
- **Java interop** (not applicable for a standalone VM)

## Design Philosophy

- **Lean VM:** Keep the Zig core minimal — only implement what can't be expressed in Clojure
- **Bootstrap from Clojure:** Build library functions in `.clj` files when possible
- **Small steps:** Incremental development with tests after every change
- **10s timeout:** All tests complete within 10 seconds
- **80%+ coverage:** Target minimum line coverage
