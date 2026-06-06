#!/bin/bash
# Sample Programs: Fibonacci, Hanoi
source tests/helpers.sh

echo "=== Hanoi Sample ==="
# Run the hanoi sample and check output (core is auto-loaded now)
hanoi_result=$(timeout 10 ./zig-out/bin/clojurez tests/complex-samples/sample_2_hanoi/hanoi/core.clj 2>&1 | tail -n +5)
expected_hanoi=$(cat tests/complex-samples/sample_2_hanoi/expected_output.txt)
TEST_TOTAL=$((TEST_TOTAL + 1))
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
# Run the fibonacci sample and check output
fib_result=$(timeout 10 ./zig-out/bin/clojurez tests/complex-samples/sample_1_fibonacci/core.clj 2>&1 | tail -1)
expected="(0 1 1 2 3 5 8 13 21 34)"
TEST_TOTAL=$((TEST_TOTAL + 1))
if [ "$fib_result" = "$expected" ]; then
    echo "PASS: fibonacci sample"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: fibonacci sample"
    echo "  Expected: $expected"
    echo "  Got:      $fib_result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
