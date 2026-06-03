#!/bin/bash
# Destructuring: vector, nested vector, & rest in let
source tests/helpers.sh

echo "=== Destructuring ==="
run_test "vector destructure" '((fn [[a b]] (+ a b)) [1 2])' "3"
run_test "nested destructure" '((fn [[[a b] c]] (+ a b c)) [[1 2] 3])' "6"

echo ""
echo "=== Destructuring with & rest ==="
run_test "let destructuring & rest" '(let [[a b & rest] (list 1 2 3 4 5)] (list a b rest))' '(1 2 (3 4 5))'
run_test "let destructuring & rest empty" '(let [[a & rest] (list 1)] (list a rest))' '(1 ())'
run_test "let destructuring & rest all" '(let [[& rest] (list 1 2 3)] rest)' '(1 2 3)'
