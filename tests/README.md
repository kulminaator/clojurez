# ClojureZ Test Suite

## Quick Start

```bash
# Run all tests (builds VM first)
./run_tests.sh

# Run without rebuilding
NOBUILD=1 ./run_tests.sh

# Run a specific Clojure test suite
./run_tests.sh test_arithmetics
./run_tests.sh test_bytecode
```

## Test Structure

```
tests/
├── run_all.clj              # Entry point for Clojure shell test suites
├── test_debug.sh            # Bash tests for CLJVM_DEBUG env var (cannot be in Clojure yet)
└── clj/
    ├── test_runner.clj      # Test framework: def-suite, test, check, run-all
    ├── shell_test_runner.clj # Subprocess helpers: run-cmd, test-cmd, test-repl, test-file, test-main
    ├── test_smoke.clj       # Fast smoke test (runs first, aborts on failure)
    ├── test_arithmetics.clj # In-VM test suites (run directly in clojurez)
    ├── test_bytecode.clj
    ├── test_collections.clj
    ├── ... (other in-VM suites)
    ├── test_shell_print_io.clj   # Shell test suites (spawn subprocesses via io/sh)
    ├── test_shell_file_exec.clj
    ├── test_shell_repl.clj
    ├── test_shell_namespaces.clj
    ├── test_shell_samples.clj
    ├── test_shell_zig_io.clj
    └── test_shell_debug.clj
```

## Test Categories

### 1. Clojure In-VM Suites (`tests/clj/test_*.clj`, excluding `shell_*`)

Run directly inside a single clojurez process. Use the `check`/`check-true`/`check-false` helpers from `clj_test_helper.clj`:

```clojure
(load-file "tests/clj/clj_test_helper.clj")
(check "1+2=3" (+ 1 2) 3)
(check-true "truthy" some-value)
(check-false "falsy" nil)
```

These test pure Clojure semantics: arithmetic, collections, sequences, macros, etc.

### 2. Clojure Shell Suites (`tests/clj/test_shell_*.clj`)

Spawn child clojurez processes to test features requiring process isolation:
- Print/println stdout capture
- File execution
- REPL interaction (via `sh-stream`)
- `-cp`/`-m` flags
- Complex sample programs

Use the test runner framework:

```clojure
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

(def-suite my-shell-tests)

(test "print hello" (fn []
  (test-cmd "print-hello"
    ["-e" "(print \"hello\")"]
    {:expected-out "hello"})))

(test "repl interaction" (fn []
  (test-repl "repl-test"
    "(+ 1 2)\n(exit)\n"
    {:expected-out-contains "3"})))

(run-all)
```

Run all shell suites: `clojurez --timeout 120 tests/run_all.clj`

### 3. Bash Debug Tests (`tests/test_debug.sh`)

Tests that require environment variable manipulation (CLJVM_DEBUG). These cannot be migrated to Clojure because `io/sh` does not yet support the `:env` option.

## Test Runner (`run_tests.sh`)

The main test runner is a ~50-line bash script that:

1. **Builds the VM** (skip with `NOBUILD=1`)
2. **Runs smoke test** (aborts immediately on failure)
3. **Runs all Clojure in-VM suites** (individually, with per-suite timeout)
4. **Runs Clojure shell suites** (via `tests/run_all.clj`)
5. **Runs bash debug tests** (CLJVM_DEBUG env var tests)
6. **Prints combined summary**

### Output Format

```
=== Clojure Test Suites ===
PASS: test_smoke [0s]
PASS: test_arithmetics [0s]
...
Clojure suites: 49 passed, 0 failed (out of 49)

=== Clojure Shell Test Suites ===
=== Suite: shell-print-io ===
SUMMARY: 5 passed, 0 failed
...

=== Bash Debug Tests ===
PASS: debug CLJVM_DEBUG=1 shows startup/shutdown [0s]
...
Bash debug tests: 4 passed, 0 failed (out of 4)

ALL TESTS PASSED: 54/54
```

### Timeout Policy

- Each Clojure in-VM suite: 15s (30s for test_clojure_string)
- Clojure shell suites batch: 120s total
- Individual shell tests: configurable via `:timeout` option
- Uses built-in `--timeout` flag (not external `timeout` command)

## Writing New Tests

### Adding an in-VM test

Create `tests/clj/test_my_feature.clj`:

```clojure
(load-file "tests/clj/clj_test_helper.clj")

(check "feature works" (my-function 1 2) 3)
(check-true "feature returns truthy" (my-function 1 2))
```

It will be picked up automatically by `run_tests.sh`.

### Adding a shell test

Create `tests/clj/test_shell_my_feature.clj`:

```clojure
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

(def-suite shell-my-feature)

(test "command output" (fn []
  (test-cmd "my-cmd"
    ["-e" "(my-feature)"]
    {:expected-out "expected output"})))

(run-all)
```

Then add `(load-file "tests/clj/test_shell_my_feature.clj")` to `tests/run_all.clj`.

## Zig Unit Tests

Zig unit tests are in `src/zig/all_tests.zig`. Run with:

```bash
zig test src/zig/all_tests.zig
```

## Full Test Run

```bash
zig test src/zig/all_tests.zig && ./run_tests.sh
```
