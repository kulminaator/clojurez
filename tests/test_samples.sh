#!/bin/bash
# Sample Programs: Fibonacci, Hanoi, Namespaces, GC Stress
source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=30
TOOL_TIMEOUT="tests/timeout.sh"

echo "=== Hanoi Sample ==="
TEST_TOTAL=$((TEST_TOTAL + 1))
hanoi_result=$($TOOL_TIMEOUT $TIMEOUT $VM tests/complex-samples/sample_2_hanoi/hanoi/core.clj 2>&1 | tr -d '\r') || {
    echo "FAIL: hanoi sample (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
expected_hanoi=$(cat tests/complex-samples/sample_2_hanoi/expected_output.txt | tr -d '\r')
if [ "$hanoi_result" = "$expected_hanoi" ]; then
    echo "PASS: hanoi sample"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: hanoi sample"
    echo "  Expected: $expected_hanoi"
    echo "  Got:      $hanoi_result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

echo ""
echo "=== Fibonacci Sample ==="
TEST_TOTAL=$((TEST_TOTAL + 1))
fib_result=$($TOOL_TIMEOUT $TIMEOUT bash -c "$VM tests/complex-samples/sample_1_fibonacci/core.clj 2>&1 | tail -1 | tr -d '\r'") || {
    echo "FAIL: fibonacci sample (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
expected="(0 1 1 2 3 5 8 13 21 34)"
if [ "$fib_result" = "$expected" ]; then
    echo "PASS: fibonacci sample"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: fibonacci sample"
    echo "  Expected: $expected"
    echo "  Got:      $fib_result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

echo ""
echo "=== Namespace Sample ==="
TEST_TOTAL=$((TEST_TOTAL + 1))
ns_result=$($TOOL_TIMEOUT $TIMEOUT $VM -cp tests/complex-samples/sample_3_namespaces/src -m main 2>&1 | tr -d '\r') || {
    echo "FAIL: namespace sample (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
expected_ns=$(cat tests/complex-samples/sample_3_namespaces/expected_output.txt | tr -d '\r')
if [ "$ns_result" = "$expected_ns" ]; then
    echo "PASS: namespace sample"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: namespace sample"
    echo "  Expected: $expected_ns"
    echo "  Got:      $ns_result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

echo ""
echo "=== GC Stress Sample ==="
TEST_TOTAL=$((TEST_TOTAL + 1))
gc_result=$($TOOL_TIMEOUT $TIMEOUT bash -c "$VM tests/complex-samples/sample_4_gc_stress/core.clj 2>&1 | tail -1 | tr -d '\r'") || {
    echo "FAIL: gc stress sample (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
expected_gc=$(cat tests/complex-samples/sample_4_gc_stress/expected_output.txt | tr -d '\r\n')
if [ "$gc_result" = "$expected_gc" ]; then
    echo "PASS: gc stress sample"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: gc stress sample"
    echo "  Expected: $expected_gc"
    echo "  Got:      $gc_result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
