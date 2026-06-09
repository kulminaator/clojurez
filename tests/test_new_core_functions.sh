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

# symbol?
run_test "symbol? symbol" "(symbol? 'foo)" "true"
run_test "symbol? not symbol" "(symbol? 42)" "false"
run_test "symbol? keyword" "(symbol? :foo)" "false"
run_test "zig.core/symbol?" "(zig.core/symbol? 'x)" "true"

# keyword?
run_test "keyword? keyword" "(keyword? :foo)" "true"
run_test "keyword? not keyword" "(keyword? 'foo)" "false"
run_test "keyword? namespaced" "(keyword? :ns/name)" "true"
run_test "zig.core/keyword?" "(zig.core/keyword? :x)" "true"

# true?
run_test "true? true" "(true? true)" "true"
run_test "true? false" "(true? false)" "false"
run_test "true? nil" "(true? nil)" "false"
run_test "true? 1" "(true? 1)" "false"
run_test "zig.core/true?" "(zig.core/true? true)" "true"

# false?
run_test "false? false" "(false? false)" "true"
run_test "false? true" "(false? true)" "false"
run_test "false? nil" "(false? nil)" "false"
run_test "false? 0" "(false? 0)" "false"
run_test "zig.core/false?" "(zig.core/false? false)" "true"

# queue?
run_test "queue? queue" "(queue? #queue(1 2 3))" "true"
run_test "queue? vector" "(queue? [1 2 3])" "false"
run_test "queue? list" "(queue? (list 1 2 3))" "false"
run_test "queue? empty queue" "(queue? #queue())" "true"
run_test "zig.core/queue?" "(zig.core/queue? #queue(1))" "true"

# coll?
run_test "coll? vector" "(coll? [1 2 3])" "true"
run_test "coll? list" "(coll? (list 1 2 3))" "true"
run_test "coll? map" "(coll? {:a 1})" "true"
run_test "coll? set" "(coll? #{1 2 3})" "true"
run_test "coll? not coll" "(coll? 42)" "false"
run_test "coll? nil" "(coll? nil)" "false"
run_test "zig.core/coll?" "(zig.core/coll? #{1})" "true"

# sequential?
run_test "sequential? vector" "(sequential? [1 2 3])" "true"
run_test "sequential? list" "(sequential? '(1 2 3))" "true"
run_test "sequential? map" "(sequential? {:a 1})" "false"
run_test "sequential? set" "(sequential? #{1 2 3})" "false"
run_test "zig.core/sequential?" "(zig.core/sequential? '(1))" "true"

# not-empty
run_test "not-empty list" "(not-empty (list 1 2 3))" "(1 2 3)"
run_test "not-empty empty list" "(not-empty ())" ""
run_test "not-empty vector" "(not-empty [1 2 3])" "[1 2 3]"
run_test "not-empty empty vector" "(not-empty [])" ""
run_test "not-empty map" "(not-empty {:a 1})" "{:a 1}"
run_test "not-empty empty map" "(not-empty {})" ""
run_test "zig.core/not-empty" "(zig.core/not-empty [1])" "[1]"

# read-line (verify function exists and is callable)
run_test "read-line is fn" "(fn? read-line)" "true"
run_test "zig.core/read-line is fn" "(fn? zig.core/read-line)" "true"

# int?
run_test "int? int" "(int? 42)" "true"
run_test "int? float" "(int? 3.14)" "false"
run_test "zig.core/int?" "(zig.core/int? 100)" "true"

# integer?
run_test "integer? int" "(integer? 42)" "true"
run_test "integer? float" "(integer? 3.14)" "false"
run_test "zig.core/integer?" "(zig.core/integer? 100)" "true"

# double?
run_test "double? double" "(double? 3.14)" "true"
run_test "double? int" "(double? 42)" "false"
run_test "zig.core/double?" "(zig.core/double? 1.0)" "true"

# float?
run_test "float? float" "(float? 3.14)" "true"
run_test "float? int" "(float? 42)" "false"
run_test "zig.core/float?" "(zig.core/float? 1.0)" "true"

# NaN?
run_test "NaN? string" "(NaN? \"hello\")" "false"
run_test "NaN? int" "(NaN? 42)" "false"
run_test "zig.core/NaN?" "(zig.core/NaN? 0)" "false"

# infinite?
run_test "infinite? int" "(infinite? 42)" "false"
run_test "infinite? float" "(infinite? 3.14)" "false"
run_test "zig.core/infinite?" "(zig.core/infinite? 0)" "false"

# int (conversion)
run_test "int from float" "(int 3.7)" "3"
run_test "int from int" "(int 42)" "42"
run_test "zig.core/int" "(zig.core/int 5.9)" "5"

# float (conversion)
run_test "float from int" "(float 42)" "42"
run_test "zig.core/float" "(zig.core/float 10)" "10"

# double (conversion)
run_test "double from int" "(double 42)" "42"
run_test "zig.core/double" "(zig.core/double 10)" "10"

# bigint (conversion)
run_test "bigint from int" "(bigint 42)" "42"
run_test "bigint from float" "(bigint 3.14)" "3"
run_test "zig.core/bigint" "(zig.core/bigint 100)" "100"

# bit-not
run_test "bit-not 0" "(bit-not 0)" "-1"
run_test "bit-not -1" "(bit-not -1)" "0"
run_test "zig.core/bit-not" "(zig.core/bit-not 0)" "-1"

# bit-xor
run_test "bit-xor" "(bit-xor 5 3)" "6"
run_test "bit-xor multi" "(bit-xor 1 2 4)" "7"
run_test "zig.core/bit-xor" "(zig.core/bit-xor 5 3)" "6"

# bit-and-not
run_test "bit-and-not" "(bit-and-not 5 3)" "4"
run_test "zig.core/bit-and-not" "(zig.core/bit-and-not 5 3)" "4"

# bit-clear
run_test "bit-clear" "(bit-clear 5 1)" "5"
run_test "bit-clear bit 0" "(bit-clear 5 0)" "4"
run_test "zig.core/bit-clear" "(zig.core/bit-clear 5 0)" "4"

# bit-set
run_test "bit-set" "(bit-set 4 1)" "6"
run_test "bit-set already set" "(bit-set 5 0)" "5"
run_test "zig.core/bit-set" "(zig.core/bit-set 4 1)" "6"

# bit-flip
run_test "bit-flip clear" "(bit-flip 5 2)" "1"
run_test "bit-flip set" "(bit-flip 4 0)" "5"
run_test "zig.core/bit-flip" "(zig.core/bit-flip 5 2)" "1"

# bit-shift-left
run_test "bit-shift-left" "(bit-shift-left 3 2)" "12"
run_test "bit-shift-left zero" "(bit-shift-left 5 0)" "5"
run_test "zig.core/bit-shift-left" "(zig.core/bit-shift-left 3 2)" "12"

# bit-shift-right
run_test "bit-shift-right" "(bit-shift-right 12 2)" "3"
run_test "bit-shift-right zero" "(bit-shift-right 5 0)" "5"
run_test "zig.core/bit-shift-right" "(zig.core/bit-shift-right 12 2)" "3"

# unsigned-bit-shift-right
run_test "unsigned-bit-shift-right neg" "(unsigned-bit-shift-right -1 2)" "4611686018427387903"
run_test "unsigned-bit-shift-right pos" "(unsigned-bit-shift-right 12 2)" "3"
run_test "zig.core/unsigned-bit-shift-right" "(zig.core/unsigned-bit-shift-right 12 2)" "3"

# bit-test
run_test "bit-test set" "(bit-test 5 2)" "true"
run_test "bit-test clear" "(bit-test 5 1)" "false"
run_test "zig.core/bit-test" "(zig.core/bit-test 5 2)" "true"
