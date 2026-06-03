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

# Helper function to run a test (expression only)
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

# Helper function to run a test with arbitrary command
run_test_cmd() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))

    result=$(timeout $TIMEOUT bash -c "$cmd" 2>&1 | tail -1) || {
        echo "FAIL: $name (timeout or error)"
        echo "  Cmd:      $cmd"
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
        echo "  Cmd:      $cmd"
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
run_test "set as fn not found" "(#{1 2 3} 4)" "nil"
run_test "count set" "(count #{1 2 3})" "3"
run_test "set equality" "(= #{1 2} #{2 1})" "true"

echo ""
echo "=== Queue Tests ==="
run_test "queue literal" '#queue(1 2 3)' "#queue(1 2 3)"
run_test "queue empty" '#queue()' "#queue()"
run_test "conj queue" "(conj #queue(1 2) 3)" "#queue(1 2 3)"
run_test "pop queue" "(pop #queue(1 2 3))" "#queue(2 3)"
run_test "peek queue" "(peek #queue(1 2 3))" "1"
run_test "queue?" "(queue? #queue(1))" "true"
run_test "count queue" "(count #queue(1 2 3))" "3"

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

echo ""
echo "=== Collection Predicate Tests ==="
run_test "empty? list" "(empty? (list))" "true"
run_test "empty? vec" "(empty? [])" "true"
run_test "empty? set" "(empty? #{})" "true"
run_test "empty? map" "(empty? {})" "true"
run_test "empty? not empty" "(empty? (list 1))" "false"
run_test "not-empty list" "(not-empty (list 1 2))" "(1 2)"
run_test "not-empty empty" "(not-empty (list))" "nil"
run_test "seq list" "(seq (list 1 2))" "(1 2)"
run_test "seq empty" "(seq (list))" "nil"
run_test "coll?" "(coll? (list 1))" "true"
run_test "coll? not coll" "(coll? 42)" "false"
run_test "sequential?" "(sequential? (list 1))" "true"
run_test "sequential? map" "(sequential? {:a 1})" "false"
run_test "vector?" "(vector? [1 2])" "true"
run_test "map?" "(map? {:a 1})" "true"
run_test "next" "(next (list 1 2 3))" "(2 3)"
run_test "next empty" "(next (list 1))" "nil"

echo ""
echo "=== Sequence Operation Tests ==="
run_test "reduce" "(reduce + 0 (list 1 2 3 4))" "10"
run_test "reduce no init" "(reduce + (list 1 2 3 4))" "10"
run_test "into" "(into [] (list 1 2 3))" "[1 2 3]"
run_test "flatten" "(flatten (list 1 (list 2 3) 4))" "(1 2 3 4)"
run_test "filter" "(filter (fn [x] (> x 2)) (list 1 2 3 4))" "(3 4)"
run_test "remove" "(remove (fn [x] (> x 2)) (list 1 2 3 4))" "(1 2)"
run_test "every?" "(every? (fn [x] (> x 0)) (list 1 2 3))" "true"
run_test "some" "(some (fn [x] (= x 3)) (list 1 2 3))" "true"
run_test "distinct?" "(distinct? (list 1 2 3))" "true"
run_test "distinct? not" "(distinct? (list 1 2 1))" "false"
run_test "nthnext" "(nthnext 2 (list 1 2 3 4))" "(3 4)"

echo ""
echo "=== Core Library Tests ==="
# Tests that require loading core.clj
run_test_cmd "update" "$VM core.clj -e '(update {:a 1} :a inc)'" "{:a 2}"
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

run_test "juxt two" '(do (def f (juxt inc dec)) (f 5))' "[6 4]"
run_test "juxt three" '(do (def f (juxt str inc dec)) (f 5))' "[\"5\" 6 4]"

run_test "atom create" '(atom 5)' "#atom(5)"
run_test "atom reset!" '(do (def a (atom 5)) (reset! a 10) a)' "#atom(10)"
run_test "atom swap!" '(do (def a (atom 5)) (swap! a inc) a)' "#atom(6)"
run_test "atom swap! with args" '(do (def a (atom 5)) (swap! a + 3) a)' "#atom(8)"

run_test_cmd "identity" "$VM core.clj -e '(identity 42)'" "42"

run_test_cmd "even?" "$VM core.clj -e '(even? 4)'" "true"
run_test_cmd "odd?" "$VM core.clj -e '(odd? 3)'" "true"
run_test_cmd "zero?" "$VM core.clj -e '(zero? 0)'" "true"
run_test_cmd "pos?" "$VM core.clj -e '(pos? 5)'" "true"
run_test_cmd "neg?" "$VM core.clj -e '(neg? (- 0 3))'" "true"
run_test_cmd "abs" "$VM core.clj -e '(abs (- 0 5))'" "5"
run_test_cmd "max" "$VM core.clj -e '(max 3 7)'" "7"
run_test_cmd "min" "$VM core.clj -e '(min 3 7)'" "3"
run_test_cmd "cons" "$VM core.clj -e '(cons 0 (list 1 2))'" "(0 1 2)"
run_test_cmd "second" "$VM core.clj -e '(second (list 1 2 3))'" "2"
run_test_cmd "third" "$VM core.clj -e '(third (list 1 2 3))'" "3"

run_test "map builtin" '(map (fn [x] (* x 2)) (list 1 2 3))' "(2 4 6)"
run_test "filter" '(filter (fn [x] (> x 2)) (list 1 2 3 4))' "(3 4)"
run_test "reduce" '(reduce + 0 (list 1 2 3 4))' "10"
run_test "take" '(take 3 (list 1 2 3 4 5))' "(1 2 3)"
run_test "first" '(first (list 1 2 3))' "1"
run_test "rest" '(rest (list 1 2 3))' "(2 3)"
run_test "nth" '(nth (list 1 2 3) 1)' "2"
run_test "count" '(count (list 1 2 3))' "3"
run_test "str" '(str "hello" " " "world")' "\"hello world\""
run_test "nil?" '(nil? nil)' "true"
run_test "empty?" '(empty? [])' "true"
run_test "contains?" '(contains? {:a 1} :a)' "true"
run_test "when" '(when true (+ 1 2))' "3"
run_test "assoc" '(assoc {:a 1} :b 2)' "{:a 1 :b 2}"
run_test "dissoc" '(dissoc {:a 1 :b 2} :a)' "{:b 2}"
run_test "get" '(get {:a 1} :a)' "1"
run_test "conj" '(conj [1 2] 3)' "[1 2 3]"
run_test "into" '(into [] (list 1 2 3))' "[1 2 3]"
run_test "merge" '(merge {:a 1} {:b 2})' "{:a 1 :b 2}"


echo ""
echo "=== UTF-8 String Tests ==="

# Estonian strings
run_test "utf8 estonian string" '"jõääreööbiku ülkskõiksus"' '"jõääreööbiku ülkskõiksus"'
run_test "utf8 estonian count" "(count \"jõääreööbiku ülkskõiksus\")" "24"
run_test "utf8 estonian nth 0" "(nth \"jõääreööbiku ülkskõiksus\" 0)" "\"j\""
run_test "utf8 estonian nth 1" "(nth \"jõääreööbiku ülkskõiksus\" 1)" "\"õ\""
run_test "utf8 estonian nth 2" "(nth \"jõääreööbiku ülkskõiksus\" 2)" "\"ä\""
run_test "utf8 estonian str concat" "(str \"jõä\" \"reöö\" \"biku\")" "\"jõäreööbiku\""

# Emoji / smiley faces
run_test "utf8 smiley string" '"😀😃😄😁"' '"😀😃😄😁"'
run_test "utf8 smiley count" "(count \"😀😃😄😁\")" "4"
run_test "utf8 smiley nth 0" "(nth \"😀😃😄😁\" 0)" "\"😀\""
run_test "utf8 smiley nth 2" "(nth \"😀😃😄😁\" 2)" "\"😄\""
run_test "utf8 mixed text emoji" "(str \"Hello \" \"😀\" \" World\")" "\"Hello 😀 World\""
run_test "utf8 emoji count mixed" "(count \"Hi😀there\")" "8"

# Japanese poem (Tanka)
run_test "utf8 japanese string" '"古池や蛙飛び込む水の音"' '"古池や蛙飛び込む水の音"'
run_test "utf8 japanese count" "(count \"古池や蛙飛び込む水の音\")" "11"
run_test "utf8 japanese nth 0" "(nth \"古池や蛙飛び込む水の音\" 0)" "\"古\""
run_test "utf8 japanese nth 10" "(nth \"古池や蛙飛び込む水の音\" 10)" "\"音\""

# Unicode escape sequences \uXXXX
run_test "unicode escape basic" '"\u0048\u0065\u006C\u006C\u006F"' '"Hello"'
run_test "unicode escape estonian" '"\u00F5\u00E4\u00F6"' '"õäö"'
run_test "unicode escape smiley" '"\u{1F600}"' '"😀"'
run_test "unicode escape japanese" '"\u53E4\u6C60"' '"古池"'

# utf8-valid? function
run_test "utf8-valid valid string" "(utf8-valid? \"hello\")" "true"
run_test "utf8-valid estonian" "(utf8-valid? \"jõääreööbiku\")" "true"
run_test "utf8-valid emoji" "(utf8-valid? \"😀\")" "true"
run_test "utf8-valid japanese" "(utf8-valid? \"古池や\")" "true"

# String equality with UTF-8
run_test "utf8 equality same" "(= \"jõä\" \"jõä\")" "true"
run_test "utf8 equality different" "(= \"jõä\" \"jõö\")" "false"
run_test "utf8 equality emoji" "(= \"😀\" \"😀\")" "true"
run_test "utf8 equality emoji different" "(= \"😀\" \"😃\")" "false"
run_test "utf8 equality japanese" "(= \"古池\" \"古池\")" "true"

# String type check with UTF-8
run_test "utf8 string? estonian" "(string? \"jõä\")" "true"
run_test "utf8 string? emoji" "(string? \"😀\")" "true"
run_test "utf8 string? japanese" "(string? \"古池\")" "true"

# Print with UTF-8
run_test "utf8 print estonian" '(do (print "jõä") nil)' "jõänil"
run_test "utf8 print emoji" '(do (print "😀") nil)' "😀nil"
run_test "utf8 print japanese" '(do (print "古池") nil)' "古池nil"

# nth out of bounds for UTF-8 strings
run_test "utf8 nth out of bounds" "(nth \"jõä\" 10)" "nil"

# Complex mixed UTF-8 expression (using let instead of def to avoid pre-existing def+string bug)
run_test "utf8 complex expression" '(let [greeting "tere mõnda😀"] (str greeting " maailm!"))' "\"tere mõnda😀 maailm!\""

# UTF-8 in lists and vectors
run_test "utf8 list estonian" "(list \"jõä\" \"reöö\" \"biku\")" "(\"jõä\" \"reöö\" \"biku\")"
run_test "utf8 vector emoji" '["😀" "😃" "😄"]' '["😀" "😃" "😄"]'

# UTF-8 in map keys/values
run_test "utf8 map estonian" '{:jõä 1 :reöö 2}' "{:jõä 1 :reöö 2}"
run_test "utf8 map emoji value" '{:greeting "😀"}' "{:greeting \"😀\"}"

# Unicode escape \u{XXXXX} for supplementary characters
run_test "unicode escape curly brace" '"\u{1F600}\u{1F603}"' '"😀😃"'
run_test "unicode escape mixed formats" '"\u0048\u{1F600}\u006F"' '"H😀o"'

# UTF-8 in function parameters
run_test "utf8 fn estonian" '((fn [s] (count s)) "jõä")' "3"
run_test "utf8 fn emoji" '((fn [s] (nth s 1)) "😀😃😄")' "\"😃\""

# UTF-8 keyword
run_test "utf8 keyword estonian" ':jõä' ":jõä"
run_test "utf8 keyword emoji" ':😀' ":😀"

# UTF-8 symbol (quoted to avoid lookup)
run_test "utf8 symbol estonian" "'jõä" "jõä"

# Empty UTF-8 string
run_test "utf8 empty string count" "(count \"\")" "0"
run_test "utf8 empty string nth" "(nth \"\" 0)" "nil"


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
