#!/bin/bash
# Print/println stdout capture tests (cannot be tested from within Clojure)
source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10
TOOL_TIMEOUT="tests/timeout.sh"

echo "=== Print/Println Stdout Capture ==="
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(print "hello")' 2>&1) || {
    echo "FAIL: print basic (timeout or error) [$( _elapsed)]"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "hello" ]; then
    echo "PASS: print basic [$( _elapsed)]"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: print basic [$( _elapsed)]"; echo "  Expected: hello"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi

TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(println "hello")' 2>&1) || {
    echo "FAIL: println basic (timeout or error) [$( _elapsed)]"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "hello" ]; then
    echo "PASS: println basic [$( _elapsed)]"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: println basic [$( _elapsed)]"; echo "  Expected: hello"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi

TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(zig.core/print 1 2 3)' 2>&1) || {
    echo "FAIL: zig.core/print (timeout or error) [$( _elapsed)]"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "123" ]; then
    echo "PASS: zig.core/print [$( _elapsed)]"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: zig.core/print [$( _elapsed)]"; echo "  Expected: 123"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi

TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(zig.core/println 1 2 3)' 2>&1) || {
    echo "FAIL: zig.core/println (timeout or error) [$( _elapsed)]"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "123" ]; then
    echo "PASS: zig.core/println [$( _elapsed)]"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: zig.core/println [$( _elapsed)]"; echo "  Expected: 123"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi
