#!/bin/bash
# Macros: defmacro
source tests/helpers.sh

echo "=== Macro Tests ==="
run_test "defmacro basic" '(do (defmacro my-if [test then-expr] (list (quote if) test then-expr)) (my-if true 42))' '42'
run_test "defmacro false branch" '(do (defmacro my-if [test then-expr] (list (quote if) test then-expr)) (my-if false 42))' 'nil'
run_test "defmacro with arithmetic" '(do (defmacro double [x] (list (quote +) x x)) (+ 1 (double 5)))' '11'
run_test "defmacro variadic" '(do (defmacro my-let [bindings & body] (cons (quote let) (cons bindings body))) (my-let [x 1 y 2] (+ x y)))' '3'
run_test "defmacro returns symbol" '(defmacro my-macro [x] x)' 'my-macro'
