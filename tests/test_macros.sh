#!/bin/bash
# Macros: defmacro
source tests/helpers.sh

echo "=== Macro Tests ==="
run_test "defmacro basic" '(do (defmacro my-if [test then-expr] (list (quote if) test then-expr)) (my-if true 42))' '42'
run_test "defmacro false branch" '(do (defmacro my-if [test then-expr] (list (quote if) test then-expr)) (my-if false 42))' 'nil'
run_test "defmacro with arithmetic" '(do (defmacro double [x] (list (quote +) x x)) (+ 1 (double 5)))' '11'
run_test "defmacro variadic" '(do (defmacro my-let [bindings & body] (cons (quote let) (cons bindings body))) (my-let [x 1 y 2] (+ x y)))' '3'
run_test "defmacro returns symbol" '(defmacro my-macro [x] x)' 'my-macro'
run_test "doseq single binding" '(do (def __a (atom [])) (doseq [x [1 2 3]] (swap! __a conj x)) @__a)' '[1 2 3]'
run_test "doseq nested bindings" '(do (def __a (atom [])) (doseq [x [1 2] y [:a :b]] (swap! __a conj (list x y))) @__a)' '[(1 :a) (1 :b) (2 :a) (2 :b)]'
run_test "doseq with computation" '(do (def __a (atom [])) (doseq [x [1 2 3]] (swap! __a conj (* x x))) @__a)' '[1 4 9]'
run_test "doseq empty collection" '(do (def __a (atom [])) (doseq [x []] (swap! __a conj x)) @__a)' '[]'
run_test "doseq returns nil" '(doseq [x [1 2]] x)' 'nil'
run_test "doseq with list" '(do (def __a (atom [])) (doseq [x (list 10 20 30)] (swap! __a conj (inc x))) @__a)' '[11 21 31]'
