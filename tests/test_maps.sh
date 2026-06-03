#!/bin/bash
# Maps: literals, get, assoc, keys, vals, dissoc, merge, contains?, hash-map
source tests/helpers.sh

echo "=== Map Tests ==="
run_test "map literal" '{:a 1 :b 2}' "{:a 1 :b 2}"
run_test "get from map" '(get {:a 1 :b 2} :a)' "1"
run_test "get missing key" '(get {:a 1} :b)' "nil"
run_test "assoc new key" '(assoc {:a 1} :b 2)' "{:a 1 :b 2}"
run_test "assoc multiple" '(assoc {:a 1} :b 2 :c 3)' "{:a 1 :b 2 :c 3}"

echo ""
echo "=== Map Enhancement Tests ==="
run_test "keys" "(keys {:a 1 :b 2})" "(:a :b)"
run_test "vals" "(vals {:a 1 :b 2})" "(1 2)"
run_test "dissoc" "(dissoc {:a 1 :b 2} :a)" "{:b 2}"
run_test "merge" "(merge {:a 1} {:b 2})" "{:a 1 :b 2}"
run_test "merge override" "(merge {:a 1} {:a 2})" "{:a 2}"
run_test "contains? map" "(contains? {:a 1} :a)" "true"
run_test "contains? map missing" "(contains? {:a 1} :b)" "false"
run_test "contains? set" "(contains? #{1 2 3} 2)" "true"
run_test "map as fn" "({:a 1 :b 2} :a)" "1"
run_test "map as fn not found" "({:a 1} :b)" "nil"
run_test "map as fn not-found" "({:a 1} :b :default)" ":default"
run_test "count map" "(count {:a 1 :b 2})" "2"

# hash-map tests
run_test "hash-map empty" "(hash-map)" "{}"
run_test "hash-map basic" "(hash-map :a 1 :b 2)" "{:a 1 :b 2}"
run_test "hash-map string keys" '(hash-map "hello" "world" 42 true)' '{"hello" "world" 42 true}'
run_test "hash-map duplicate key" "(hash-map :a 1 :a 2)" "{:a 2}"
run_test "hash-map mixed types" '(hash-map :x "str" :y [1 2] :z #{3 4})' '{:x "str" :y [1 2] :z #{3 4}}'
run_test_cmd "hash-map odd args" 'timeout 10 ./main -e "(hash-map :a 1 :b)" 2>&1 | head -1' 'error: ArityError'

# assoc on nil
echo ""
echo "=== Assoc on Nil ==="
run_test "assoc nil single kv" '(assoc nil :a 1)' '{:a 1}'
run_test "assoc nil multiple kvs" '(assoc nil :a 1 :b 2)' '{:a 1 :b 2}'
run_test "assoc nil then assoc" '(assoc (assoc nil :a 1) :b 2)' '{:a 1 :b 2}'
