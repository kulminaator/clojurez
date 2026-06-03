#!/bin/bash
# Special Forms: def, if, quote, do, when, cond, let, etc.
source tests/helpers.sh

echo "=== Special Forms ==="
run_test "def" "(def x 42)" "x"
run_test "if true" "(if true 1 2)" "1"
run_test "if false" "(if false 1 2)" "2"
run_test "quote" "'(1 2 3)" "(1 2 3)"
run_test "do" "(do 1 2 3)" "3"
run_test "when" '(when true (+ 1 2))' "3"
