#!/bin/bash
# Lists and Sequences: list, vec, count, first, rest, nth
source tests/helpers.sh

echo "=== List/Sequence Tests ==="
run_test "list" "(list 1 2 3)" "(1 2 3)"
run_test "vec" "(vec 1 2 3)" "[1 2 3]"
run_test "count list" "(count (list 1 2 3))" "3"
run_test "first" "(first (list 1 2 3))" "1"
run_test "rest" "(rest (list 1 2 3))" "(2 3)"
run_test "nth" "(nth (list 1 2 3) 1)" "2"
