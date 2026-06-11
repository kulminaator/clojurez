;; New features: rand, rand-int, rand-nth, shuffle, hash-set,
;; drop-last, take-last, drop-while, cycle, split-at, split-with,
;; repeat, replicate, comparator, sort, sort-by
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Random Functions ----
(check "rand returns float in [0,1)" (let [r (rand)] (and (>= r 0.0) (< r 1.0))) true)
(check "rand-int returns int in [0,n)" (let [r (rand-int 100)] (and (>= r 0) (< r 100))) true)
(check "rand-nth picks from coll" (let [r (rand-nth [10 20 30])] (or (= r 10) (= r 20) (= r 30))) true)

;; ---- Shuffle ----
(check "shuffle produces permutation" (let [s (shuffle [1 2 3])] (= (set s) #{1 2 3})) true)
(check "shuffle empty" (shuffle []) '[])

;; ---- hash-set ----
(check "hash-set creates set" (hash-set 1 2 3) '#{1 2 3})
(check "hash-set empty" (hash-set) '#{})
(check "hash-set deduplicates" (hash-set 1 1 2) '#{1 2})

;; ---- drop-last ----
(check "drop-last 2" (doall (drop-last 2 [1 2 3 4 5])) '(1 2 3))
(check "drop-last default" (doall (drop-last [1 2 3 4 5])) '(1 2 3 4))
(check "drop-last 0" (doall (drop-last 0 [1 2 3])) '(1 2 3))

;; ---- take-last ----
(check "take-last 2" (take-last 2 [1 2 3 4 5]) '(4 5))
(check "take-last all" (take-last 10 [1 2 3]) '(1 2 3))

;; ---- drop-while ----
(check "drop-while basic" (doall (drop-while (fn [x] (< x 3)) [1 2 3 4])) '(3 4))
(check "drop-while all" (doall (drop-while (fn [x] true) [1 2 3])) '())
(check "drop-while none" (doall (drop-while (fn [x] false) [1 2 3])) '(1 2 3))

;; ---- cycle ----
(check "cycle basic" (doall (take 5 (cycle [1 2]))) '(1 2 1 2 1))
(check "cycle single" (doall (take 3 (cycle [42]))) '(42 42 42))
(check "cycle empty" (doall (take 3 (cycle []))) '())

;; ---- split-at ----
(check "split-at basic first" (doall (first (split-at 2 [1 2 3 4 5]))) '(1 2))
(check "split-at basic rest" (second (split-at 2 [1 2 3 4 5])) '[3 4 5])

;; ---- split-with ----
(check "split-with basic first" (doall (first (split-with (fn [x] (< x 3)) [1 2 3 4]))) '(1 2))
(check "split-with basic rest" (doall (second (split-with (fn [x] (< x 3)) [1 2 3 4]))) '(3 4))

;; ---- repeat ----
(check "repeat n x" (doall (repeat 3 :x)) '(:x :x :x))
(check "repeat 0 x" (doall (repeat 0 :x)) '())
(check "repeat infinite take" (doall (take 3 (repeat :a))) '(:a :a :a))

;; ---- replicate ----
(check "replicate basic" (doall (replicate 3 :x)) '(:x :x :x))

;; ---- comparator ----
(check "comparator less" ((comparator <) 1 2) -1)
(check "comparator greater" ((comparator <) 2 1) 1)
(check "comparator equal" ((comparator <) 1 1) 0)

;; ---- sort ----
(check "sort ascending" (sort [3 1 4 1 5]) '(1 1 3 4 5))
(check "sort strings" (sort ["b" "a" "c"]) '("a" "b" "c"))
(check "sort empty" (sort []) '())

;; ---- sort-by ----
(check "sort-by count" (sort-by count ["bb" "a" "ccc"]) '("a" "bb" "ccc"))
(check "sort-by neg" (sort-by (fn [x] (* -1 x)) [1 2 3]) '(3 2 1))

(print-summary)
