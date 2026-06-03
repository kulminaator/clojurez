#!/bin/bash
# Functions: fn, defn, variadic, multi-arity
source tests/helpers.sh

echo "=== Function Tests ==="
run_test "fn call" "((fn [x] (* x x)) 5)" "25"
run_test "defn" "(defn square [n] (* n n))" "square"

# Variadic function tests
run_test "variadic fn all rest" '(do (defn var-fn [& args] args) (var-fn 1 2 3))' '(1 2 3)'
run_test "variadic fn empty rest" '(do (defn var-fn [& args] args) (var-fn))' '()'
run_test "variadic fn mixed" '(do (defn var-mix [a b & rest] (list a b rest)) (var-mix 1 2 3 4 5))' '(1 2 (3 4 5))'
run_test "variadic fn no extra" '(do (defn var-mix [a b & rest] (list a b rest)) (var-mix 1 2))' '(1 2 ())'
run_test "variadic fn inline" '((fn [& args] args) 10 20 30)' '(10 20 30)'
run_test "variadic fn with defn" '(do (defn my-sum [init & nums] (reduce + init nums)) (my-sum 0 1 2 3 4))' '10'
run_test_cmd "variadic fn arity error" 'timeout 10 ./main -e "(do (defn var-mix [a b & rest] (list a b rest)) (var-mix 1))" 2>&1 | head -1' 'error: ArityError'

echo ""
echo "=== Multi-arity Functions ==="
run_test "multi-arity defn single arg" '(do (defn foo [a] a [a b] (+ a b)) (foo 1))' '1'
run_test "multi-arity defn two args" '(do (defn foo [a] a [a b] (+ a b)) (foo 1 2))' '3'
run_test "multi-arity fn single arg" '((fn [a] a [a b] (+ a b)) 1)' '1'
run_test "multi-arity fn two args" '((fn [a] a [a b] (+ a b)) 1 2)' '3'
run_test "multi-arity defn three arities" '(do (defn bar [] 0 [a] a [a b] (+ a b)) (bar))' '0'
run_test "multi-arity defn three arities 1" '(do (defn bar [] 0 [a] a [a b] (+ a b)) (bar 5))' '5'
run_test "multi-arity defn three arities 2" '(do (defn bar [] 0 [a] a [a b] (+ a b)) (bar 3 4))' '7'
