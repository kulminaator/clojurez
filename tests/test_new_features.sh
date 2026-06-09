#!/bin/bash
# Test new features: rand, rand-int, rand-nth, shuffle, hash-set,
# drop-last, take-last, drop-while, cycle, split-at, split-with,
# repeat, replicate, comparator, sort, sort-by

set -e
BIN="./zig-out/bin/clojurez"
PASS=0
FAIL=0

run_test() {
    local name="$1"
    local expr="$2"
    local expected="$3"

    result=$(timeout 10s $BIN -e "$expr" 2>/dev/null) || {
        echo "FAIL: $name (timeout or error)"
        FAIL=$((FAIL + 1))
        return
    }

    if [ "$result" = "$expected" ]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Random Functions ==="
run_test "rand returns float in [0,1)" "(let [r (rand)] (and (>= r 0.0) (< r 1.0)))" "true"
run_test "rand-int returns int in [0,n)" "(let [r (rand-int 100)] (and (>= r 0) (< r 100)))" "true"
run_test "rand-nth picks from coll" "(let [r (rand-nth [10 20 30])] (or (= r 10) (= r 20) (= r 30)))" "true"

echo "=== Shuffle ==="
run_test "shuffle produces permutation" "(let [s (shuffle [1 2 3])] (= (set s) #{1 2 3}))" "true"
run_test "shuffle empty" "(shuffle [])" "[]"

echo "=== hash-set ==="
run_test "hash-set creates set" "(hash-set 1 2 3)" "#{1 2 3}"
run_test "hash-set empty" "(hash-set)" "#{}"
run_test "hash-set deduplicates" "(hash-set 1 1 2)" "#{1 2}"

echo "=== drop-last ==="
run_test "drop-last 2" "(drop-last 2 [1 2 3 4 5])" "(1 2 3)"
run_test "drop-last default" "(drop-last [1 2 3 4 5])" "(1 2 3 4)"
run_test "drop-last 0" "(drop-last 0 [1 2 3])" "(1 2 3)"

echo "=== take-last ==="
run_test "take-last 2" "(take-last 2 [1 2 3 4 5])" "(4 5)"
run_test "take-last all" "(take-last 10 [1 2 3])" "(1 2 3)"

echo "=== drop-while ==="
run_test "drop-while basic" "(drop-while (fn [x] (< x 3)) [1 2 3 4])" "(3 4)"
run_test "drop-while all" "(drop-while (fn [x] true) [1 2 3])" "()"
run_test "drop-while none" "(drop-while (fn [x] false) [1 2 3])" "(1 2 3)"

echo "=== cycle ==="
run_test "cycle basic" "(doall (take 5 (cycle [1 2])))" "(1 2 1 2 1)"
run_test "cycle single" "(doall (take 3 (cycle [42])))" "(42 42 42)"
run_test "cycle empty" "(doall (take 3 (cycle [])))" "()"

echo "=== split-at ==="
run_test "split-at basic" "(doall (map doall (split-at 2 [1 2 3 4 5])))" "((1 2) [3 4 5])"

echo "=== split-with ==="
run_test "split-with basic" "(doall (map doall (split-with (fn [x] (< x 3)) [1 2 3 4])))" "((1 2) (3 4))"

echo "=== repeat ==="
run_test "repeat n x" "(doall (repeat 3 :x))" "(:x :x :x)"
run_test "repeat 0 x" "(doall (repeat 0 :x))" "()"
run_test "repeat infinite take" "(doall (take 3 (repeat :a)))" "(:a :a :a)"

echo "=== replicate ==="
run_test "replicate basic" "(doall (replicate 3 :x))" "(:x :x :x)"

echo "=== comparator ==="
run_test "comparator less" "((comparator <) 1 2)" "-1"
run_test "comparator greater" "((comparator <) 2 1)" "1"
run_test "comparator equal" "((comparator <) 1 1)" "0"

echo "=== sort ==="
run_test "sort ascending" "(sort [3 1 4 1 5])" "(1 1 3 4 5)"
run_test "sort strings" "(sort [\"b\" \"a\" \"c\"])" "(\"a\" \"b\" \"c\")"
run_test "sort empty" "(sort [])" "()"

echo "=== sort-by ==="
run_test "sort-by count" "(sort-by count [\"bb\" \"a\" \"ccc\"])" "(\"a\" \"bb\" \"ccc\")"
run_test "sort-by neg" "(sort-by (fn [x] (* -1 x)) [1 2 3])" "(3 2 1)"

echo ""
echo "========================================"
echo "=== Test Summary ==="
echo "Total: $((PASS + FAIL)), Passed: $PASS, Failed: $FAIL"
echo "========================================"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
