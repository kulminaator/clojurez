;; Collections: conj, pop, last, reverse, range, empty?, not-empty, seq, coll?, sequential?, vector?, map?, next, nthnext
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Collection Tests ----
(check "conj vector" (conj [1 2] 3) '[1 2 3])
(check "pop vector" (pop [1 2 3]) '[1 2])
(check "last vector" (last [1 2 3]) 3)
(check "reverse vector" (reverse [1 2 3]) '[3 2 1])
(check "range" (doall (range 1 4)) '(1 2 3))

;; ---- Collection Predicate Tests ----
(check "empty? list" (empty? (list)) true)
(check "empty? vec" (empty? []) true)
(check "empty? set" (empty? #{}) true)
(check "empty? map" (empty? {}) true)
(check "empty? not empty" (empty? (list 1)) false)
(check "not-empty list" (not-empty (list 1 2)) '(1 2))
(check "not-empty empty" (not-empty (list)) nil)
(check "seq list" (seq (list 1 2)) '(1 2))
(check "seq empty" (seq (list)) nil)
(check "coll?" (coll? (list 1)) true)
(check "coll? not coll" (coll? 42) false)
(check "sequential?" (sequential? (list 1)) true)
(check "sequential? map" (sequential? {:a 1}) false)
(check "vector?" (vector? [1 2]) true)
(check "map?" (map? {:a 1}) true)
(check "next" (next (list 1 2 3)) '(2 3))
(check "next empty" (next (list 1)) nil)

(print-summary)
