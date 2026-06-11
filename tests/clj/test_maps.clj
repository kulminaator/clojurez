;; Maps: literals, get, assoc, keys, vals, dissoc, merge, contains?, hash-map
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Map Tests ----
(check "map literal" {:a 1 :b 2} '{:a 1 :b 2})
(check "get from map" (get {:a 1 :b 2} :a) 1)
(check "get missing key" (get {:a 1} :b) nil)
(check "assoc new key" (assoc {:a 1} :b 2) '{:a 1 :b 2})
(check "assoc multiple" (assoc {:a 1} :b 2 :c 3) '{:a 1 :b 2 :c 3})

;; ---- Map Enhancement Tests ----
(check "keys" (keys {:a 1 :b 2}) '(:a :b))
(check "vals" (vals {:a 1 :b 2}) '(1 2))
(check "dissoc" (dissoc {:a 1 :b 2} :a) '{:b 2})
(check "merge" (merge {:a 1} {:b 2}) '{:a 1 :b 2})
(check "merge override" (merge {:a 1} {:a 2}) '{:a 2})
(check "contains? map" (contains? {:a 1} :a) true)
(check "contains? map missing" (contains? {:a 1} :b) false)
(check "contains? set" (contains? #{1 2 3} 2) true)
(check "map as fn" ({:a 1 :b 2} :a) 1)
(check "map as fn not found" ({:a 1} :b) nil)
(check "map as fn not-found" ({:a 1} :b :default) ':default)
(check "count map" (count {:a 1 :b 2}) 2)

;; hash-map tests
(check "hash-map empty" (hash-map) '{})
(check "hash-map basic" (hash-map :a 1 :b 2) '{:a 1 :b 2})
(check "hash-map string keys" (hash-map "hello" "world" 42 true) '{"hello" "world" 42 true})
(check "hash-map duplicate key" (hash-map :a 1 :a 2) '{:a 2})
(check "hash-map mixed types" (hash-map :x "str" :y [1 2] :z #{3 4}) '{:x "str" :y [1 2] :z #{3 4}})

;; assoc on nil
(check "assoc nil single kv" (assoc nil :a 1) '{:a 1})
(check "assoc nil multiple kvs" (assoc nil :a 1 :b 2) '{:a 1 :b 2})
(check "assoc nil then assoc" (assoc (assoc nil :a 1) :b 2) '{:a 1 :b 2})

(print-summary)
