#!/bin/bash
# Shared test helpers for Clojure VM test suite
# Source this file from test scripts: source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10

# Counters (accumulated across all test files)
if [ -z "$TEST_PASS" ]; then
    TEST_PASS=0
    TEST_FAIL=0
    TEST_TOTAL=0
fi

#special help program for computers designed by apple
if [[ "$(uname)" == "Darwin" ]]; then
    if ! command -v timeout >/dev/null 2>&1; then
        timeout() {
            perl -e 'alarm shift; exec @ARGV' "$@"
        }
    fi
fi

# Build the VM (core.clj copy is handled by build.zig)
build_vm() {
    echo "Building VM..."
    zig build 2>&1
    echo ""
}

# Run a test with an expression, comparing trimmed output
run_test() {
    local name="$1"
    local input="$2"
    local expected="$3"
    TEST_TOTAL=$((TEST_TOTAL + 1))

    local result
    result=$(timeout $TIMEOUT $VM -e "$input" 2>&1) || {
        echo "FAIL: $name (timeout or error)"
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
        echo "PASS: $name"
        TEST_PASS=$((TEST_PASS + 1))
    else
        echo "FAIL: $name"
        echo "  Input:    $input"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
}

# Run a test with an arbitrary shell command, comparing trimmed output
run_test_cmd() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    TEST_TOTAL=$((TEST_TOTAL + 1))

    local result
    result=$(timeout $TIMEOUT bash -c "$cmd" 2>&1 | tail -1) || {
        echo "FAIL: $name (timeout or error)"
        echo "  Cmd:      $cmd"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        TEST_FAIL=$((TEST_FAIL + 1))
        return
    }

    # Trim whitespace
    result=$(echo "$result" | tr -d '[:space:]')
    expected=$(echo "$expected" | tr -d '[:space:]')

    if [ "$result" = "$expected" ]; then
        echo "PASS: $name"
        TEST_PASS=$((TEST_PASS + 1))
    else
        echo "FAIL: $name"
        echo "  Cmd:      $cmd"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
}

# Run a test with an arbitrary shell command, comparing FULL output (all lines)
# Useful for file-execution tests where only println output should appear.
run_test_cmd_full() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    TEST_TOTAL=$((TEST_TOTAL + 1))

    local result
    result=$(timeout $TIMEOUT bash -c "$cmd" 2>&1) || {
        echo "FAIL: $name (timeout or error)"
        echo "  Cmd:      $cmd"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        TEST_FAIL=$((TEST_FAIL + 1))
        return
    }

    # Trim whitespace
    result=$(echo "$result" | tr -d '[:space:]')
    expected=$(echo "$expected" | tr -d '[:space:]')

    if [ "$result" = "$expected" ]; then
        echo "PASS: $name"
        TEST_PASS=$((TEST_PASS + 1))
    else
        echo "FAIL: $name"
        echo "  Cmd:      $cmd"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
}
