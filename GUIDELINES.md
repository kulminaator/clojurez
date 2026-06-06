# Development & Testing Guidelines

## Overview

This document defines the development workflow, testing standards, and procedures for the Clojure VM project. All contributors must follow these guidelines to ensure code quality, reliability, and maintainability.

---

## 0. Design Philosophy — Minimal Zig, Maximal Clojure

**Things that are possible to implement purely with Clojure code should be implemented purely with Clojure code, not with Zig code.**

Our design is a **minimal Zig VM** with **Clojure code on top of it**.

### How to decide where to implement a feature

1. **Can it be expressed in Clojure?** If yes, implement it in `core.clj` using only functions and forms already available.
2. **Does it require OS-level access?** (file I/O, stdin/stdout, process control) If yes, implement it in Zig as a built-in function.
3. **Does it require new value types or evaluation rules?** If yes, implement it in Zig as part of the VM core.
4. **When in doubt, prefer Clojure.** A Zig built-in is harder to test, harder to read, and harder to modify than a Clojure function.

### Examples

| Feature | Where | Why |
| ------- | ----- | --- |
| `+`, `-`, `*`, `/` | Zig | Fundamental arithmetic, used by everything |
| `print`, `println`, `read-line`, `spit`, `slurp` | Zig | Requires OS I/O |
| `atom`, `swap!`, `reset!` | Zig | Requires mutable state management |
| `inc`, `dec` | Clojure | Expressible as `(+ n 1)`, `(- n 1)` |
| `even?`, `odd?`, `zero?` | Clojure | Expressible as `(= (rem n 2) 0)` etc. |
| `cons`, `second`, `third` | Clojure | Built on `concat`, `first`, `rest` |
| `max`, `min`, `abs` | Clojure | Built on comparison and arithmetic |
| `into` | Clojure | Built on `reduce`, `conj` |
| `update`, `keep` | Clojure | Built on `assoc`, `get`, `reduce`, `filter` |
| `union`, `intersection`, `difference` | Clojure | Built on `conj`, `reduce`, `contains?` |

### Rules

- **Every new Zig built-in must be justified** by explaining why it cannot be implemented in Clojure.
- **Review existing Clojure functions first** before adding a new Zig function — you might be able to compose existing ones.
- **Keep `core.zig` lean** — each function should do one thing that Clojure cannot do.
- **Keep `core.clj` rich** — this is where most library functions live.
- **`core.clj` is auto-loaded** — it is embedded into the binary at compile time and loaded silently on startup. All functions defined in `core.clj` are always available to the user without any explicit loading.
- **Build copies `core.clj`** — the build process copies `src/clj/core.clj` to `src/zig/clj/core.clj` so `@embedFile` can find it. Always edit `src/clj/core.clj` (the source of truth), never `src/zig/clj/core.clj`.

---

## 1. Code Size Limits

**No Zig source file may exceed 1,000 lines. No single function may exceed 80 lines.**

These are hard limits. When a file or function approaches its limit, it must be split before more functionality is added.

### File Size Limit: 1,000 lines

- Count all lines including imports, comments, blank lines, and tests.
- When a file reaches **800 lines**, plan a split. At **1,000 lines**, a split is mandatory.
- Split by **logical domain**: group related functions together (e.g., arithmetic, comparison, I/O, maps, sets).
- Place domain-specific modules in a subdirectory (e.g., `core/arithmetic.zig`, `core/maps.zig`).
- The parent file becomes a coordinator that imports sub-modules and delegates registration.

### Function Size Limit: 80 lines

- Count all lines from the `fn` signature to the closing `}`.
- When a function reaches **60 lines**, look for sub-tasks to extract into helper functions.
- Extract helpers that:
  - Handle a distinct sub-task (e.g., argument validation, type switching, result construction)
  - Are reusable across multiple functions
  - Improve readability by giving a name to a complex operation
- Mark extracted helpers as `fn` (private) unless they are needed by other modules, in which case place them in a shared `helpers.zig`.

### Rationale

- **Readability**: A developer should be able to understand a function in one screen and a file in one sitting.
- **Testability**: Smaller functions and files are easier to test in isolation.
- **Maintainability**: Changes are localized — modifying one feature doesn't risk breaking unrelated code.
- **Code review**: Smaller diffs are faster to review and less error-prone.

### Enforcement

- These limits should be checked during code review.
- If a file or function exceeds its limit, the review should request a split before merging.

---

## 2. Timeout Policy

**All tests must complete within 10 seconds.** This applies to:

- Unit tests
- Integration tests
- CLI / end-to-end tests
- REPL interaction tests

### Enforcement

- **CLI tests**: Use a 10-second timeout when spawning the VM process.
  ```bash
  timeout 10s ./zig-out/bin/clojurez -e '(+ 1 2)'
  ```
- **REPL tests**: Never pipe unbounded input into the REPL. Always provide a finite input with an explicit exit command (`:quit` or `:exit`) and use a timeout.
  ```bash
  timeout 10s ./zig-out/bin/clojurez --repl < input.clj
  ```
- **Unit tests**: Use Zig's built-in test timeout or wrap long-running tests with explicit guards.

### Rationale

The REPL is inherently interactive and can loop forever if fed malformed input or if a bug causes infinite evaluation. The 10-second timeout prevents:

- CI/CD pipelines from hanging indefinitely
- Developer machines from locking up during local test runs
- Resource exhaustion from runaway processes

---

## 3. Code Coverage Requirements

**Minimum target: 80% line coverage across the entire codebase.**

### Coverage by Module

| Module                        | Minimum Coverage | Notes                              |
| ----------------------------- | ---------------- | ---------------------------------- |
| `lexer.zig`                   | 90%              | Tokenization is foundational       |
| `parser.zig`                  | 90%              | Parsing is foundational            |
| `value.zig`                   | 95%              | Core data structures               |
| `eval.zig`                    | 85%              | Evaluator logic, special forms     |
| `core.zig`                    | 80%              | Coordinator + higher-order fns     |
| `core/arithmetic.zig`         | 80%              | +, -, *, /, rem                    |
| `core/comparison.zig`         | 80%              | =, !=, <, >, <=, >=, not           |
| `core/type_predicates.zig`    | 80%              | nil?, number?, string?, etc.       |
| `core/strings.zig`            | 80%              | str, utf8-valid?                   |
| `core/sequences.zig`          | 80%              | count, first, rest, nth, list, vec |
| `core/seq_ops.zig`            | 80%              | map, reduce, filter, flatten, etc. |
| `core/maps.zig`               | 80%              | get, assoc, keys, vals, merge      |
| `core/sets.zig`               | 80%              | set, set?, disj                    |
| `core/collections.zig`        | 80%              | conj, pop, last, reverse, range    |
| `core/io.zig`                 | 80%              | print, println, spit, slurp        |
| `core/atoms.zig`              | 80%              | atom, swap!, reset!                |
| `core/eval_helpers.zig`       | 80%              | Shared callBuiltin/evalForm        |
| `core/helpers.zig`            | 80%              | Shared numeric helpers             |
| `repl.zig`                    | 70%              | Hard to test interactively         |
| `main.zig`                    | 80%              | CLI argument handling              |
| `list.zig`                    | 90%              | Collection utilities               |
| `vector.zig`                  | 90%              | Collection utilities               |

### Measuring Coverage

Use Zig's built-in code coverage tools:

```bash
# Build with coverage instrumentation
cp src/clj/core.clj src/zig/clj/core.clj && zig build-exe -femit-coverage src/zig/main.zig

# Run tests and generate coverage report
llvm-cov show ...
```

Or use a coverage wrapper script that runs the full test suite and reports results.

### Coverage Exclusions

The following are acceptable exclusions (documented with `// coverage: excluded`):

- Panic handlers and unrecoverable error paths
- Platform-specific code paths not applicable to the test environment
- Debug-only code paths

---

## 4. Test Categories

### 3.1 Unit Tests

Test individual functions in isolation. Place tests at the bottom of each source file using Zig's `test` blocks.

```zig
test "plus with two arguments" {
    const result = try core_plus(&dummy, args, &env);
    try expect(result.type == .integer);
    try expect(result.int_val == 5);
}
```

**Requirements:**
- Each test must be self-contained (no shared mutable state between tests)
- Tests must not depend on execution order
- Use descriptive test names: `test "fn_name: condition"`

### 3.2 Integration Tests

Test the interaction between multiple modules (e.g., lexer → parser → evaluator). These verify that the full pipeline works correctly.

```bash
# Example: test a full expression through the CLI
timeout 10s ./zig-out/bin/clojurez -e '(defn add [a b] (+ a b)) (add 3 4)'
```

### 3.3 CLI / End-to-End Tests

Test the command-line interface behavior:

- Argument parsing (`-e`, `--eval`, `--repl`, `-h`, `--help`)
- File execution
- Exit codes
- Error messages

### 3.4 REPL Tests

Test REPL behavior with controlled, finite input:

```bash
# Create a test input file
cat > /tmp/repl_test.clj << 'EOF'
(+ 1 2)
(defn square [n] (* n n))
(square 5)
:quit
EOF

# Run with timeout
timeout 10s ./zig-out/bin/clojurez --repl < /tmp/repl_test.clj
```

---

## 5. Test Naming Conventions

### Unit Tests (Zig `test` blocks)

```
test "<module>::<function>: <description>"
```

Examples:
- `test "lexer::nextToken: parses integer"`
- `test "parser::parse: handles nested lists"`
- `test "eval::def: binds symbol in environment"`
- `test "core::plus: returns integer for integer args"`

### CLI / Integration Tests (Shell scripts)

```
test_<feature>_<scenario>()
```

Examples:
- `test_cli_eval_simple_expression()`
- `test_cli_file_execution()`
- `test_repl_basic_interaction()`

---

## 6. Error Handling Tests

Every public function must have tests for:

1. **Happy path**: Normal, expected input
2. **Edge cases**: Empty inputs, single elements, maximum sizes
3. **Error cases**: Invalid input, type mismatches, out-of-memory

Example:
```zig
test "core::div: division by zero" {
    const result = core_div(&dummy, args, &env);
    try expectError(error.DivisionByZero, result);
}
```

---

## 7. Regression Tests

When a bug is fixed, add a test that reproduces the bug before the fix. Name it:

```
test "regression: <bug_description_or_issue_number>"
```

This ensures the bug never reappears.

---

## 8. Test Execution

### Running All Tests

```bash
# Run CLI/integration tests (47 tests)
./run_tests.sh

# Run Zig unit tests (10 parser tests)
zig test -fsingle-threaded src/zig/parser.zig
```

### Sample Program Verification

Sample programs in `tests/complex-samples/` serve as integration tests. Each sample has:
- Source code (`.clj` files)
- Expected output (`expected_output.txt`)

Verify samples match expected output:

```bash
# Run a sample and compare output
diff <(./zig-out/bin/clojurez samples/sample_1_fibonacci/core.clj 2>&1 | tail -1) \
     <(cat samples/sample_1_fibonacci/expected_output.txt)
```

A sample passes if the diff produces no output.

### CI/CD

Every pull request must:
1. Pass all Zig unit tests (`zig test`)
2. Pass all CLI/integration tests (`./run_tests.sh`)
3. Pass all sample program verifications (diff against expected output)
4. Maintain ≥80% code coverage
5. Complete within the timeout budget

---

## 9. Anti-Patterns

### Never Do This

- **Infinite loops in tests**: Always use timeouts for REPL or file-based tests
- **Shared mutable state**: Each test must be independent
- **Sleep-based synchronization**: Never use `sleep` to wait for results
- **Commented-out tests**: Either fix the test or remove it
- **Ignoring errors**: Always assert or handle errors in tests

### Do This Instead

- Use timeouts for all external process tests
- Set up and tear down test fixtures explicitly
- Use deterministic test data
- Keep tests fast (<1s for unit tests, <10s for integration tests)
- Document flaky tests and fix them promptly

---

## 10. Test Data

Store test fixtures in `tests/fixtures/`:

```
tests/
├── fixtures/
│   ├── simple.clj          # Simple expressions
│   ├── functions.clj       # Function definitions and calls
│   ├── control_flow.clj    # if, when, cond
│   ├── data_structures.clj # Lists, vectors, maps
│   └── errors.clj          # Error cases
├── unit/
│   ├── test_lexer.zig
│   ├── test_parser.zig
│   └── test_eval.zig
└── integration/
    ├── test_cli.sh
    └── test_repl.sh
```

---

## 11. Coverage Reporting

Generate coverage reports regularly:

```bash
# Generate coverage HTML report
./scripts/coverage.sh

# View report
open coverage/index.html
```

The coverage report should be part of the CI/CD pipeline and posted as a comment on pull requests.

---

## 12. Incremental Development

### Split Tasks into Small Steps

**Always break coding tasks into small, incremental steps with clear, verifiable goals.** Never attempt to implement a large feature in a single pass.

#### How to Split Tasks

1. **Define the end goal** clearly before writing any code
2. **Break it into sub-tasks** that each produce a compileable, testable increment
3. **Each step should be small enough** to implement and verify in under 30 minutes
4. **Each step must compile** and pass existing tests before moving to the next

#### Example: Implementing a New Special Form

Instead of writing the entire `let` implementation at once:

1. Add the `let` keyword recognition in the evaluator (no logic yet)
2. Parse the bindings list structure
3. Implement single-variable binding
4. Implement multi-variable binding
5. Implement the body evaluation
6. Add error handling for malformed input
7. Add tests for each case

#### Task Checklist

Before starting a task, ask:
- [ ] Can I describe the expected behavior of this step in one sentence?
- [ ] Can I write a failing test for this step before implementing it?
- [ ] Will this step compile independently?
- [ ] If this step fails, can I easily identify what went wrong?

### Move in Small Iterative Steps

**Iterate frequently. Run tests after every meaningful change.**

#### The Iteration Cycle

```
1. Write a failing test (or identify the behavior to implement)
2. Implement the minimal code to make it pass
3. Run tests — verify nothing broke
4. Refactor if needed (tests still pass)
5. Repeat
```

#### How Often to Run Tests

| Activity | When to Run Tests |
| ---- | ---- |
| Adding a new function | Immediately after writing it |
| Modifying existing logic | Before and after the change |
| Merging two branches | After merge, before continuing |
| Every 15–30 minutes of coding | At minimum, even if nothing "changed" |
| Before taking a break | Always |

#### Practical Rules

- **Compile often**: If you can't compile, you can't test. Fix compile errors immediately.
- **Test often**: Run `zig test` or `./run_tests.sh` after every logical unit of work.
- **Small commits**: Each commit should represent one small, verifiable change.
- **No zombie code**: Don't carry around broken or untested code for more than one iteration.
- **Verify before proceeding**: Never start step N+1 until step N compiles and passes tests.

#### Signs You're Moving Too Fast

- You've been coding for 30+ minutes without running tests
- You can't describe what the current change does in one sentence
- Multiple files are changed without intermediate verification
- You're "hoping" something works instead of verifying it does
- The code doesn't compile and you're making more changes to fix it

---

## Summary

| Rule | Requirement |
| ---- | ----------- |
| Design | Minimal Zig VM, Clojure code on top |
| File size | Max 1,000 lines per `.zig` file |
| Function size | Max 80 lines per function |
| Task size | Small, verifiable increments |
| Iteration | Test after every meaningful change |
| Compile | Fix errors immediately, never accumulate |
| Timeout | 10 seconds max per test |
| Coverage | 80% minimum line coverage |
| Independence | No shared state between tests |
| Error handling | Test both success and failure paths |
| Naming | Descriptive, module-prefixed names |
| Regression | Every bug fix gets a test |
| Samples | Verify against expected output |

---

## Appendix: Current Test Status

| Category | Count | Status |
|----------|-------|--------|
| CLI/Integration tests | 230 | All passing |
| Zig unit tests (parser) | 10 | All passing |
| Fibonacci sample | 1 | Passing |
| Hanoi sample | 1 | Passing |
| **Total** | **242** | **242/242 passing** |

### Test Categories (run_tests.sh)

- Arithmetic (7): `+`, `-`, `*`, `/`, division with floats, `rem`
- Comparison (6): `=`, `!=`, `<`, `>`, `<=`, `>=`
- Boolean (5): `true`, `false`, `nil`, `not`
- Strings (2): literals, `str`
- Type checks (5): `nil?`, `number?`, `string?`, `list?`, etc.
- Sequences (6): `list`, `vec`, `count`, `first`, `rest`, `nth`
- Special forms (5): `def`, `if`, `quote`, `do`
- Functions (2): `fn` calls, `defn`
- I/O (1): `print`
- Thread macros (2): `->>`, `->`
- Sequence functions (3): `iterate`, `map`, `take`
- Destructuring (2): vector, nested vector
- Maps (5): literal, get, assoc
- Collections (5): conj, pop, last, reverse, range
- Namespace (1): `ns` declaration
- Sets (12): literal, empty, set, set?, conj, disj, set-as-fn, count, equality
- Queues (7): literal, empty, conj, pop, peek, queue?, count
- Map enhancements (12): keys, vals, dissoc, merge, contains?, map-as-fn, count
- Collection predicates (14): empty?, not-empty, seq, coll?, sequential?, vector?, map?, next, nthnext
- Sequence operations (11): reduce, into, flatten, filter, remove, every?, some, distinct?, nthnext
- Core library (20): update, if-not, drop, apply, comp, partial, fnil, juxt, atom, identity, even?, odd?, zero?, pos?, neg?, abs, max, min, cons, second, third
- File I/O (6): spit, slurp, spit integer, slurp integer, slurp with str, slurp nonexistent
- UTF-8 strings (42): estonian, emoji, japanese, unicode escapes, utf8-valid?, equality, type checks, print, nth, complex expressions, lists/vectors/maps with UTF-8
- Fibonacci sample (1): full pipeline verification
- Hanoi sample (1): full pipeline verification
