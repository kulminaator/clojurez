#!/bin/bash
# Thread Macros: ->, ->>
source tests/helpers.sh

echo "=== Thread Macros ==="
run_test "thread-last basic" '(->> 1 (+ 2) (* 3))' "9"
run_test "thread-first basic" '(-> 1 (+ 2) (* 3))' "9"
