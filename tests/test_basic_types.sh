#!/bin/bash
# Basic Types: Arithmetic, Comparison, Boolean, Strings, Type checks
source tests/helpers.sh

echo "=== Arithmetic Tests ==="
run_test "add two" "(+ 1 2)" "3"
run_test "add many" "(+ 1 2 3 4)" "10"
run_test "subtract" "(- 10 3)" "7"
run_test "multiply" "(* 6 7)" "42"
run_test "divide" "(/ 10 2)" "5"
run_test "divide float" "(/ 10.0 3)" "3.3333333333333335"
run_test "divide ratio" "(/ 10 3)" "10/3"
run_test "modulo" "(rem 10 3)" "1"

echo ""
echo "=== Comparison Tests ==="
run_test "equal" "(= 1 1)" "true"
run_test "not equal" "(= 1 2)" "false"
run_test "less than" "(< 1 2)" "true"
run_test "greater than" "(> 2 1)" "true"
run_test "less equal" "(<= 1 1)" "true"
run_test "greater equal" "(>= 2 1)" "true"

echo ""
echo "=== Boolean Tests ==="
run_test "true literal" "true" "true"
run_test "false literal" "false" "false"
run_test "nil literal" "nil" ""
run_test "not true" "(not true)" "false"
run_test "not false" "(not false)" "true"

echo ""
echo "=== String Tests ==="
run_test "string literal" '"hello"' '"hello"'
run_test "string concat" "(str \"hello\" \" \" \"world\")" "\"hello world\""

echo ""
echo "=== Type Tests ==="
run_test "nil?" "(nil? nil)" "true"
run_test "nil? not nil" "(nil? 1)" "false"
run_test "number?" "(number? 42)" "true"
run_test "string?" "(string? \"hi\")" "true"
run_test "list?" "(list? '(1 2))" "true"
