#!/bin/bash
# Shared test helpers for Clojure VM test suite
# Source this file from test scripts: source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10
TOOL_TIMEOUT="tests/timeout.sh"

# Counters (accumulated across all test files)
if [ -z "$TEST_PASS" ]; then
    TEST_PASS=0
    TEST_FAIL=0
    TEST_TOTAL=0
fi

# Timing helpers for shell tests (unified format with Clojure tests)
_test_start_time=0

_start_timer() {
    _test_start_time=$(date +%s)
}

_elapsed() {
    local end elapsed
    end=$(date +%s)
    elapsed=$((end - _test_start_time))
    if [ "$elapsed" -ge 60 ]; then
        echo "$((elapsed / 60))m$((elapsed % 60))s"
    else
        echo "${elapsed}s"
    fi
}

# Build the VM (core.clj copy is handled by build.zig)
build_vm() {
    echo "Building VM..."
    zig build 2>&1
    echo ""
}

# Run a test with an expression, comparing trimmed output
# Uses tests/timeout.sh for cross-platform compatibility
# Includes timing in output: PASS: name [0s]
run_test() {
    local name="$1"
    local input="$2"
    local expected="$3"
    TEST_TOTAL=$((TEST_TOTAL + 1))

    _start_timer
    local result
    result=$($TOOL_TIMEOUT $TIMEOUT $VM -e "$input" 2>&1) || {
        echo "FAIL: $name [$( _elapsed)] (timeout or error)"
        echo "  Input:    $input"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        TEST_FAIL=$((TEST_FAIL + 1))
        return
    }

    # Trim whitespace
    result=$(echo "$result" | tr -d '[:space:]')
    expected=$(echo "$expected" | tr -d '[:space:]')

    if [ "$result" = "$expected" ]; then
        echo "PASS: $name [$( _elapsed)]"
        TEST_PASS=$((TEST_PASS + 1))
    else
        echo "FAIL: $name [$( _elapsed)]"
        echo "  Input:    $input"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
}
