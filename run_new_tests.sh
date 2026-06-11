#!/bin/bash
# New test runner for Clojure VM
# Runs focused Clojure test files instead of launching a separate process per test.
# Each test file contains multiple checks and runs as a single execution.
#
# Usage:
#   ./run_new_tests.sh          # Build + run all test suites
#   NOBUILD=1 ./run_new_tests.sh  # Run without rebuilding
#   ./run_new_tests.sh test_arithmetics  # Run a specific test suite

set -e

VM="./zig-out/bin/clojurez"
TIMEOUT_SECONDS=15
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Counters
TOTAL=0
PASSED=0
FAILED=0

# Build the VM once (skip with NOBUILD=1)
if [ "$NOBUILD" != "1" ]; then
    echo "Building VM..."
    zig build 2>&1
    echo ""
fi

# Run a single test suite file
run_suite() {
    local test_file="$1"
    local suite_name
    suite_name=$(basename "$test_file" .clj)

    TOTAL=$((TOTAL + 1))

    local output
    local exit_code=0
    output=$(tests/timeout.sh "$TIMEOUT_SECONDS" "$VM" "$test_file" 2>&1) || exit_code=$?

    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ] || [ "$exit_code" -eq 134 ] || [ "$exit_code" -eq 143 ]; then
        # Timeout or killed (124=timeout, 137=SIGKILL, 134=SIGABRT, 143=SIGTERM)
        echo "TIMEOUT: $suite_name (${TIMEOUT_SECONDS}s)"
        FAILED=$((FAILED + 1))
        return
    elif [ "$exit_code" -ne 0 ]; then
        # VM crashed or error
        echo "CRASH: $suite_name (exit code $exit_code)"
        echo "$output" | head -20
        FAILED=$((FAILED + 1))
        return
    fi

    # Parse output for FAIL: lines
    local fail_count
    fail_count=$(echo "$output" | grep -c "^FAIL:" || true)

    # Print all output
    echo "$output"

    if [ "$fail_count" -gt 0 ]; then
        FAILED=$((FAILED + 1))
    else
        PASSED=$((PASSED + 1))
    fi
}

# Determine which tests to run
if [ $# -gt 0 ]; then
    # Run specific test(s)
    for name in "$@"; do
        test_file="$SCRIPT_DIR/tests/clj/test_${name}.clj"
        if [ ! -f "$test_file" ]; then
            echo "Error: test file not found: $test_file"
            exit 1
        fi
        run_suite "$test_file"
    done
else
    # Run all test suites in tests/clj/
    echo "Running test suites..."
    echo ""

    for test_file in "$SCRIPT_DIR/tests/clj/test_"*.clj; do
        if [ -f "$test_file" ]; then
            run_suite "$test_file"
            echo ""
        fi
    done
fi

# Print summary
echo "========================================"
echo "Suites: $PASSED passed, $FAILED failed (out of $TOTAL)"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
