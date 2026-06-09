#!/bin/bash
# Sequence Functions: iterate, map, take, partition, reduce, flatten, filter, remove, every?, some, distinct?, nthnext, into, drop
source tests/helpers.sh

echo "=== Sequence Functions ==="
run_test "iterate" "(take 5 (iterate (fn [x] (+ x 1)) 0))" "(0 1 2 3 4)"
run_test "map" "(doall (map (fn [x] (* x 2)) (list 1 2 3)))" "(2 4 6)"
run_test "take" "(take 3 (list 1 2 3 4 5))" "(1 2 3)"

echo ""
echo "=== Sequence Operation Tests ==="
run_test "reduce" "(reduce + 0 (list 1 2 3 4))" "10"
run_test "reduce no init" "(reduce + (list 1 2 3 4))" "10"
run_test_cmd "into" "$VM -e '(into [] (list 1 2 3))'" "[1 2 3]"
run_test "flatten" "(flatten (list 1 (list 2 3) 4))" "(1 2 3 4)"
run_test "filter" "(filter (fn [x] (> x 2)) (list 1 2 3 4))" "(3 4)"
run_test "remove" "(remove (fn [x] (> x 2)) (list 1 2 3 4))" "(1 2)"
run_test "every?" "(every? (fn [x] (> x 0)) (list 1 2 3))" "true"
run_test "some" "(some (fn [x] (= x 3)) (list 1 2 3))" "true"
run_test "distinct?" "(distinct? (list 1 2 3))" "true"
run_test "distinct? not" "(distinct? (list 1 2 1))" "false"
run_test "nthnext" "(nthnext 2 (list 1 2 3 4))" "(3 4)"

echo ""
echo "=== Partition ==="
run_test "partition exact" '(doall (partition 2 (list 1 2 3 4)))' '((1 2) (3 4))'
run_test "partition with remainder" '(doall (partition 2 (list 1 2 3 4 5)))' '((1 2) (3 4))'
run_test "partition single" '(doall (partition 1 (list 1 2 3)))' '((1) (2) (3))'
run_test "partition larger than coll" '(doall (partition 5 (list 1 2 3)))' '()'
run_test "partition empty" '(doall (partition 2 (list)))' '()'

echo ""
echo "=== take-nth ==="
run_test "take-nth basic" "(doall (take-nth 2 (list 1 2 3 4 5 6 7)))" "(1 3 5 7)"
run_test "take-nth step 3" "(doall (take-nth 3 (list 1 2 3 4 5 6 7 8 9)))" "(1 4 7)"
run_test "take-nth step 1" "(doall (take-nth 1 (list 1 2 3)))" "(1 2 3)"
run_test "take-nth step > len" "(doall (take-nth 5 (list 1 2 3)))" "(1)"
run_test "take-nth empty" "(doall (take-nth 2 (list)))" "()"

echo ""
echo "=== interleave ==="
run_test "interleave equal" "(doall (interleave (list 1 3 5) (list 2 4 6)))" "(1 2 3 4 5 6)"
run_test "interleave first shorter" "(doall (interleave (list 1 3) (list 2 4 6)))" "(1 2 3 4)"
run_test "interleave second shorter" "(doall (interleave (list 1 3 5) (list 2 4)))" "(1 2 3 4)"
run_test "interleave empty" "(doall (interleave))" "()"
run_test "interleave one empty" "(doall (interleave (list 1) (list)))" "()"

echo ""
echo "=== partition-all ==="
run_test "partition-all exact" "(doall (partition-all 2 (list 1 2 3 4 5 6)))" "((1 2) (3 4) (5 6))"
run_test "partition-all partial" "(doall (partition-all 2 (list 1 2 3 4 5)))" "((1 2) (3 4) (5))"
run_test "partition-all single" "(doall (partition-all 3 (list 1 2 3 4 5)))" "((1 2 3) (4 5))"
run_test "partition-all empty" "(doall (partition-all 2 (list)))" "()"

echo ""
echo "=== partition-by ==="
run_test "partition-by even?" "(doall (partition-by even? (list 1 1 1 2 2 2 3 3)))" "([1 1 1] [2 2 2] [3 3])"
run_test "partition-by identity" "(doall (partition-by identity (list :a :a :b :b :b :c)))" "([:a :a] [:b :b :b] [:c])"
run_test "partition-by empty" "(doall (partition-by even? (list)))" "()"

echo ""
echo "=== frequencies ==="
run_test "frequencies basic" "(frequencies (list 1 1 2 3 3 3))" "{1 2 2 1 3 3}"
run_test "frequencies strings" '(frequencies (list "a" "b" "a" "c" "b" "a"))' '{"a" 3 "b" 2 "c" 1}'
run_test "frequencies empty" "(frequencies (list))" "{}"

# Regression: large range must not cause stack overflow (lazy-seq recursion bug)
run_test "reduce large range (regression)" "(reduce + (range 1 25000))" "312487500"
