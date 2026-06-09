#!/bin/bash
# Core Library: update, if-not, drop, apply, comp, partial, fnil, juxt, atom, identity, even?, odd?, zero?, pos?, neg?, abs, max, min, cons, second, third
source tests/helpers.sh

echo "=== Core Library Tests ==="
run_test_cmd "update" "$VM -e '(update {:a 1} :a inc)'" "{:a 2}"
run_test "if-not false" '(if-not false :yes :no)' ":yes"
run_test "if-not true" '(if-not true :yes :no)' ":no"
run_test "if-not nil 2arg" '(if-not nil :yes)' ":yes"
run_test "if-not true 2arg" '(if-not true :yes)' ""

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

echo ""
echo "=== Mod Tests ==="
run_test "mod positive" '(mod 7 3)' '1'
run_test "mod neg dividend" '(mod -7 3)' '2'
run_test "mod neg divisor" '(mod 7 -3)' '-2'
run_test "mod both neg" '(mod -7 -3)' '-1'
run_test "mod zero" '(mod 0 5)' '0'
run_test "mod exact" '(mod 6 3)' '0'
run_test "mod float" '(mod 7.5 3.0)' '1.5'
run_test "mod float neg" '(mod -7.5 3.0)' '1.5'

echo ""
echo "=== Quot Tests ==="
run_test "quot positive" '(quot 7 3)' '2'
run_test "quot neg dividend" '(quot -7 3)' '-2'
run_test "quot neg divisor" '(quot 7 -3)' '-2'
run_test "quot both neg" '(quot -7 -3)' '2'
run_test "quot zero" '(quot 0 5)' '0'
run_test "quot exact" '(quot 6 3)' '2'

echo ""
echo "=== Compare Tests ==="
run_test "compare less" '(compare 1 2)' '-1'
run_test "compare greater" '(compare 2 1)' '1'
run_test "compare equal" '(compare 1 1)' '0'
run_test "compare int float" '(compare 1 1.0)' '0'
run_test "compare string lt" '(compare "a" "b")' '-1'
run_test "compare string gt" '(compare "b" "a")' '1'
run_test "compare string eq" '(compare "a" "a")' '0'
run_test "compare nil less" '(compare nil 1)' '-1'
run_test "compare nil greater" '(compare 1 nil)' '1'
run_test "compare nil nil" '(compare nil nil)' '0'

echo ""
echo "=== Double Eq Tests ==="
run_test "== int float equal" '(== 1 1.0)' 'true'
run_test "== int int equal" '(== 1 1)' 'true'
run_test "== int int not equal" '(== 1 2)' 'false'
run_test "== float float equal" '(== 1.0 1.0)' 'true'
run_test "== float float not equal" '(== 1.0 2.0)' 'false'
run_test "== multiple equal" '(== 1 1.0 1)' 'true'
run_test "== multiple not equal" '(== 1 2 3)' 'false'
run_test "== zero args" '(==)' 'true'
run_test "== one arg" '(== 5)' 'true'

echo ""
echo "=== Rationalize Tests ==="
run_test "rationalize int" '(rationalize 5)' '5'
run_test "rationalize 1.0" '(rationalize 1.0)' '1'
run_test "rationalize 1.5" '(rationalize 1.5)' '3/2'
run_test "rationalize 0.1" '(rationalize 0.1)' '1/10'
run_test "rationalize 0.25" '(rationalize 0.25)' '1/4'
run_test "rationalize 2.0" '(rationalize 2.0)' '2'
run_test "rationalize 0.33" '(rationalize 0.33)' '33/100'
run_test "rationalize neg" '(rationalize -1.5)' '-3/2'
