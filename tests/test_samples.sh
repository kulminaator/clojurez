#!/bin/bash
# Sample Programs: Fibonacci, Hanoi
source tests/helpers.sh

echo "=== Hanoi Sample ==="
# Run the hanoi sample and check output (core is auto-loaded now)
# File execution is silent — only println output appears
hanoi_result=$(timeout 10 ./zig-out/bin/clojurez tests/complex-samples/sample_2_hanoi/hanoi/core.clj 2>&1)
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

echo ""
echo "=== Namespace Sample ==="
# Run the namespace sample with -cp and -m
ns_result=$(timeout 10 ./zig-out/bin/clojurez -cp tests/complex-samples/sample_3_namespaces/src -m main 2>&1)
expected_ns=$(cat tests/complex-samples/sample_3_namespaces/expected_output.txt)
TEST_TOTAL=$((TEST_TOTAL + 1))
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
# Run the GC stress test — checks that auto-GC triggers, manual sweep
# frees memory, and sweep count increases. Only the final RESULT line
# is checked (memory values vary by build/platform).
gc_result=$(timeout 30 ./zig-out/bin/clojurez tests/complex-samples/sample_4_gc_stress/core.clj 2>&1 | tail -1)
expected_gc=$(cat tests/complex-samples/sample_4_gc_stress/expected_output.txt | tr -d '\n')
TEST_TOTAL=$((TEST_TOTAL + 1))
if [ "$gc_result" = "$expected_gc" ]; then
    echo "PASS: gc stress sample"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: gc stress sample"
    echo "  Expected: $expected_gc"
    echo "  Got:      $gc_result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
