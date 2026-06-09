#!/bin/bash
# Core Library: update, if-not, drop, apply, comp, partial, fnil, juxt, atom, identity, even?, odd?, zero?, pos?, neg?, abs, max, min, cons, second, third
source tests/helpers.sh

echo "=== Core Library Tests ==="
run_test_cmd "update" "$VM -e '(update {:a 1} :a inc)'" "{:a 2}"
run_test "if-not false" '(if-not false :yes :no)' ":yes"
run_test "if-not true" '(if-not true :yes :no)' ":no"
run_test "if-not nil 2arg" '(if-not nil :yes)' ":yes"
run_test "if-not true 2arg" '(if-not true :yes)' ""

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

echo ""
echo "=== Mod Tests ==="
run_test "mod positive" '(mod 7 3)' '1'
run_test "mod neg dividend" '(mod -7 3)' '2'
run_test "mod neg divisor" '(mod 7 -3)' '-2'
run_test "mod both neg" '(mod -7 -3)' '-1'
run_test "mod zero" '(mod 0 5)' '0'
run_test "mod exact" '(mod 6 3)' '0'
run_test "mod float" '(mod 7.5 3.0)' '1.5'
run_test "mod float neg" '(mod -7.5 3.0)' '1.5'

echo ""
echo "=== Quot Tests ==="
run_test "quot positive" '(quot 7 3)' '2'
run_test "quot neg dividend" '(quot -7 3)' '-2'
run_test "quot neg divisor" '(quot 7 -3)' '-2'
run_test "quot both neg" '(quot -7 -3)' '2'
run_test "quot zero" '(quot 0 5)' '0'
run_test "quot exact" '(quot 6 3)' '2'

echo ""
echo "=== Compare Tests ==="
run_test "compare less" '(compare 1 2)' '-1'
run_test "compare greater" '(compare 2 1)' '1'
run_test "compare equal" '(compare 1 1)' '0'
run_test "compare int float" '(compare 1 1.0)' '0'
run_test "compare string lt" '(compare "a" "b")' '-1'
run_test "compare string gt" '(compare "b" "a")' '1'
run_test "compare string eq" '(compare "a" "a")' '0'
run_test "compare nil less" '(compare nil 1)' '-1'
run_test "compare nil greater" '(compare 1 nil)' '1'
run_test "compare nil nil" '(compare nil nil)' '0'

echo ""
echo "=== Double Eq Tests ==="
run_test "== int float equal" '(== 1 1.0)' 'true'
run_test "== int int equal" '(== 1 1)' 'true'
run_test "== int int not equal" '(== 1 2)' 'false'
run_test "== float float equal" '(== 1.0 1.0)' 'true'
run_test "== float float not equal" '(== 1.0 2.0)' 'false'
run_test "== multiple equal" '(== 1 1.0 1)' 'true'
run_test "== multiple not equal" '(== 1 2 3)' 'false'
run_test "== zero args" '(==)' 'true'
run_test "== one arg" '(== 5)' 'true'

echo ""
echo "=== Rationalize Tests ==="
run_test "rationalize int" '(rationalize 5)' '5'
run_test "rationalize 1.0" '(rationalize 1.0)' '1'
run_test "rationalize 1.5" '(rationalize 1.5)' '3/2'
run_test "rationalize 0.1" '(rationalize 0.1)' '1/10'
run_test "rationalize 0.25" '(rationalize 0.25)' '1/4'
run_test "rationalize 2.0" '(rationalize 2.0)' '2'
run_test "rationalize 0.33" '(rationalize 0.33)' '33/100'
run_test "rationalize neg" '(rationalize -1.5)' '-3/2'

echo ""
echo "=== Zig-Delegated Function Wrapper Tests ==="

# compare
run_test "compare less" '(compare 1 2)' '-1'
run_test "compare greater" '(compare 2 1)' '1'
run_test "compare equal" '(compare 1 1)' '0'
run_test "compare strings" '(compare "a" "b")' '-1'
run_test "zig.core/compare" '(zig.core/compare 3 2)' '1'

# identical?
run_test "identical? same int" '(identical? 1 1)' 'true'
run_test "identical? same string" '(identical? "a" "a")' 'true'
run_test "zig.core/identical?" '(zig.core/identical? 42 42)' 'true'

# get (already tested via other tests, add wrapper-specific tests)
run_test "get wrapper" '(get {:x 10} :x)' '10'
run_test "get wrapper not-found" '(get {:x 10} :y)' ''
run_test "get wrapper default" '(get {:x 10} :y "missing")' '"missing"'
run_test "zig.core/get" '(zig.core/get {:a 1} :a)' '1'

# conj
run_test "conj vector" '(conj [1 2] 3)' '[1 2 3]'
run_test "conj set" '(conj #{1 2} 3)' '#{1 2 3}'
run_test "conj map" '(conj {:a 1} [:b 2])' '{:a 1 :b 2}'
run_test "zig.core/conj" '(zig.core/conj [1] 2)' '[1 2]'

# str
run_test "str empty" '(str)' '""'
run_test "str one arg" '(str 42)' '"42"'
run_test "str multi" '(str "hello" " " "world")' '"hello world"'
run_test "zig.core/str" '(zig.core/str "a" "b")' '"ab"'

# nano-time
run_test "nano-time positive" '(> (nano-time) 0)' 'true'
run_test "nano-time integer" '(integer? (nano-time))' 'true'
run_test "zig.core/nano-time" '(> (zig.core/nano-time) 0)' 'true'

# rand-int
run_test "rand-int range" '(and (>= (rand-int 100) 0) (< (rand-int 100) 100))' 'true'
run_test "rand-int 1" '(= (rand-int 1) 0)' 'true'
run_test "zig.core/rand-int" '(and (>= (zig.core/rand-int 50) 0) (< (zig.core/rand-int 50) 50))' 'true'

# gensym
run_test "gensym symbol" '(symbol? (gensym))' 'true'
run_test "gensym with prefix" '(symbol? (gensym "tmp"))' 'true'
run_test "gensym unique" '(not= (gensym) (gensym))' 'true'
run_test "zig.core/gensym" '(symbol? (zig.core/gensym "x"))' 'true'

# distinct
run_test "distinct basic" '(distinct [1 2 1 3 2 4])' '(1 2 3 4)'
run_test "distinct all same" '(distinct [5 5 5])' '(5)'
run_test "distinct empty" '(distinct [])' '()'
run_test "zig.core/distinct" '(zig.core/distinct [1 1 2])' '(1 2)'

# get inside lazy-seq (regression test for qualified symbol resolution)
run_test "get in for" '(doall (for [k [:a :b]] (get {:a 1 :b 2} k)))' '(1 2)'
run_test "get in map" '(doall (map (fn [m] (get m :x)) (list {:x 1} {:x 2})))' '(1 2)'

# reduced
run_test "reduced wraps" '(reduced? (reduced 42))' 'true'
run_test "reduced not wraps" '(reduced? 42)' 'false'
run_test "zig.core/reduced" '(zig.core/reduced? (zig.core/reduced 5))' 'true'

# keys
run_test "keys basic" '(keys {:a 1 :b 2})' '(:a :b)'
run_test "keys empty" "(keys {})" "()"
run_test "zig.core/keys" '(zig.core/keys {:x 1})' '(:x)'

# vals
run_test "vals basic" '(vals {:a 1 :b 2})' '(1 2)'
run_test "vals empty" "(vals {})" "()"
run_test "zig.core/vals" '(zig.core/vals {:x 1})' '(1)'

# rand
run_test "rand range" '(and (>= (rand) 0) (< (rand) 1))' 'true'
run_test "rand with n" '(and (>= (rand 100) 0) (< (rand 100) 100))' 'true'
run_test "zig.core/rand" '(and (>= (zig.core/rand) 0) (< (zig.core/rand) 1))' 'true'

# rand inside lazy-seq (regression for qualified symbol resolution)
run_test "rand in map" '(every? (fn [x] (and (>= x 0) (< x 1))) (doall (map (fn [_] (rand)) (list 1 2 3))))' 'true'

# pop
run_test "pop vector" '(pop [1 2 3])' '[1 2]'
run_test "pop list" '(pop (list 1 2 3))' '(1 2)'
run_test "zig.core/pop" '(zig.core/pop [1 2])' '[1]'

# peek
run_test "peek vector" '(peek [1 2 3])' '3'
run_test "peek list" '(peek (list 1 2 3))' '3'
run_test "zig.core/peek" '(zig.core/peek [1 2])' '2'

# reverse
run_test "reverse vector" '(reverse [1 2 3])' '[3 2 1]'
run_test "reverse list" '(reverse (list 1 2 3))' '(3 2 1)'
run_test "zig.core/reverse" '(zig.core/reverse [1 2])' '[2 1]'

# set
run_test "set from list" '(set (list 1 2 1 3))' '#{1 2 3}'
run_test "set from vector" '(set [1 2 3])' '#{1 2 3}'
run_test "set from set" '(set #{1 2})' '#{1 2}'
run_test "zig.core/set" '(zig.core/set [1 2 1])' '#{1 2}'

# disj
run_test "disj one" '(disj #{1 2 3} 2)' '#{1 3}'
run_test "disj multiple" '(disj #{1 2 3 4} 2 3)' '#{1 4}'
run_test "zig.core/disj" '(zig.core/disj #{1 2} 1)' '#{2}'

# assoc
run_test "assoc basic" '(assoc {:a 1} :b 2)' '{:a 1 :b 2}'
run_test "assoc multi" '(assoc {:a 1} :b 2 :c 3)' '{:a 1 :b 2 :c 3}'
run_test "assoc empty" '(assoc {} :x 1)' '{:x 1}'
run_test "zig.core/assoc" '(zig.core/assoc {:a 1} :b 2)' '{:a 1 :b 2}'

# merge
run_test "merge two" '(merge {:a 1} {:b 2})' '{:a 1 :b 2}'
run_test "merge override" '(merge {:a 1} {:a 2})' '{:a 2}'
run_test "merge empty" '(merge {} {:a 1})' '{:a 1}'
run_test "zig.core/merge" '(zig.core/merge {:a 1} {:b 2})' '{:a 1 :b 2}'

# hash-map
run_test "hash-map basic" '(hash-map :a 1 :b 2)' '{:a 1 :b 2}'
run_test "hash-map empty" '(hash-map)' '{}'
run_test "zig.core/hash-map" '(zig.core/hash-map :x 1)' '{:x 1}'

# dissoc
run_test "dissoc one" '(dissoc {:a 1 :b 2} :a)' '{:b 2}'
run_test "dissoc multi" '(dissoc {:a 1 :b 2 :c 3} :a :b)' '{:c 3}'
run_test "zig.core/dissoc" '(zig.core/dissoc {:a 1 :b 2} :a)' '{:b 2}'

# contains?
run_test "contains? map true" '(contains? {:a 1} :a)' 'true'
run_test "contains? map false" '(contains? {:a 1} :b)' 'false'
run_test "zig.core/contains?" '(zig.core/contains? {:a 1} :a)' 'true'

# last
run_test "last vector" '(last [1 2 3])' '3'
run_test "last list" '(last (list 1 2 3))' '3'
run_test "zig.core/last" '(zig.core/last [1 2 3])' '3'

# range
run_test "range one arg" '(range 5)' '(0 1 2 3 4)'
run_test "range two args" '(range 2 5)' '(2 3 4)'
run_test "range three args" '(range 0 10 3)' '(0 3 6 9)'
run_test "zig.core/range" '(zig.core/range 3)' '(0 1 2)'

# replace
run_test "replace basic" '(replace {:a :x} (list :a :b :a))' '(:x :b :x)'
run_test "replace no match" '(replace {:a :x} (list :b :c))' '(:b :c)'
run_test "zig.core/replace" '(zig.core/replace {:a :x} (list :a))' '(:x)'

# group-by
run_test "group-by even" '(group-by even? [1 2 3 4])' '{false [1 3] true [2 4]}'
run_test "zig.core/group-by" '(zig.core/group-by even? [1 2])' '{false [1] true [2]}'

# bounded-count
run_test "bounded-count under" '(bounded-count 10 [1 2 3])' '3'
run_test "bounded-count over" '(bounded-count 2 [1 2 3 4])' '2'
run_test "zig.core/bounded-count" '(zig.core/bounded-count 5 [1 2])' '2'

# assoc inside lazy-seq (regression for qualified symbol resolution)
run_test "assoc in map" '(get (first (doall (map (fn [m] (assoc m :x 99)) (list {:a 1} {:b 2})))) :x)' '99'

# rem
run_test "rem positive" '(rem 7 3)' '1'
run_test "rem negative" '(rem -7 3)' '-1'
run_test "zig.core/rem" '(zig.core/rem 7 3)' '1'

# mod
run_test "mod positive" '(mod 7 3)' '1'
run_test "mod negative" '(mod -7 3)' '2'
run_test "zig.core/mod" '(zig.core/mod 7 3)' '1'

# quot
run_test "quot positive" '(quot 7 3)' '2'
run_test "quot negative" '(quot -7 3)' '-2'
run_test "zig.core/quot" '(zig.core/quot 7 3)' '2'

# nil?
run_test "nil? nil" '(nil? nil)' 'true'
run_test "nil? not nil" '(nil? 42)' 'false'
run_test "zig.core/nil?" '(zig.core/nil? nil)' 'true'

# number?
run_test "number? int" '(number? 42)' 'true'
run_test "number? float" '(number? 3.14)' 'true'
run_test "number? string" '(number? "x")' 'false'
run_test "zig.core/number?" '(zig.core/number? 1)' 'true'

# string?
run_test "string? string" '(string? "hello")' 'true'
run_test "string? int" '(string? 42)' 'false'
run_test "zig.core/string?" '(zig.core/string? "x")' 'true'

# utf8-valid?
run_test "utf8-valid? valid" '(utf8-valid? "hello")' 'true'
run_test "zig.core/utf8-valid?" '(zig.core/utf8-valid? "world")' 'true'

# count
run_test "count vector" '(count [1 2 3])' '3'
run_test "count list" '(count (list 1 2))' '2'
run_test "count string" '(count "abc")' '3'
run_test "zig.core/count" '(zig.core/count [1 2])' '2'

# first
run_test "first vector" '(first [1 2 3])' '1'
run_test "first list" '(first (list 1 2 3))' '1'
run_test "first empty" "(first [])" ''
run_test "zig.core/first" '(zig.core/first [1 2 3])' '1'

# set?
run_test "set? set" '(set? #{1 2})' 'true'
run_test "set? vector" '(set? [1 2])' 'false'
run_test "zig.core/set?" '(zig.core/set? #{1})' 'true'

# count inside lazy-seq (regression for qualified symbol resolution)
run_test "count in map" '(doall (map (fn [x] (count x)) (list [1 2] [1 2 3])))' '(2 3)'

# rest
run_test "rest vector" '(rest [1 2 3])' '(2 3)'
run_test "rest list" '(rest (list 1 2 3))' '(2 3)'
run_test "rest empty" "(rest [])" "()"
run_test "zig.core/rest" '(zig.core/rest [1 2 3])' '(2 3)'

# nth
run_test "nth vector" '(nth [1 2 3] 1)' '2'
run_test "nth list" '(nth (list 1 2 3) 0)' '1'
run_test "nth out of bounds" "(nth [1 2] 10)" ''
run_test "nth string" "(nth \"abc\" 1)" "\"b\""
run_test "zig.core/nth" '(zig.core/nth [1 2 3] 2)' '3'

# list
run_test "list basic" '(list 1 2 3)' '(1 2 3)'
run_test "list empty" '(list)' '()'
run_test "zig.core/list" '(zig.core/list 1 2)' '(1 2)'

# vec
run_test "vec basic" '(vec 1 2 3)' '[1 2 3]'
run_test "vec empty" '(vec)' '[]'
run_test "vec from list" '(vec (list 1 2 3))' '[1 2 3]'
run_test "zig.core/vec" '(zig.core/vec 1 2)' '[1 2]'

# concat
run_test "concat two" '(concat [1 2] [3 4])' '(1 2 3 4)'
run_test "concat three" '(concat [1] [2] [3])' '(1 2 3)'
run_test "zig.core/concat" '(zig.core/concat [1] [2])' '(1 2)'

# seq
run_test "seq vector" '(seq [1 2 3])' '[1 2 3]'
run_test "seq empty" "(seq [])" ''
run_test "zig.core/seq" '(zig.core/seq [1])' '[1]'

# print / println (use run_test_cmd for stdout capture)
run_test_cmd "print basic" "$VM -e '(print \"hello\")'" "hello"
run_test_cmd "println basic" "$VM -e '(println \"hello\")'" "hello"
run_test_cmd "zig.core/print" "$VM -e '(zig.core/print 1 2 3)'" "123"
run_test_cmd "zig.core/println" "$VM -e '(zig.core/println 1 2 3)'" "123"

# atom
run_test "atom creates" '(deref (atom 42))' '42'
run_test "zig.core/atom" '(deref (zig.core/atom 1))' '1'

# bit-and
run_test "bit-and basic" '(bit-and 15 8)' '8'
run_test "bit-and multi" '(bit-and 15 8 3)' '0'
run_test "zig.core/bit-and" '(zig.core/bit-and 15 8)' '8'

# rest inside lazy-seq (regression for qualified symbol resolution)
run_test "rest in map" '(doall (map rest (list [1 2] [3 4])))' '((2) (4))'

# bit-or
run_test "bit-or basic" '(bit-or 8 2)' '10'
run_test "bit-or multi" '(bit-or 1 2 4)' '7'
run_test "zig.core/bit-or" '(zig.core/bit-or 8 2)' '10'

# spit / slurp
run_test_cmd "spit and slurp" "$VM -e '(spit \"/tmp/clj_test.txt\" \"hello\") (slurp \"/tmp/clj_test.txt\")'" '"hello"'
run_test_cmd "zig.core/spit slurp" "$VM -e '(zig.core/spit \"/tmp/clj_test2.txt\" \"world\") (zig.core/slurp \"/tmp/clj_test2.txt\")'" '"world"'

# swap!
run_test "swap! inc" '(do (def a (atom 10)) (swap! a inc) (deref a))' '11'
run_test "swap! with fn" '(do (def a (atom 5)) (swap! a (fn [x] (* x 3))) (deref a))' '15'
run_test "zig.core/swap!" '(do (def a (atom 1)) (zig.core/swap! a inc) (deref a))' '2'

# reset!
run_test "reset! basic" '(do (def a (atom 10)) (reset! a 99) (deref a))' '99'
run_test "zig.core/reset!" '(do (def a (atom 1)) (zig.core/reset! a 42) (deref a))' '42'

# deref
run_test "deref atom" '(deref (atom 42))' '42'
run_test "zig.core/deref" '(zig.core/deref (atom 99))' '99'

# list?
run_test "list? list" '(list? (list 1 2))' 'true'
run_test "list? vector" '(list? [1 2])' 'false'
run_test "zig.core/list?" '(zig.core/list? (list 1))' 'true'

# vector?
run_test "vector? vector" '(vector? [1 2])' 'true'
run_test "vector? list" '(vector? (list 1 2))' 'false'
run_test "zig.core/vector?" '(zig.core/vector? [1])' 'true'

# map?
run_test "map? map" '(map? {:a 1})' 'true'
run_test "map? vector" '(map? [1 2])' 'false'
run_test "zig.core/map?" '(zig.core/map? {:x 1})' 'true'

# empty?
run_test "empty? empty vector" '(empty? [])' 'true'
run_test "empty? non-empty" '(empty? [1])' 'false'
run_test "empty? empty list" '(empty? ())' 'true'
run_test "empty? nil" '(empty? nil)' 'true'
run_test "zig.core/empty?" '(zig.core/empty? [])' 'true'

# empty? inside lazy-seq (regression for qualified symbol resolution)
run_test "empty? in map" '(doall (map empty? (list [] [1] () (list 1))))' '(true false true false)'
