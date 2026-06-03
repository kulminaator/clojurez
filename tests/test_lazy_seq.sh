#!/bin/bash
# Lazy Sequences: lazy-seq, loop/recur, gensym
source tests/helpers.sh

echo "=== Loop/Recur Multiple Bindings ==="
run_test "loop recur two bindings" '(loop [x 0 y 10] (if (< x y) (recur (+ x 1) (- y 1)) x))' '5'
run_test "loop recur three bindings" '(loop [a 0 b 1 c 2] (if (< a 5) (recur (+ a 1) (+ b 1) (+ c 1)) a))' '5'
run_test "loop recur single binding" '(loop [x 0] (if (< x 3) (recur (+ x 1)) x))' '3'
run_test "loop recur no recur" '(loop [x 10] x)' '10'

echo ""
echo "=== Take with Lazy-seq from Variables ==="
run_test "take from lazy-seq variable" '(let [xs (lazy-seq (list 1 2 3 4 5))] (take 3 xs))' '(1 2 3)'
run_test "take all from lazy-seq variable" '(let [xs (lazy-seq (list 1 2))] (take 5 xs))' '(1 2)'
run_test "take zero from lazy-seq variable" '(let [xs (lazy-seq (list 1 2 3))] (take 0 xs))' '()'

echo ""
echo "=== Lazy-seq Scoping ==="
run_test "lazy-seq uses let helper" '(let [f (fn [x] (+ x 1))] (doall (lazy-seq (list (f 5)))))' '(6)'
run_test "lazy-seq multiple let refs" '(let [inc2 (fn [x] (+ x 2))] (doall (lazy-seq (list (inc2 1) (inc2 2) (inc2 3)))))' '(3 4 5)'

echo ""
echo "=== Gensym ==="
run_test "gensym returns symbol" '(symbol? (gensym))' 'true'
run_test "gensym unique" '(let [a (gensym) b (gensym)] (if (= a b) false true))' 'true'
run_test "gensym with prefix" '(let [g (gensym "tmp")] (and (symbol? g) (string? (str g))))' 'true'
