#!/bin/bash
# Sequence Functions: iterate, map, take, partition, reduce, flatten, filter, remove, every?, some, distinct?, nthnext, into, drop
source tests/helpers.sh

echo "=== Sequence Functions ==="
run_test "iterate" "(take 5 (iterate (fn [x] (+ x 1)) 0))" "(0 1 2 3 4)"
run_test "map" "(doall (map (fn [x] (* x 2)) (list 1 2 3)))" "(2 4 6)"
run_test "take" "(take 3 (list 1 2 3 4 5))" "(1 2 3)"

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
run_test "nthnext" "(nthnext (list 1 2 3 4) 2)" "(3 4)"

echo ""
echo "=== Partition ==="
run_test "partition exact" '(doall (partition 2 (list 1 2 3 4)))' '((1 2) (3 4))'
run_test "partition with remainder" '(doall (partition 2 (list 1 2 3 4 5)))' '((1 2) (3 4))'
run_test "partition single" '(doall (partition 1 (list 1 2 3)))' '((1) (2) (3))'
run_test "partition larger than coll" '(doall (partition 5 (list 1 2 3)))' '()'
run_test "partition empty" '(doall (partition 2 (list)))' '()'

echo ""
echo "=== take-nth ==="
run_test "take-nth basic" "(doall (take-nth 2 (list 1 2 3 4 5 6 7)))" "(1 3 5 7)"
run_test "take-nth step 3" "(doall (take-nth 3 (list 1 2 3 4 5 6 7 8 9)))" "(1 4 7)"
run_test "take-nth step 1" "(doall (take-nth 1 (list 1 2 3)))" "(1 2 3)"
run_test "take-nth step > len" "(doall (take-nth 5 (list 1 2 3)))" "(1)"
run_test "take-nth empty" "(doall (take-nth 2 (list)))" "()"

echo ""
echo "=== interleave ==="
run_test "interleave equal" "(doall (interleave (list 1 3 5) (list 2 4 6)))" "(1 2 3 4 5 6)"
run_test "interleave first shorter" "(doall (interleave (list 1 3) (list 2 4 6)))" "(1 2 3 4)"
run_test "interleave second shorter" "(doall (interleave (list 1 3 5) (list 2 4)))" "(1 2 3 4)"
run_test "interleave empty" "(doall (interleave))" "()"
run_test "interleave one empty" "(doall (interleave (list 1) (list)))" "()"

echo ""
echo "=== partition-all ==="
run_test "partition-all exact" "(doall (partition-all 2 (list 1 2 3 4 5 6)))" "((1 2) (3 4) (5 6))"
run_test "partition-all partial" "(doall (partition-all 2 (list 1 2 3 4 5)))" "((1 2) (3 4) (5))"
run_test "partition-all single" "(doall (partition-all 3 (list 1 2 3 4 5)))" "((1 2 3) (4 5))"
run_test "partition-all empty" "(doall (partition-all 2 (list)))" "()"

echo ""
echo "=== partition-by ==="
run_test "partition-by even?" "(doall (partition-by even? (list 1 1 1 2 2 2 3 3)))" "([1 1 1] [2 2 2] [3 3])"
run_test "partition-by identity" "(doall (partition-by identity (list :a :a :b :b :b :c)))" "([:a :a] [:b :b :b] [:c])"
run_test "partition-by empty" "(doall (partition-by even? (list)))" "()"

echo ""
echo "=== frequencies ==="
run_test "frequencies basic" "(frequencies (list 1 1 2 3 3 3))" "{1 2 2 1 3 3}"
run_test "frequencies strings" '(frequencies (list "a" "b" "a" "c" "b" "a"))' '{"a" 3 "b" 2 "c" 1}'
run_test "frequencies empty" "(frequencies (list))" "{}"

# Regression: large range must not cause stack overflow (lazy-seq recursion bug)
# Timeout increased to 30s — + wrapper adds GC pressure (addressed separately)
run_test_cmd "reduce large range (regression)" "timeout 30 $VM -e '(reduce + (range 1 25000))'" "312487500"

echo ""
echo "=== reductions ==="
run_test "reductions with init" "(reductions + 0 (list 1 2 3 4))" "(0 1 3 6 10)"
run_test "reductions no init" "(reductions + (list 1 2 3 4))" "(1 3 6 10)"
run_test "reductions conj" "(reductions conj [] (list 1 2 3))" "([] [1] [1 2] [1 2 3])"
run_test "reductions single" "(reductions + 0 (list 1))" "(0 1)"
run_test "reductions empty" "(reductions + 0 (list))" "(0)"

echo ""
echo "=== map-indexed ==="
run_test "map-indexed basic" "(map-indexed (fn [i x] [i x]) (list \"a\" \"b\" \"c\"))" "([0 \"a\"] [1 \"b\"] [2 \"c\"])"
run_test "map-indexed vector" "(map-indexed (fn [i x] (+ i x)) [10 20 30])" "(10 21 32)"
run_test "map-indexed empty" "(map-indexed (fn [i x] [i x]) (list))" "()"
run_test "map-indexed single" "(map-indexed (fn [i x] [i x]) (list 42))" "([0 42])"

echo ""
echo "=== keep-indexed ==="
run_test "keep-indexed even" "(keep-indexed (fn [i x] (when (even? i) x)) (list 10 20 30 40 50))" "(10 30 50)"
run_test "keep-indexed all" "(keep-indexed (fn [i x] x) (list 1 2 3))" "(1 2 3)"
run_test "keep-indexed none" "(keep-indexed (fn [i x] nil) (list 1 2 3))" "()"
run_test "keep-indexed empty" "(keep-indexed (fn [i x] x) (list))" "()"

echo ""
echo "=== every-pred ==="
run_test "every-pred true" "((every-pred even? pos?) 4)" "true"
run_test "every-pred false odd" "((every-pred even? pos?) 3)" "false"
run_test "every-pred false neg" "((every-pred even? pos?) -2)" "false"
run_test "every-pred single" "((every-pred even?) 4)" "true"
run_test "every-pred single false" "((every-pred even?) 3)" "false"

echo ""
echo "=== some-fn ==="
run_test "some-fn true even" "((some-fn even? zero?) 4)" "true"
run_test "some-fn true zero" "((some-fn even? zero?) 0)" "true"
run_test "some-fn false" "((some-fn even? zero?) 3)" ""
run_test "some-fn single" "((some-fn even?) 4)" "true"

echo ""
echo "=== bounded-count ==="
run_test "bounded-count less than n" "(bounded-count 100 (range 10))" "10"
run_test "bounded-count more than n" "(bounded-count 5 (range 10))" "5"
run_test "bounded-count equal" "(bounded-count 10 (range 10))" "10"
run_test "bounded-count empty" "(bounded-count 5 (list))" "0"

echo ""
echo "=== group-by ==="
run_test "group-by even?" "(group-by even? (list 1 2 3 4 5 6))" "{false [1 3 5] true [2 4 6]}"
run_test "group-by identity" "(group-by identity (list :a :b :a :c :b))" "{:a [:a :a] :b [:b :b] :c [:c]}"
run_test "group-by empty" "(group-by even? (list))" "{}"

echo ""
echo "=== distinct ==="
run_test "distinct basic" "(distinct (list 1 2 1 3 2 4))" "(1 2 3 4)"
run_test "distinct all same" "(distinct (list 1 1 1 1))" "(1)"
run_test "distinct all unique" "(distinct (list 1 2 3 4))" "(1 2 3 4)"
run_test "distinct empty" "(distinct (list))" "()"

echo ""
echo "=== replace ==="
run_test "replace basic" "(replace {1 :a 2 :b} (list 1 2 3 1))" "(:a :b 3 :a)"
run_test "replace all match" "(replace {1 :a 2 :b} (list 1 2))" "(:a :b)"
run_test "replace none match" "(replace {1 :a} (list 2 3 4))" "(2 3 4)"
run_test "replace empty" "(replace {1 :a} (list))" "()"
run_test "replace vector" "(replace {1 :a 2 :b} [1 2 3])" "(:a :b 3)"

echo ""
echo "=== repeatedly ==="
run_test "repeatedly infinite take" "(doall (take 5 (repeatedly (fn [] 1))))" "(1 1 1 1 1)"
run_test "repeatedly with count" "(doall (repeatedly 3 (fn [] 42)))" "(42 42 42)"
run_test "repeatedly zero" "(doall (repeatedly 0 (fn [] 1)))" "()"

echo ""
echo "=== cat ==="
run_test "cat two vecs" "(cat [1 2] [3 4])" "(1 2 3 4)"
run_test "cat three vecs" "(cat [1 2] [3 4] [5 6])" "(1 2 3 4 5 6)"
run_test "cat with nil" "(cat [1] nil [2])" "(1 2)"
run_test "cat empty" "(cat)" "()"

echo ""
echo "=== dedupe ==="
run_test "dedupe basic" "(doall (dedupe [1 1 2 2 3 1 1]))" "(1 2 3 1)"
run_test "dedupe no dups" "(doall (dedupe [1 2 3]))" "(1 2 3)"
run_test "dedupe all same" "(doall (dedupe [1 1 1 1]))" "(1)"
run_test "dedupe single" "(doall (dedupe [1]))" "(1)"
run_test "dedupe empty" "(doall (dedupe []))" "()"

echo ""
echo "=== random-sample ==="
run_test "random-sample 1.0" "(doall (random-sample 1.0 [1 2 3]))" "(1 2 3)"
run_test "random-sample 0.0" "(doall (random-sample 0.0 [1 2 3]))" "()"

echo ""
echo "=== reduced ==="
run_test "reduced wrap" "(reduced 42)" "#reduced(42)"
run_test "reduced? true" "(reduced? (reduced 42))" "true"
run_test "reduced? false" "(reduced? 42)" "false"
run_test "ensure-reduced already" "(ensure-reduced (reduced 42))" "#reduced(42)"
run_test "ensure-reduced not" "(ensure-reduced 42)" "#reduced(42)"
run_test "unreduced reduced" "(unreduced (reduced 42))" "42"
run_test "unreduced not reduced" "(unreduced 42)" "42"
run_test "deref reduced" "(deref (reduced 42))" "42"
run_test "reduce with reduced" "(reduce (fn [acc x] (if (> x 3) (reduced acc) (conj acc x))) [] [1 2 3 4 5 6])" "[1 2 3]"
run_test "reduce reduced early" "(reduce (fn [acc x] (if (= x 2) (reduced acc) (+ acc x))) 0 (list 1 2 3 4))" "1"
