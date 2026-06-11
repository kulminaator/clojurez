;; Sequence Functions: iterate, map, take, partition, reduce, flatten, filter,
;; remove, every?, some, distinct?, nthnext, into, drop, take-nth, interleave,
;; partition-all, partition-by, frequencies, reductions, map-indexed,
;; keep-indexed, every-pred, some-fn, bounded-count, group-by, distinct,
;; replace, repeatedly, cat, dedupe, random-sample, reduced
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Sequence Functions ----
(check "iterate" (doall (take 5 (iterate (fn [x] (+ x 1)) 0))) '(0 1 2 3 4))
(check "map" (doall (map (fn [x] (* x 2)) (list 1 2 3))) '(2 4 6))
(check "take" (doall (take 3 (list 1 2 3 4 5))) '(1 2 3))

;; ---- Sequence Operation Tests ----
(check "reduce" (reduce + 0 (list 1 2 3 4)) 10)
(check "reduce no init" (reduce + (list 1 2 3 4)) 10)
(check "into" (into [] (list 1 2 3)) '[1 2 3])
(check "flatten" (flatten (list 1 (list 2 3) 4)) '(1 2 3 4))
(check "filter" (filter (fn [x] (> x 2)) (list 1 2 3 4)) '(3 4))
(check "remove" (remove (fn [x] (> x 2)) (list 1 2 3 4)) '(1 2))
(check "every?" (every? (fn [x] (> x 0)) (list 1 2 3)) true)
(check "some" (some (fn [x] (= x 3)) (list 1 2 3)) true)
(check "distinct?" (distinct? (list 1 2 3)) true)
(check "distinct? not" (distinct? (list 1 2 1)) false)
(check "nthnext" (nthnext (list 1 2 3 4) 2) '(3 4))

;; ---- Partition ----
(check "partition exact" (doall (partition 2 (list 1 2 3 4))) '((1 2) (3 4)))
(check "partition with remainder" (doall (partition 2 (list 1 2 3 4 5))) '((1 2) (3 4)))
(check "partition single" (doall (partition 1 (list 1 2 3))) '((1) (2) (3)))
(check "partition larger than coll" (doall (partition 5 (list 1 2 3))) '())
(check "partition empty" (doall (partition 2 (list))) '())

;; ---- take-nth ----
(check "take-nth basic" (doall (take-nth 2 (list 1 2 3 4 5 6 7))) '(1 3 5 7))
(check "take-nth step 3" (doall (take-nth 3 (list 1 2 3 4 5 6 7 8 9))) '(1 4 7))
(check "take-nth step 1" (doall (take-nth 1 (list 1 2 3))) '(1 2 3))
(check "take-nth step > len" (doall (take-nth 5 (list 1 2 3))) '(1))
(check "take-nth empty" (doall (take-nth 2 (list))) '())

;; ---- interleave ----
(check "interleave equal" (doall (interleave (list 1 3 5) (list 2 4 6))) '(1 2 3 4 5 6))
(check "interleave first shorter" (doall (interleave (list 1 3) (list 2 4 6))) '(1 2 3 4))
(check "interleave second shorter" (doall (interleave (list 1 3 5) (list 2 4))) '(1 2 3 4))
(check "interleave empty" (doall (interleave)) '())
(check "interleave one empty" (doall (interleave (list 1) (list))) '())

;; ---- partition-all ----
(check "partition-all exact" (doall (partition-all 2 (list 1 2 3 4 5 6))) '((1 2) (3 4) (5 6)))
(check "partition-all partial" (doall (partition-all 2 (list 1 2 3 4 5))) '((1 2) (3 4) (5)))
(check "partition-all single" (doall (partition-all 3 (list 1 2 3 4 5))) '((1 2 3) (4 5)))
(check "partition-all empty" (doall (partition-all 2 (list))) '())

;; ---- partition-by ----
(check "partition-by even?" (doall (partition-by even? (list 1 1 1 2 2 2 3 3))) '([1 1 1] [2 2 2] [3 3]))
(check "partition-by identity" (doall (partition-by identity (list :a :a :b :b :b :c))) '([:a :a] [:b :b :b] [:c]))
(check "partition-by empty" (doall (partition-by even? (list))) '())

;; ---- frequencies ----
(check "frequencies basic" (frequencies (list 1 1 2 3 3 3)) '{1 2 2 1 3 3})
(check "frequencies strings" (frequencies (list "a" "b" "a" "c" "b" "a")) '{"a" 3 "b" 2 "c" 1})
(check "frequencies empty" (frequencies (list)) '{})

;; ---- reduce regression ----
(check "reduce large range (regression)" (reduce + (range 1 25000)) 312487500)

;; ---- reductions ----
(check "reductions with init" (reductions + 0 (list 1 2 3 4)) '(0 1 3 6 10))
(check "reductions no init" (reductions + (list 1 2 3 4)) '(1 3 6 10))
(check "reductions conj" (reductions conj [] (list 1 2 3)) '([] [1] [1 2] [1 2 3]))
(check "reductions single" (reductions + 0 (list 1)) '(0 1))
(check "reductions empty" (reductions + 0 (list)) '(0))

;; ---- map-indexed ----
(check "map-indexed basic" (map-indexed (fn [i x] [i x]) (list "a" "b" "c")) '([0 "a"] [1 "b"] [2 "c"]))
(check "map-indexed vector" (map-indexed (fn [i x] (+ i x)) [10 20 30]) '(10 21 32))
(check "map-indexed empty" (map-indexed (fn [i x] [i x]) (list)) '())
(check "map-indexed single" (map-indexed (fn [i x] [i x]) (list 42)) '([0 42]))

;; ---- keep-indexed ----
(check "keep-indexed even" (keep-indexed (fn [i x] (when (even? i) x)) (list 10 20 30 40 50)) '(10 30 50))
(check "keep-indexed all" (keep-indexed (fn [i x] x) (list 1 2 3)) '(1 2 3))
(check "keep-indexed none" (keep-indexed (fn [i x] nil) (list 1 2 3)) '())
(check "keep-indexed empty" (keep-indexed (fn [i x] x) (list)) '())

;; ---- every-pred ----
(check "every-pred true" ((every-pred even? pos?) 4) true)
(check "every-pred false odd" ((every-pred even? pos?) 3) false)
(check "every-pred false neg" ((every-pred even? pos?) -2) false)
(check "every-pred single" ((every-pred even?) 4) true)
(check "every-pred single false" ((every-pred even?) 3) false)

;; ---- some-fn ----
(check "some-fn true even" ((some-fn even? zero?) 4) true)
(check "some-fn true zero" ((some-fn even? zero?) 0) true)
(check "some-fn false" ((some-fn even? zero?) 3) nil)
(check "some-fn single" ((some-fn even?) 4) true)

;; ---- bounded-count ----
(check "bounded-count less than n" (bounded-count 100 (range 10)) 10)
(check "bounded-count more than n" (bounded-count 5 (range 10)) 5)
(check "bounded-count equal" (bounded-count 10 (range 10)) 10)
(check "bounded-count empty" (bounded-count 5 (list)) 0)

;; ---- group-by ----
(check "group-by even?" (group-by even? (list 1 2 3 4 5 6)) '{false [1 3 5] true [2 4 6]})
(check "group-by identity" (group-by identity (list :a :b :a :c :b)) '{:a [:a :a] :b [:b :b] :c [:c]})
(check "group-by empty" (group-by even? (list)) '{})

;; ---- distinct ----
(check "distinct basic" (distinct (list 1 2 1 3 2 4)) '(1 2 3 4))
(check "distinct all same" (distinct (list 1 1 1 1)) '(1))
(check "distinct all unique" (distinct (list 1 2 3 4)) '(1 2 3 4))
(check "distinct empty" (distinct (list)) '())

;; ---- replace ----
(check "replace basic" (replace {1 :a 2 :b} (list 1 2 3 1)) '(:a :b 3 :a))
(check "replace all match" (replace {1 :a 2 :b} (list 1 2)) '(:a :b))
(check "replace none match" (replace {1 :a} (list 2 3 4)) '(2 3 4))
(check "replace empty" (replace {1 :a} (list)) '())
(check "replace vector" (replace {1 :a 2 :b} [1 2 3]) '(:a :b 3))

;; ---- repeatedly ----
(check "repeatedly infinite take" (doall (take 5 (repeatedly (fn [] 1)))) '(1 1 1 1 1))
(check "repeatedly with count" (doall (repeatedly 3 (fn [] 42))) '(42 42 42))
(check "repeatedly zero" (doall (repeatedly 0 (fn [] 1))) '())

;; ---- cat ----
(check "cat two vecs" (cat [1 2] [3 4]) '(1 2 3 4))
(check "cat three vecs" (cat [1 2] [3 4] [5 6]) '(1 2 3 4 5 6))
(check "cat with nil" (cat [1] nil [2]) '(1 2))
(check "cat empty" (cat) '())

;; ---- dedupe ----
(check "dedupe basic" (doall (dedupe [1 1 2 2 3 1 1])) '(1 2 3 1))
(check "dedupe no dups" (doall (dedupe [1 2 3])) '(1 2 3))
(check "dedupe all same" (doall (dedupe [1 1 1 1])) '(1))
(check "dedupe single" (doall (dedupe [1])) '(1))
(check "dedupe empty" (doall (dedupe [])) '())

;; ---- random-sample ----
(check "random-sample 1.0" (doall (random-sample 1.0 [1 2 3])) '(1 2 3))
(check "random-sample 0.0" (doall (random-sample 0.0 [1 2 3])) '())

;; ---- reduced ----
(check "reduced wrap" (reduced? (reduced 42)) true)
(check "reduced? false" (reduced? 42) false)
(check "ensure-reduced already" (reduced? (ensure-reduced (reduced 42))) true)
(check "ensure-reduced not" (reduced? (ensure-reduced 42)) true)
(check "unreduced reduced" (unreduced (reduced 42)) 42)
(check "unreduced not reduced" (unreduced 42) 42)
(check "deref reduced" (deref (reduced 42)) 42)
(check "reduce with reduced" (reduce (fn [acc x] (if (> x 3) (reduced acc) (conj acc x))) [] [1 2 3 4 5 6]) '[1 2 3])
(check "reduce reduced early" (reduce (fn [acc x] (if (= x 2) (reduced acc) (+ acc x))) 0 (list 1 2 3 4)) 1)

(print-summary)
