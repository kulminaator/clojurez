#!/bin/bash
# I/O error tests (stderr capture — cannot be tested from within Clojure)
source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10
TOOL_TIMEOUT="tests/timeout.sh"

echo "=== I/O Error Tests ==="
# slurp nonexistent file should error
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(slurp "/tmp/clojure_vm_nonexistent_xyz.txt")' 2>&1 | head -1) || true
if [ "$result" = "error: FileError" ]; then
    echo "PASS: slurp nonexistent"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: slurp nonexistent"
    echo "  Expected: error: FileError"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
