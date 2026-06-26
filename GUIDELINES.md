# Development & Testing Guidelines

## Overview

This document defines the development workflow, testing standards, and procedures for the ClojureZ project.

---

## 0. Design Philosophy - Minimal Zig, Maximal Clojure

**Things that can be expressed in Clojure should be expressed in Clojure, not Zig.**

Our design is a **minimal Zig VM** with **Clojure code on top of it**.

### How to decide where to implement a feature

1. **Can it be expressed in Clojure?** If yes, implement it in `src/clj/core.clj` or another matching namespace clojure file using only functions and forms already available.
2. **Does it require OS-level access?** (file I/O, stdin/stdout, process control) If yes, implement it in Zig as a built-in function.
3. **Does it require new value types or evaluation rules?** If yes, implement it in Zig as part of the VM core.
4. **When in doubt, prefer Clojure.** A Zig built-in is harder to test, harder to read, and harder to modify than a Clojure function.

### Examples

| Feature | Where | Why |
|---------|-------|-----|
| `+`, `-`, `*`, `/` | Zig | Fundamental arithmetic, used by everything |
| `print`, `println`, `read-line`, `spit`, `slurp` | Zig | Requires OS I/O |
| `atom`, `swap!`, `reset!` | Zig | Requires mutable state management |
| `inc`, `dec` | Clojure | Expressible as `(+ n 1)`, `(- n 1)` |
| `even?`, `odd?`, `zero?` | Clojure | Expressible with `rem` and `=` |
| `cons`, `second`, `third` | Clojure | Built on `concat`, `first`, `rest` |
| `max`, `min`, `abs` | Clojure | Built on comparison and arithmetic |
| `into`, `keep`, `update` | Clojure | Built on `reduce`, `conj`, `assoc`, `get`, `filter` |
| `union`, `intersection`, `difference` | Clojure | Built on `conj`, `reduce`, `contains?` |

### Rules

- **Every new Zig built-in must be justified** by explaining why it cannot be implemented in Clojure.
- **Review existing Clojure functions first** before adding a new Zig function.
- **Keep `src/zig/namespaces/` lean** - each function should do one thing that Clojure cannot do.
- **Keep `src/clj/` rich** - this is where most library functions live.
- **`src/clj/core.clj` is auto-loaded** - embedded into the binary at compile time. All functions defined here are always available.
- **Build copies `.clj` files automatically** - always edit `src/clj/core.clj` (source of truth), never edit copied files under `src/zig/`.

---

## 1. Code Size Limits

**No Zig source file may exceed 1,000 lines. No single function may exceed 80 lines.**

These are hard limits. When a file or function approaches its limit, it must be split before more functionality is added.

### File Size Limit: 1,000 lines

- Count all lines including imports, comments, blank lines, and tests.
- When a file reaches **800 lines**, plan a split. At **1,000 lines**, a split is mandatory.
- Split by **logical domain**: group related functions together.
- Place domain-specific modules in a subdirectory (e.g., `core/arithmetic.zig`, `core/maps.zig`).
- The parent file becomes a coordinator that imports sub-modules and delegates registration.

### Function Size Limit: 80 lines

- Count all lines from the `fn` signature to the closing `}`.
- When a function reaches **60 lines**, look for sub-tasks to extract into helper functions.
- Extract helpers that:
  - Handle a distinct sub-task (argument validation, type switching, result construction)
  - Are reusable across multiple functions
  - Improve readability by giving a name to a complex operation
- Mark extracted helpers as `fn` (private) unless needed by other modules.

### Rationale

- **Readability**: A developer should understand a function in one screen and a file in one sitting.
- **Testability**: Smaller functions and files are easier to test in isolation.
- **Maintainability**: Changes are localized - modifying one feature doesn't risk breaking unrelated code.
- **Code review**: Smaller diffs are faster to review and less error-prone.

---

## 2. Timeout Policy

**All tests must complete within 10 seconds.**

### Enforcement

- **CLI tests**: Use `tests/timeout.sh` when spawning the VM process.
  ```bash
  tests/timeout.sh 10 ./zig-out/bin/clojurez -e '(+ 1 2)'
  ```
- **REPL tests**: Never pipe unbounded input into the REPL. Always provide finite input with an explicit exit command.
  ```bash
  tests/timeout.sh 10 ./zig-out/bin/clojurez --repl < input.clj
  ```
- **Unit tests**: Use Zig's built-in test timeout or wrap long-running tests with explicit guards.

### Rationale

The REPL is inherently interactive and can loop forever if fed malformed input or if a bug causes infinite evaluation. The timeout prevents CI/CD pipelines from hanging and developer machines from locking up.

---

## 3. Code Coverage Requirements

**Minimum target: 80% line coverage across the entire codebase.**

### Measuring Coverage

```bash
zig build-exe -femit-coverage src/zig/main.zig
llvm-cov show ...
```

### Coverage Exclusions

Acceptable exclusions (documented with `// coverage: excluded`):
- Panic handlers and unrecoverable error paths
- Platform-specific code paths not applicable to the test environment
- Debug-only code paths

---

## 4. Test Categories

### 4.1 Unit Tests

Test individual functions in isolation. Place tests at the bottom of each source file using Zig's `test` blocks:

```zig
test "core::plus: returns integer for integer args" {
    const result = try core_plus(&dummy, args, &env);
    try expect(result.type == .integer);
    try expect(result.int_val == 5);
}
```

**Requirements:**
- Each test must be self-contained (no shared mutable state between tests)
- Tests must not depend on execution order
- Use descriptive names: `test "<module>::<function>: <description>"`

### 4.2 Clojure-based Tests (`tests/clj/test_*.clj`)

Test the full pipeline (lexer → parser → evaluator → runtime) through the VM. Use the `check`/`check-true`/`check-false` helper from `tests/clj/clj_test_helper.clj`:

```clojure
(check "addition" (+ 1 2) 3)
(check-true "truthy" some-value)
(check-false "falsy" nil)
```

### 4.3 Shell-based Tests (`tests/test_*.sh`)

Integration tests for I/O, namespaces, file execution, `-cp -m`, REPL behavior, and complex samples.

### 4.4 Complex Samples (`tests/complex-samples/`)

End-to-end programs with `expected_output.txt` verification. Each sample serves as a regression test for a specific feature area.

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

### Shell Tests

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

---

## 7. Regression Tests

When a bug is fixed, add a test that reproduces the bug before the fix. Name it:

```
test "regression: <bug_description_or_issue_number>"
```

---

## 8. Test Execution

### Running All Tests

```bash
# Zig unit tests
zig test -fsingle-threaded src/zig/all_tests.zig

# CLI/integration tests (builds + runs everything)
./run_tests.sh

# Specific Clojure test suite
./run_tests.sh test_arithmetics
```

### Running Both

```bash
zig test -fsingle-threaded src/zig/all_tests.zig && ./run_tests.sh
```

### Sample Program Verification

```bash
diff <(./zig-out/bin/clojurez tests/complex-samples/sample_1_fibonacci/core.clj 2>&1 | tail -1) \
     <(cat tests/complex-samples/sample_1_fibonacci/expected_output.txt)
```

A sample passes if the diff produces no output.

---

## 9. Anti-Patterns

### Never Do This

- **Infinite loops in tests**: Always use timeouts
- **Shared mutable state**: Each test must be independent
- **Sleep-based synchronization**: Never use `sleep` to wait for results
- **Commented-out tests**: Either fix the test or remove it
- **Ignoring errors**: Always assert or handle errors in tests
- **`@panic("OOM")`**: Propagate errors through `anyerror!` return types instead
- **Silent truncation**: Never silently truncate data (e.g., fixed-size stack buffers for variable-length input)
- **Duplicated logic**: Extract shared helpers instead of copy-pasting code

### Do This Instead

- Use `tests/timeout.sh` for all external process tests
- Set up and tear down test fixtures explicitly
- Use deterministic test data
- Keep tests fast (<1s for unit tests, <10s for integration tests)
- Document flaky tests and fix them promptly
- Return errors and let callers decide how to handle them

---

## 10. Incremental Development

### Split Tasks into Small Steps

**Always break coding tasks into small, incremental steps with clear, verifiable goals.** Never attempt to implement a large feature in a single pass.

#### How to Split Tasks

1. **Define the end goal** clearly before writing any code
2. **Break it into sub-tasks** that each produce a compileable, testable increment
3. **Each step should be small enough** to implement and verify in under 30 minutes
4. **Each step must compile** and pass existing tests before moving to the next

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
3. Run tests - verify nothing broke
4. Refactor if needed (tests still pass)
5. Repeat
```

#### How Often to Run Tests

| Activity | When to Run Tests |
|----------|-------------------|
| Adding a new function | Immediately after writing it |
| Modifying existing logic | Before and after the change |
| Merging two branches | After merge, before continuing |
| Every 15–30 minutes of coding | At minimum, even if nothing "changed" |
| Before taking a break | Always |

#### Practical Rules

- **Compile often**: If you can't compile, you can't test. Fix compile errors immediately.
- **Test often**: Run `zig test` and `./run_tests.sh` after every logical unit of work.
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

## 11. Debugging Practices

### GC Debugging

- **Suspected GC bug**: Disable sweep with `CLJVM_GC_SWEEP=0`. If the problem disappears, the issue was likely caused by the GC freeing objects still in use.
- **Memory leak**: With sweep disabled, unreachable objects accumulate. Compare GC stats before and after.
- **Pointer debugging**: Enable verbose mode with `CLJVM_GC_VERBOSE=1` or set `gc_instance.verbose = true` in code.

### Parse Debugging

**Always use `--parse-debug` first** when a `.clj` file fails to load. It isolates syntax errors from runtime errors:

```bash
./zig-out/bin/clojurez --parse-debug myfile.clj
```

### Memory Tracing

```bash
CLJVM_MEM_TRACE=1 ./zig-out/bin/clojurez -e '(+ 1 2 3)'       # stderr
CLJVM_MEM_TRACE=/tmp/mem.log ./zig-out/bin/clojurez -e '...'  # file
```

### Debug Output

```bash
CLJVM_DEBUG=1 ./zig-out/bin/clojurez -e '(+ 1 2 3)'           # all categories
CLJVM_DEBUG=gc,eval ./zig-out/bin/clojurez -e '(+ 1 2 3)'     # specific
```

Categories: `gc`, `eval`, or `all`/`1`/`true` for everything.

### General Advice

- **Add debug statements** instead of making blind guesses. Quick debug executions are more helpful than endless thoughts.
- **Run miniature Clojure code** to verify behavior instead of making hypotheses.
- **Prefer small iterations** of solutions with frequent testing over writing massive amounts of code blindly.
- **Use the real Clojure** installed on the machine for comparison when needed.

---

## Summary

| Rule | Requirement |
|------|-------------|
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

## Appendix: Test Requirements

**All tests must pass.** Both CLI/integration tests and Zig unit tests.
