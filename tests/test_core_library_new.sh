#!/bin/bash
# New Core Library Functions: constantly, complement, empty, get-in, assoc-in, zipmap, interpose, when-not, when-some, if-let
source tests/helpers.sh

echo "=== New Core Library Functions ==="

# constantly
run_test "constantly returns fn" '(constantly 42)' '#function'
run_test "constantly calls with no args" '((constantly 42))' '42'
run_test "constantly calls with args" '((constantly 42) 1 2 3)' '42'

# complement
run_test "complement returns fn" '(complement nil?)' '#function'
run_test "complement nil? true" '((complement nil?) 1)' 'true'
run_test "complement nil? false" '((complement nil?) nil)' 'false'
run_test "complement even?" '((complement even?) 3)' 'true'
run_test "complement even? even" '((complement even?) 4)' 'false'

# empty
run_test "empty list" '(empty (list 1 2))' '()'
run_test "empty vector" '(empty [1 2])' '[]'
run_test "empty map" '(empty {:a 1})' '{}'
run_test "empty set" '(empty #{1 2})' '#{}'
run_test "empty queue" '(empty #queue(1 2))' '#queue()'

# get-in
run_test "get-in nested" '(get-in {:a {:b {:c 42}}} [:a :b :c])' '42'
run_test "get-in single key" '(get-in {:a 1} [:a])' '1'
run_test "get-in missing key" '(get-in {:a 1} [:b])' ''
run_test "get-in deep missing" '(get-in {:a {:b 1}} [:a :c :d])' ''

# assoc-in
run_test "assoc-in existing" '(assoc-in {:a {:b 1}} [:a :c] 2)' '{:a {:b 1 :c 2}}'
run_test "assoc-in create nested" '(assoc-in {} [:a :b :c] 42)' '{:a {:b {:c 42}}}'
run_test "assoc-in single key" '(assoc-in {:a 1} [:b] 2)' '{:a 1 :b 2}'

# zipmap
run_test "zipmap equal length" '(zipmap (list :a :b :c) (list 1 2 3))' '{:a 1 :b 2 :c 3}'
run_test "zipmap keys longer" '(zipmap (list :a :b) (list 1))' '{:a 1}'
run_test "zipmap empty" '(zipmap (list) (list))' '{}'

# interpose
run_test "interpose basic" '(interpose "," (list 1 2 3))' '(1 "," 2 "," 3)'
run_test "interpose empty" '(interpose 0 (list))' '()'
run_test "interpose single" '(interpose 0 (list 1))' '(1)'
run_test "interpose two" '(interpose "-" (list "a" "b"))' '("a" "-" "b")'

# when-not
run_test "when-not false" '(when-not false "yes")' '"yes"'
run_test "when-not true" '(when-not true "yes")' ''
run_test "when-not multi body" '(when-not false (+ 1 2))' '3'

# when-some
run_test "when-some value" '(when-some [x 5] (* x 2))' '10'
run_test "when-some nil" '(when-some [x nil] (* x 2))' ''
run_test "when-some string" '(when-some [x "hi"] (str x " there"))' '"hi there"'

# if-let
run_test "if-let truthy" '(if-let [x 5] (* x 2) "nope")' '10'
run_test "if-let nil" '(if-let [x nil] (* x 2) "nope")' '"nope"'
run_test "if-let false" '(if-let [x false] "yes" "no")' '"no"'
