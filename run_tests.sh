#!/bin/bash
# Test runner for Clojure VM
# All tests must complete within 10 seconds each

set -e

PASS=0
FAIL=0
TOTAL=0

VM="./main"
TIMEOUT=10

# Build the VM (copies core.clj into zig package for @embedFile)
echo "Building VM..."
cp src/clj/core.clj src/zig/clj/core.clj 2>/dev/null || true
zig build-exe -fsingle-threaded src/zig/main.zig 2>&1
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

# Variadic function tests
run_test "variadic fn all rest" '(do (defn var-fn [& args] args) (var-fn 1 2 3))' '(1 2 3)'
run_test "variadic fn empty rest" '(do (defn var-fn [& args] args) (var-fn))' '()'
run_test "variadic fn mixed" '(do (defn var-mix [a b & rest] (list a b rest)) (var-mix 1 2 3 4 5))' '(1 2 (3 4 5))'
run_test "variadic fn no extra" '(do (defn var-mix [a b & rest] (list a b rest)) (var-mix 1 2))' '(1 2 ())'
run_test "variadic fn inline" '((fn [& args] args) 10 20 30)' '(10 20 30)'
run_test "variadic fn with defn" '(do (defn my-sum [init & nums] (reduce + init nums)) (my-sum 0 1 2 3 4))' '10'
run_test_cmd "variadic fn arity error" 'timeout 10 ./main -e "(do (defn var-mix [a b & rest] (list a b rest)) (var-mix 1))" 2>&1 | head -1' 'error: ArityError'

echo ""
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

# defmacro
run_test "defmacro basic" '(do (defmacro my-if [test then-expr] (list (quote if) test then-expr)) (my-if true 42))' '42'
run_test "defmacro false branch" '(do (defmacro my-if [test then-expr] (list (quote if) test then-expr)) (my-if false 42))' 'nil'
run_test "defmacro with arithmetic" '(do (defmacro double [x] (list (quote +) x x)) (+ 1 (double 5)))' '11'
run_test "defmacro variadic" '(do (defmacro my-let [bindings & body] (cons (quote let) (cons bindings body))) (my-let [x 1 y 2] (+ x y)))' '3'
run_test "defmacro returns symbol" '(defmacro my-macro [x] x)' 'my-macro'

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
run_test "map" "(doall (map (fn [x] (* x 2)) (list 1 2 3)))" "(2 4 6)"
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
run_test "range" '(doall (range 1 4))' "(1 2 3)"

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

# hash-map tests
run_test "hash-map empty" "(hash-map)" "{}"
run_test "hash-map basic" "(hash-map :a 1 :b 2)" "{:a 1 :b 2}"
run_test "hash-map string keys" '(hash-map "hello" "world" 42 true)' '{"hello" "world" 42 true}'
run_test "hash-map duplicate key" "(hash-map :a 1 :a 2)" "{:a 2}"
run_test "hash-map mixed types" '(hash-map :x "str" :y [1 2] :z #{3 4})' '{:x "str" :y [1 2] :z #{3 4}}'
run_test_cmd "hash-map odd args" 'timeout 10 ./main -e "(hash-map :a 1 :b)" 2>&1 | head -1' 'error: ArityError'

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
run_test_cmd "into" "$VM -e '(into [] (list 1 2 3))'" "[1 2 3]"
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
run_test_cmd "update" "$VM -e '(update {:a 1} :a inc)'" "{:a 2}"
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

run_test "map builtin" '(doall (map (fn [x] (* x 2)) (list 1 2 3)))' "(2 4 6)"
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
run_test_cmd "into" "$VM -e '(into [] (list 1 2 3))'" "[1 2 3]"
run_test "merge" '(merge {:a 1} {:b 2})' "{:a 1 :b 2}"


echo ""
echo "=== File I/O Tests (spit/slurp) ==="
# spit writes content to a file, returns nil
run_test "spit basic" '(spit "/tmp/clojure_vm_test_spit.txt" "hello world")' "nil"
# slurp reads file contents as string
run_test "slurp basic" '(slurp "/tmp/clojure_vm_test_spit.txt")' '"hello world"'
# spit with integer (converted to string)
run_test "spit integer" '(spit "/tmp/clojure_vm_test_spit2.txt" 42)' "nil"
run_test "slurp integer" '(slurp "/tmp/clojure_vm_test_spit2.txt")' '"42"'
# slurp and str operations
run_test "slurp with str" '(str (slurp "/tmp/clojure_vm_test_spit.txt"))' '"hello world"'
# slurp nonexistent file should error (we test it doesn't crash)
run_test_cmd "slurp nonexistent" 'timeout 10 ./main -e '"'"'(slurp "/tmp/clojure_vm_nonexistent_xyz.txt")'"'"' 2>&1 | head -1' 'error: FileError'

# Clean up temp files
rm -f /tmp/clojure_vm_test_spit.txt /tmp/clojure_vm_test_spit2.txt


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
# Run the hanoi sample and check output (core is auto-loaded now)
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
run_test "get-in missing key" '(get-in {:a 1} [:b])' 'nil'
run_test "get-in deep missing" '(get-in {:a {:b 1}} [:a :c :d])' 'nil'

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
run_test "when-not true" '(when-not true "yes")' 'nil'
run_test "when-not multi body" '(when-not false (+ 1 2))' '3'

# when-some
run_test "when-some value" '(when-some [x 5] (* x 2))' '10'
run_test "when-some nil" '(when-some [x nil] (* x 2))' 'nil'
run_test "when-some string" '(when-some [x "hi"] (str x " there"))' '"hi there"'

# if-let
run_test "if-let truthy" '(if-let [x 5] (* x 2) "nope")' '10'
run_test "if-let nil" '(if-let [x nil] (* x 2) "nope")' '"nope"'
run_test "if-let false" '(if-let [x false] "yes" "no")' '"no"'

echo ""
echo "=== Summary ==="
echo "Total: $TOTAL, Passed: $PASS, Failed: $FAIL"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
