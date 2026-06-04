#!/bin/bash
# Miscellaneous: Namespace, and/or, quasiquote, set!, binding, var, deref
source tests/helpers.sh

echo "=== Namespace Tests ==="
run_test "ns declaration" '(ns my.core)' "nil"

echo ""
echo "=== Binding Tests ==="
run_test "binding single var" '(do (def x 10) (binding [x 20] x))' "20"
run_test "binding multiple vars" '(do (def a 1) (def b 2) (binding [a 10 b 20] (+ a b)))' "30"
run_test "binding value restored after scope" '(do (def x 10) (binding [x 20] x) x)' "10"
run_test "binding with expression" '(do (def x 0) (binding [x (+ 3 4)] x))' "7"
run_test "binding nested" '(do (def x 10) (binding [x 20] (binding [x 30] x)))' "30"
