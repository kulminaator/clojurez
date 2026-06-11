#!/bin/bash
# Print/println stdout capture tests (cannot be tested from within Clojure)
source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10
TOOL_TIMEOUT="tests/timeout.sh"

echo "=== Print/Println Stdout Capture ==="
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(print "hello")' 2>&1) || {
    echo "FAIL: print basic (timeout or error)"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "hello" ]; then
    echo "PASS: print basic"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: print basic"; echo "  Expected: hello"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(println "hello")' 2>&1) || {
    echo "FAIL: println basic (timeout or error)"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "hello" ]; then
    echo "PASS: println basic"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: println basic"; echo "  Expected: hello"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(zig.core/print 1 2 3)' 2>&1) || {
    echo "FAIL: zig.core/print (timeout or error)"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "123" ]; then
    echo "PASS: zig.core/print"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: zig.core/print"; echo "  Expected: 123"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(zig.core/println 1 2 3)' 2>&1) || {
    echo "FAIL: zig.core/println (timeout or error)"; TEST_FAIL=$((TEST_FAIL + 1))
}
result=$(echo "$result" | tr -d '[:space:]')
if [ "$result" = "123" ]; then
    echo "PASS: zig.core/println"; TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: zig.core/println"; echo "  Expected: 123"; echo "  Got: $result"; TEST_FAIL=$((TEST_FAIL + 1))
fi
