#!/bin/bash
# New Core Functions: fn?, keyword, mapcat, key, val, doall, into-array, trampoline
source tests/helpers.sh

echo "=== New Core Function Tests ==="
# fn?
run_test "fn? builtin" "(fn? +)" "true"
run_test "fn? user fn" "(fn? (fn [] 1))" "true"
run_test "fn? not fn" "(fn? 42)" "false"

# keyword
run_test "keyword from string" '(keyword "foo")' ":foo"
run_test "keyword from symbol" "(keyword 'bar)" ":bar"
run_test "keyword from keyword" '(keyword :baz)' ":baz"
run_test "keyword namespaced" '(keyword "ns" "name")' ":ns/name"

# map (as first-class function)
run_test "map as fn" "(doall (map inc (list 1 2 3)))" "(2 3 4)"

# mapcat
run_test "mapcat" '(mapcat (fn [x] (list x (* x x))) (list 1 2 3))' "(1 1 2 4 3 9)"

# key
run_test "key from entry" '(key {:key :a :val 1})' ":a"

# val
run_test "val from entry" '(val {:key :a :val 1})' "1"

# doall
run_test "doall" "(doall (list 1 2 3))" "(1 2 3)"

# into-array
run_test "into-array" "(into-array (list 1 2 3))" "[1 2 3]"

# trampoline
run_test "trampoline simple" "(trampoline (fn [] 42))" "42"
run_test "trampoline nested" "(trampoline (fn [] (fn [] (fn [] 42))))" "42"
run_test "trampoline mutual recursion" '(do (defn even? [n] (if (zero? n) true (fn [] (odd? (- n 1))))) (defn odd? [n] (if (zero? n) false (fn [] (even? (- n 1))))) (trampoline even? 10))' "true"

# iterate
run_test "iterate builtin" "(take 5 (iterate inc 0))" "(0 1 2 3 4)"
