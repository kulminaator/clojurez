#!/bin/bash
# Core Library: update, if-not, drop, apply, comp, partial, fnil, juxt, atom, identity, even?, odd?, zero?, pos?, neg?, abs, max, min, cons, second, third
source tests/helpers.sh

echo "=== Core Library Tests ==="
run_test_cmd "update" "$VM -e '(update {:a 1} :a inc)'" "{:a 2}"
run_test "if-not false" '(if-not false :yes :no)' ":yes"
run_test "if-not true" '(if-not true :yes :no)' ":no"
run_test "if-not nil 2arg" '(if-not nil :yes)' ":yes"
run_test "if-not true 2arg" '(if-not true :yes)' "nil"

run_test "drop list" '(drop 2 (list 1 2 3 4 5))' "(3 4 5)"
run_test "drop zero" '(drop 0 (list 1 2 3))' "(1 2 3)"
run_test "drop all" '(drop 10 (list 1 2))' "()"
run_test "drop vector" '(drop 1 [1 2 3])' "[2 3]"

run_test "apply +" '(apply + (list 1 2 3 4))' "10"
run_test "apply + with prefix" '(apply + 10 (list 1 2 3))' "16"
run_test "apply str" '(apply str "hello" (list " " "world"))' "\"hello world\""

run_test "comp single" '(do (defn f [x] (+ x 1)) ((comp f) 5))' "6"
run_test "comp two" '(do (defn f [x] (+ x 1)) (defn g [x] (* x 2)) ((comp g f) 5))' "12"
run_test "comp three" '(do (defn f [x] (+ x 1)) (defn g [x] (* x 2)) (defn h [x] (- x 1)) ((comp h g f) 5))' "11"

run_test "partial" '(do (def add3 (partial + 3)) (add3 (list 5)))' "8"
run_test "fnil" '(do (def f (fnil / 0 1)) (f 10 5))' "2"
run_test "fnil nil arg" '(do (def f (fnil / 0 1)) (f nil 5))' "0"
run_test "fnil nil second" '(do (def f (fnil / 0 1)) (f 10 nil))' "10"

run_test_cmd "juxt two" "$VM -e '(do (def f (juxt inc dec)) (f 5))'" "[6 4]"
run_test_cmd "juxt three" "$VM -e '(do (def f (juxt str inc dec)) (f 5))'" "[\"5\" 6 4]"

run_test "atom create" '(atom 5)' "#atom(5)"
run_test "atom reset!" '(do (def a (atom 5)) (reset! a 10) a)' "#atom(10)"
run_test_cmd "atom swap!" "$VM -e '(do (def a (atom 5)) (swap! a inc) a)'" "#atom(6)"
run_test "atom swap! with args" '(do (def a (atom 5)) (swap! a + 3) a)' "#atom(8)"

run_test_cmd "identity" "$VM -e '(identity 42)'" "42"

run_test_cmd "even?" "$VM -e '(even? 4)'" "true"
run_test_cmd "odd?" "$VM -e '(odd? 3)'" "true"
run_test_cmd "zero?" "$VM -e '(zero? 0)'" "true"
run_test_cmd "pos?" "$VM -e '(pos? 5)'" "true"
run_test_cmd "neg?" "$VM -e '(neg? (- 0 3))'" "true"
run_test_cmd "abs" "$VM -e '(abs (- 0 5))'" "5"
run_test_cmd "max" "$VM -e '(max 3 7)'" "7"
run_test_cmd "min" "$VM -e '(min 3 7)'" "3"
run_test_cmd "cons" "$VM -e '(cons 0 (list 1 2))'" "(0 1 2)"
run_test_cmd "second" "$VM -e '(second (list 1 2 3))'" "2"
run_test_cmd "third" "$VM -e '(third (list 1 2 3))'" "3"
