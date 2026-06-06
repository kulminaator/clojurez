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
run_test "partition larger than coll" '(doall (partition 5 (list 1 2 3)))' 'nil'
run_test "partition empty" '(doall (partition 2 (list)))' 'nil'

# Regression: large range must not cause stack overflow (lazy-seq recursion bug)
run_test "reduce large range (regression)" "(reduce + (range 1 25000))" "312487500"
