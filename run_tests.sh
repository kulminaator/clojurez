#!/bin/bash
# Test runner for Clojure VM
# All tests must complete within 10 seconds each

set -e

PASS=0
FAIL=0
TOTAL=0

VM="./main"
TIMEOUT=10

# Build the VM
echo "Building VM..."
zig build-exe -fsingle-threaded src/main.zig 2>&1
echo ""

# Helper function to run a test
run_test() {
    local name="$1"
    local input="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))

    result=$(timeout $TIMEOUT $VM -e "$input" 2>&1) || {
        echo "FAIL: $name (timeout or error)"
        echo "  Input:    $input"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        FAIL=$((FAIL + 1))
        return
    }

    # Trim whitespace
    result=$(echo "$result" | tr -d '[:space:]')
    expected=$(echo "$expected" | tr -d '[:space:]')

    if [ "$result" = "$expected" ]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  Input:    $input"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Arithmetic Tests ==="
run_test "add two" "(+ 1 2)" "3"
run_test "add many" "(+ 1 2 3 4)" "10"
run_test "subtract" "(- 10 3)" "7"
run_test "multiply" "(* 6 7)" "42"
run_test "divide" "(/ 10 2)" "5"
run_test "divide float" "(/ 10 3)" "3.3333333333333335"
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
run_test "nil literal" "nil" "nil"
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

echo ""
echo "=== List/Sequence Tests ==="
run_test "list" "(list 1 2 3)" "(1 2 3)"
run_test "vec" "(vec 1 2 3)" "[1 2 3]"
run_test "count list" "(count (list 1 2 3))" "3"
run_test "first" "(first (list 1 2 3))" "1"
run_test "rest" "(rest (list 1 2 3))" "(2 3)"
run_test "nth" "(nth (list 1 2 3) 1)" "2"

echo ""
echo "=== Special Forms ==="
run_test "def" "(def x 42)" "x"
run_test "if true" "(if true 1 2)" "1"
run_test "if false" "(if false 1 2)" "2"
run_test "quote" "'(1 2 3)" "(1 2 3)"
run_test "do" "(do 1 2 3)" "3"

echo ""
echo "=== Function Tests ==="
run_test "fn call" "((fn [x] (* x x)) 5)" "25"
run_test "defn" "(defn square [n] (* n n))" "square"

echo ""
echo "=== I/O Tests ==="
# println prints to stdout and returns nil
# We can't easily test println output in this framework, so we just verify it doesn't error
# Instead test print which also works
run_test "print works" '(do (print "x") nil)' "xnil"

echo ""
echo "=== Thread Macros ==="
run_test "thread-last basic" '(->> 1 (+ 2) (* 3))' "9"
run_test "thread-first basic" '(-> 1 (+ 2) (* 3))' "9"

echo ""
echo "=== Sequence Functions ==="
run_test "iterate" "(take 5 (iterate (fn [x] (+ x 1)) 0))" "(0 1 2 3 4)"
run_test "map" "(map (fn [x] (* x 2)) (list 1 2 3))" "(2 4 6)"
run_test "take" "(take 3 (list 1 2 3 4 5))" "(1 2 3)"

echo ""
echo "=== Destructuring ==="
run_test "vector destructure" '((fn [[a b]] (+ a b)) [1 2])' "3"
run_test "nested destructure" '((fn [[[a b] c]] (+ a b c)) [[1 2] 3])' "6"

echo ""
echo "=== Map Tests ==="
run_test "map literal" '{:a 1 :b 2}' "{:a 1 :b 2}"
run_test "get from map" '(get {:a 1 :b 2} :a)' "1"
run_test "get missing key" '(get {:a 1} :b)' "nil"
run_test "assoc new key" '(assoc {:a 1} :b 2)' "{:a 1 :b 2}"
run_test "assoc multiple" '(assoc {:a 1} :b 2 :c 3)' "{:a 1 :b 2 :c 3}"

echo ""
echo "=== Collection Tests ==="
run_test "conj vector" '(conj [1 2] 3)' "[1 2 3]"
run_test "pop vector" '(pop [1 2 3])' "[1 2]"
run_test "last vector" '(last [1 2 3])' "3"
run_test "reverse vector" '(reverse [1 2 3])' "[3 2 1]"
run_test "range" '(range 1 4)' "(1 2 3)"

echo ""
echo "=== Namespace Tests ==="
run_test "ns declaration" '(ns my.core)' "nil"

echo ""
echo "=== Hanoi Sample ==="
# Run the hanoi sample and check output
hanoi_result=$(timeout 10 ./main samples/sample_2_hanoi/hanoi/core.clj 2>&1 | tail -n +5)
expected_hanoi=$(cat samples/sample_2_hanoi/expected_output.txt)
TOTAL=$((TOTAL + 1))
if [ "$hanoi_result" = "$expected_hanoi" ]; then
    echo "PASS: hanoi sample"
    PASS=$((PASS + 1))
else
    echo "FAIL: hanoi sample"
    echo "  Expected: $expected_hanoi"
    echo "  Got:      $hanoi_result"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Fibonacci Sample ==="
# Run the fibonacci sample and check output
fib_result=$(timeout 10 ./main samples/sample_1_fibonacci/core.clj 2>&1 | tail -1)
expected="(0 1 1 2 3 5 8 13 21 34)"
TOTAL=$((TOTAL + 1))
if [ "$fib_result" = "$expected" ]; then
    echo "PASS: fibonacci sample"
    PASS=$((PASS + 1))
else
    echo "FAIL: fibonacci sample"
    echo "  Expected: $expected"
    echo "  Got:      $fib_result"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Summary ==="
echo "Total: $TOTAL, Passed: $PASS, Failed: $FAIL"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
