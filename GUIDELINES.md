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
| `future`, `promise`, `deliver` | Zig | Requires thread spawning and atomic state |
| `stat`, `list-dir`, `sh-execute` | Zig | Requires OS filesystem / process APIs |
| `inc`, `dec` | Clojure | Expressible as `(+ n 1)`, `(- n 1)` |
| `even?`, `odd?`, `zero?` | Clojure | Expressible with `rem` and `=` |
| `cons`, `second`, `third` | Clojure | Built on `concat`, `first`, `rest` |
| `max`, `min`, `abs` | Clojure | Built on comparison and arithmetic |
| `into`, `keep`, `update` | Clojure | Built on `reduce`, `conj`, `assoc`, `get`, `filter` |
| `union`, `intersection`, `difference` | Clojure | Built on `conj`, `reduce`, `contains?` |
| `sh`, `with-open`, `copy`, `line-seq` | Clojure (`zig.io`) | Protocol-based wrappers around Zig builtins |

### Rules

- **Every new Zig built-in must be justified** by explaining why it cannot be implemented in Clojure.
- **Review existing Clojure functions first** before adding a new Zig function.
- **Keep `src/zig/namespaces/` lean** - each function should do one thing that Clojure cannot do.
- **Keep `src/clj/` rich** - this is where most library functions live.
- **`src/clj/core.clj` is auto-loaded** - embedded into the binary at compile time. All functions defined here are always available.
- **Build copies `.clj` files automatically** - always edit `src/clj/core.clj` (source of truth), never edit copied files under `src/zig/`.

---

## 0.5 Thread Safety Requirements

**All Zig code that can be reached during evaluation must be thread-safe.**

The VM supports multithreading via `future` and `future-call`, which spawn detached OS threads that execute Clojure code concurrently. This means:

1. **No shared mutable global state** — Do not introduce global variables that are written by one thread and read by another without synchronization. If you must use globals, use `std.atomic.Value` or protect with a mutex.
2. **GC operations are already thread-safe** — The GC block list uses an atomic spinlock (`block_mutex`). The slab allocator uses per-slab spinlocks. You do not need to add extra locking around GC alloc/free calls.
3. **Child threads must call `threadDone()` on exit** — This releases the `gc_lock` and decrements `active_thread_count`. See `threading.zig` for the pattern.
4. **Auto-GC is disabled in child threads** — Short-lived threads set `gc.auto_gc_active = false` to avoid triggering collection while the `gc_lock` is held. The main thread performs GC on behalf of all threads.
5. **Atomic state for future/promise** — Use `std.atomic.Value(u32)` with `.release`/`.acquire` ordering for state transitions. The `FutureData` and `PromiseData` structs demonstrate the pattern.
6. **Env cloning for child threads** — Never share an `Env` across threads. Clone it with `env.clone(allocator)` before passing to a child thread's evaluation.
7. **Wrapped handles are not thread-safe** — Stream handles (`StreamHandle`) and process handles (`ProcessHandle`) stored as `.wrapped` values are not designed for concurrent access from multiple threads. Document this in function docs.
8. **When adding new built-in functions** — Ask: "Can this function be called from inside a `future`?" If yes, it must be thread-safe.

### Thread Safety Checklist for New Built-in Functions

- [ ] Does the function read or write any global state?
- [ ] Does the function allocate memory through the GC? (safe — GC is thread-safe)
- [ ] Does the function spawn threads? (must acquire `gc_lock`, call `threadDone()`)
- [ ] Does the function store results in shared structures? (use atomics or clone)
- [ ] Is the function's documentation clear about thread safety?

### Debugging Thread Safety Issues

- **Race conditions**: Run the same code multiple times. Non-deterministic failures often indicate races.
- **Use `CLJVM_GC_SWEEP=0`** to rule out GC-related issues when debugging crashes in multithreaded code.
- **Add debug prints with thread IDs**: `std.log.info("thread {d}: ...", .{std.Thread.getCurrentId()})`
- **Keep it simple**: Prefer atomic operations over mutexes where possible. The `FutureData`/`PromiseData` pattern (atomic state + single-writer result) is the model to follow.

---

## 0.6 GC Memory Invariant

**All Clojure value data MUST come from the GC allocator. Nothing must be allocated from the Zig stack.**

This is a hard, non-negotiable rule. Values can be passed to other threads, captured in closures, and stored in parent frames — stack memory would be freed, causing use-after-free.

### How the invariant is enforced

The `Value` type uses private wrapper types (e.g., `GcStr`) to make it **compile-time impossible** to construct heap-backed fields from non-GC memory:

- `string`, `symbol`, `keyword`, `regex` fields use `GcStr` — a private struct only constructable through factory functions in `value.zig`
- Code outside `value.zig` that tries `Value{ .string = some_slice }` gets a compile error: `GcStr` is not accessible

### Rules

- **Use factory functions**: `stringValue()`, `symValue()`, `keywordValue()`, `regexValue()`, `listValue()`, `vectorValue()`, `mapValue()`, etc.
- **Never construct `Value{ .string = ... }` directly** — the compiler will reject it
- **Never construct `GcStr` directly** — it is private to `value.zig`
- **For hash map lookup keys**: use `phm.sym(name)` which memoizes symbol values via `sym_cache`, avoiding repeated allocations
- **The GC scanner only tracks GC-allocated blocks** — non-GC pointers are silently skipped (memory leak, not crash)

### Violation symptoms

- Use-after-free, dangling pointers
- GC scanner crashes or sweeps live data
- Namespace aliases silently failing (key points to freed stack memory)
- Memory corruption in multithreaded code

### `shallowClone` is a no-op

Since all Value data is GC-managed and immutable, `shallowClone(val, allocator)` is a simple struct copy (`return val.*`). No duplication is needed — the GC keeps all shared data alive. The `allocator` parameter is unused.

### Guardrails

- **Lint check**: `tests/lint_gc_invariants.sh` — runs grep-based checks for violations
- **Unit tests**: `test "gc_invariant: ..."` tests in `test_value.zig` verify GC tracking
- Run these regularly to catch regressions early

---

## 1. Code Size Limits

**No Zig source file may exceed 2,000 lines. No single function may exceed 80 lines.**

These are hard limits. When a file or function approaches its limit, it must be split before more functionality is added.

### File Size Limit: 2,000 lines

- Count all lines including imports, comments, blank lines, and tests.
- When a file reaches **1,800 lines**, plan a split. At **2,000 lines**, a split is mandatory.
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

- **CLI tests**: Use the built-in `--timeout` flag.
  ```bash
  ./zig-out/bin/clojurez --timeout 10 -e '(+ 1 2)'
  ```
- **REPL tests**: Never pipe unbounded input into the REPL. Always provide finite input with an explicit exit command.
  ```bash
  ./zig-out/bin/clojurez --timeout 10 --repl < input.clj
  ```
- **Clojure shell tests**: Use the `:timeout` option in test helpers.
  ```clojure
  (test-cmd "my-test" ["-e" "..."] {:timeout 15})
  (test-repl "my-repl" "..." {:timeout 10})
  ```
- **Unit tests**: Use Zig's built-in test timeout or wrap long-running tests with explicit guards.
- **Multithreading tests**: Tests involving `future` or `promise` must include explicit timeouts. Never rely on `deref` without a fallback. Use patterns like:
  ```clojure
  (let [f (future (do (sleep 100000) 42))]
    ;; Use a timeout-aware check instead of bare deref
    ...)
  ```

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

### 4.1 Unit Tests (Zig)

Test individual functions in isolation. Place tests at the bottom of each source file using Zig's `test` blocks:

```zig
test "core::plus: returns integer for integer args" {
    const result = try core_plus(&dummy, args, &env);
    try expect(result.type == .integer);
    try expect(result.int_val == 5);
}
```

Run: `zig test src/zig/all_tests.zig`

**Requirements:**
- Each test must be self-contained (no shared mutable state between tests)
- Tests must not depend on execution order
- Use descriptive names: `test "<module>::<function>: <description>"`

### 4.2 Clojure In-VM Tests (`tests/clj/test_*.clj`, excluding `shell_*`)

Test the full pipeline (lexer → parser → evaluator → runtime) through the VM. Use the `check`/`check-true`/`check-false` helper from `tests/clj/clj_test_helper.clj`:

```clojure
(check "addition" (+ 1 2) 3)
(check-true "truthy" some-value)
(check-false "falsy" nil)
```

These run directly inside a single clojurez process. Create `tests/clj/test_my_feature.clj` and it will be picked up automatically.

### 4.3 Clojure Shell Tests (`tests/clj/test_shell_*.clj`)

Test features requiring process isolation (stdout capture, REPL interaction, file execution, `-cp`/`-m`). Use the test runner framework:

```clojure
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

(def-suite shell-my-tests)

(test "print hello" (fn []
  (test-cmd "print-hello" ["-e" "(print \"hello\")"] {:expected-out "hello"})))

(test "repl interaction" (fn []
  (test-repl "repl-test" "(+ 1 2)\n(exit)\n" {:expected-out-contains "3"})))

(run-all)
```

Register in `tests/run_all.clj` with `(load-file "tests/clj/test_shell_my_tests.clj")`.

### 4.4 Bash Debug Tests (`tests/test_debug.sh`)

Tests requiring environment variable manipulation (CLJVM_DEBUG). These cannot be migrated to Clojure because `io/sh` does not yet support the `:env` option. Minimal bash script sourced by `run_tests.sh`.

### 4.5 Complex Samples (`tests/complex-samples/`)

End-to-end programs with `expected_output.txt` verification. Each sample serves as a regression test for a specific feature area. Tested via `test_shell_samples.clj`.

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

### Clojure Tests

- **In-VM suites**: `tests/clj/test_<feature>.clj` (e.g., `test_arithmetics.clj`)
- **Shell suites**: `tests/clj/test_shell_<category>.clj` (e.g., `test_shell_repl.clj`)
- **Test names inside suites**: descriptive strings passed to `(test "name" ...)`

### Bash Debug Tests

- `tests/test_debug.sh` — single file for CLJVM_DEBUG env var tests

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
zig test src/zig/all_tests.zig

# All tests (builds VM, runs Clojure suites + shell tests + debug tests)
./run_tests.sh

# Run without rebuilding
NOBUILD=1 ./run_tests.sh

# Specific Clojure in-VM test suite
./run_tests.sh test_arithmetics
./run_tests.sh test_bytecode
```

### Running Both

```bash
zig test src/zig/all_tests.zig && ./run_tests.sh
```

### Running Clojure Shell Tests Directly

```bash
# All shell test suites in one process
./zig-out/bin/clojurez --timeout 120 tests/run_all.clj
```

### Test Output Format

```
=== Clojure Test Suites ===
PASS: test_smoke [0s]
PASS: test_arithmetics [0s]
...FAIL: test_xyz (2 failure(s)) [1s]    ; suite had check failures
TIMEOUT: test_abc (15s) [15s]             ; suite exceeded timeout
CRASH: test_def (exit 11) [0s]            ; suite crashed (segfault, assertion)

=== Clojure Shell Test Suites ===
=== Suite: shell-print-io ===
SUMMARY: 5 passed, 0 failed
...

=== Bash Debug Tests ===
PASS: debug CLJVM_DEBUG=1 shows startup/shutdown [0s]
...

ALL TESTS PASSED: 54/54
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
- **Unsafe global state in built-in functions**: Any global variable read/written by a built-in function must be atomic or protected by a lock
- **Sharing `Env` across threads**: Always clone the environment before passing to a child thread
- **Forgetting `threadDone()`**: Child threads must always release the `gc_lock` and decrement `active_thread_count`

### Do This Instead

- Use `tests/timeout.sh` for all external process tests
- Set up and tear down test fixtures explicitly
- Use deterministic test data
- Keep tests fast (<1s for unit tests, <10s for integration tests)
- Document flaky tests and fix them promptly
- Return errors and let callers decide how to handle them
- Use `std.atomic.Value` for shared counters and flags
- Clone `Env` with `env.clone(allocator)` for child threads
- Follow the `FutureData`/`PromiseData` pattern for thread-safe state machines

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

### Multithreading Debugging

- **Non-deterministic crashes**: Likely a race condition. Add thread ID to debug prints: `std.log.info("thread {d}: ...", .{std.Thread.getCurrentId()})`
- **Future never completes**: Check that the child thread doesn't crash silently. Wrap the eval call in a `defer` block that sets an error state.
- **Deadlock on `gc_lock`**: Verify all child threads call `threadDone()`. Use `CLJVM_GC_VERBOSE=1` to see lock state.
- **Memory corruption with threads**: Run with `CLJVM_GC_SWEEP=0` first. If the issue persists, it's a data race, not a GC issue.

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
| Thread safety | All code reachable during evaluation must be thread-safe |
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
