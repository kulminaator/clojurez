#!/bin/bash
# Test runner for Clojure VM
# All tests must complete within 10 seconds each.
#
# Runs Clojure-based test suites first (fast, single-process),
# then shell-based I/O tests (stdin, file execution, -cp -m, REPL).
#
# Usage:
#   ./run_tests.sh              # Build + run all tests
#   NOBUILD=1 ./run_tests.sh    # Run without rebuilding
#   ./run_tests.sh test_arithmetics  # Run a specific Clojure test suite
#
# Clojure test files: tests/clj/test_*.clj
# Shell test files:   tests/test_*.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM="./zig-out/bin/clojurez"
TIMEOUT_SECONDS=15

# Build the VM once (skip with NOBUILD=1)
if [ "$NOBUILD" != "1" ]; then
    echo "Building VM..."
    zig build 2>&1
    echo ""
fi

# ============================================================
# Clojure-based test suites (fast, single-process per suite)
# ============================================================

CLJ_TOTAL=0
CLJ_PASSED=0
CLJ_FAILED=0

# Run a single Clojure test suite file
run_clj_suite() {
    local test_file="$1"
    local suite_name
    suite_name=$(basename "$test_file" .clj)

    CLJ_TOTAL=$((CLJ_TOTAL + 1))

    local output
    local exit_code=0
    output=$(tests/timeout.sh "$TIMEOUT_SECONDS" "$VM" "$test_file" 2>&1) || exit_code=$?

    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ] || [ "$exit_code" -eq 134 ] || [ "$exit_code" -eq 143 ]; then
        echo "TIMEOUT: $suite_name (${TIMEOUT_SECONDS}s)"
        CLJ_FAILED=$((CLJ_FAILED + 1))
        return
    elif [ "$exit_code" -ne 0 ]; then
        echo "CRASH: $suite_name (exit code $exit_code)"
        echo "$output" | head -20
        CLJ_FAILED=$((CLJ_FAILED + 1))
        return
    fi

    local fail_count
    fail_count=$(echo "$output" | grep -c "^FAIL:" || true)

    echo "$output"

    if [ "$fail_count" -gt 0 ]; then
        CLJ_FAILED=$((CLJ_FAILED + 1))
    else
        CLJ_PASSED=$((CLJ_PASSED + 1))
    fi
}

echo "=== Clojure Test Suites ==="
echo ""

if [ $# -gt 0 ]; then
    # Run specific Clojure test(s)
    for name in "$@"; do
        test_file="$SCRIPT_DIR/tests/clj/test_${name}.clj"
        if [ ! -f "$test_file" ]; then
            echo "Error: test file not found: $test_file"
            exit 1
        fi
        run_clj_suite "$test_file"
        echo ""
    done
else
    # Run all Clojure test suites
    for test_file in "$SCRIPT_DIR/tests/clj/test_"*.clj; do
        if [ -f "$test_file" ]; then
            run_clj_suite "$test_file"
            echo ""
        fi
    done
fi

echo "========================================"
echo "Clojure suites: $CLJ_PASSED passed, $CLJ_FAILED failed (out of $CLJ_TOTAL)"
echo "========================================"
echo ""

# If specific tests were requested, skip shell tests and exit
if [ $# -gt 0 ]; then
    if [ $CLJ_FAILED -gt 0 ]; then
        exit 1
    fi
    exit 0
fi

# ============================================================
# Shell-based I/O tests (stdin, file execution, -cp -m, REPL)
# ============================================================

source tests/helpers.sh

echo "=== Shell Test Suites ==="
echo ""

source tests/test_io.sh
echo ""

source tests/test_misc.sh
echo ""

source tests/test_namespaces.sh
echo ""

source tests/test_samples.sh
echo ""

source tests/test_core_library.sh

echo ""
echo "========================================"
echo "Shell tests: $TEST_PASS passed, $TEST_FAIL failed (out of $TEST_TOTAL)"
echo "========================================"

# Combined exit
if [ $CLJ_FAILED -gt 0 ] || [ $TEST_FAIL -gt 0 ]; then
    exit 1
fi
