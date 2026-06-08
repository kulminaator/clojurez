#!/bin/bash
# Sets: literals, set, set?, conj, disj, count, equality
source tests/helpers.sh

echo "=== Set Tests ==="
run_test "set literal" '#{1 2 3}' "#{1 2 3}"
run_test "set empty" '#{}' "#{}"
run_test "set from list" "(set (list 1 2 2 3))" "#{1 2 3}"
run_test "set?" "(set? #{1 2})" "true"
run_test "set? not set" "(set? (list 1 2))" "false"
run_test "conj set" "(conj #{1 2} 3)" "#{1 2 3}"
run_test "conj set dup" "(conj #{1 2} 1)" "#{1 2}"
run_test "disj set" "(disj #{1 2 3} 2)" "#{1 3}"
run_test "set as fn found" "(#{1 2 3} 2)" "2"
run_test "set as fn not found" "(#{1 2 3} 4)" ""
run_test "count set" "(count #{1 2 3})" "3"
run_test "set equality" "(= #{1 2} #{2 1})" "true"
