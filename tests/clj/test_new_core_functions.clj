;; New Core Functions: fn?, keyword, mapcat, key, val, doall, into-array,
;; trampoline, iterate, symbol?, keyword?, true?, false?, queue?, coll?,
;; sequential?, not-empty, int?, integer?, double?, float?, NaN?, infinite?,
;; type conversions, bitwise ops, byte, short, bigdec, if-not, ensure-reduced,
;; unreduced, next, nthnext, map, mapcat, reduce, filter, remove, flatten,
;; take, drop, every?, some, distinct?, not, reductions, map-indexed,
;; keep-indexed, comp, fnil, juxt, partial, trampoline, sort, sort-by, cons,
;; cycle, =, !=, not=, <, >, <=, >=, +, -, *, /, numerator, denominator,
;; num, denom, rational, boolean?, find, filterv, mapv, keepv, reducev,
;; completing, memoize, def string regression, namespace resolution
(load-file "tests/clj/clj_test_helper.clj")

;; fn?
(check "fn? builtin" (fn? +) true)
(check "fn? user fn" (fn? (fn [] 1)) true)
(check "fn? not fn" (fn? 42) false)

;; keyword
(check "keyword from string" (keyword "foo") ':foo)
(check "keyword from symbol" (keyword 'bar) ':bar)
(check "keyword from keyword" (keyword :baz) ':baz)
(check "keyword namespaced" (keyword "ns" "name") ':ns/name)

;; mapcat
(check "mapcat" (doall (mapcat (fn [x] (list x (* x x))) (list 1 2 3))) '(1 1 2 4 3 9))

;; key / val
(check "key from entry" (key {:key :a :val 1}) ':a)
(check "val from entry" (val {:key :a :val 1}) 1)

;; doall
(check "doall" (doall (list 1 2 3)) '(1 2 3))

;; into-array
(check "into-array" (into-array (list 1 2 3)) '[1 2 3])

;; trampoline
(check "trampoline simple" (trampoline (fn [] 42)) 42)
(check "trampoline nested" (trampoline (fn [] (fn [] (fn [] 42)))) 42)
(check "trampoline mutual recursion" (do (defn even-tr [n] (if (zero? n) true (fn [] (odd-tr (- n 1))))) (defn odd-tr [n] (if (zero? n) false (fn [] (even-tr (- n 1))))) (trampoline even-tr 10)) true)

;; iterate
(check "iterate builtin" (doall (take 5 (iterate inc 0))) '(0 1 2 3 4))

;; symbol?
(check "symbol? symbol" (symbol? 'foo) true)
(check "symbol? not symbol" (symbol? 42) false)
(check "symbol? keyword" (symbol? :foo) false)

;; keyword?
(check "keyword? keyword" (keyword? :foo) true)
(check "keyword? not keyword" (keyword? 'foo) false)
(check "keyword? namespaced" (keyword? :ns/name) true)

;; true?
(check "true? true" (true? true) true)
(check "true? false" (true? false) false)
(check "true? nil" (true? nil) false)
(check "true? 1" (true? 1) false)

;; false?
(check "false? false" (false? false) true)
(check "false? true" (false? true) false)
(check "false? nil" (false? nil) false)
(check "false? 0" (false? 0) false)

;; queue?
(check "queue? queue" (queue? #queue(1 2 3)) true)
(check "queue? vector" (queue? [1 2 3]) false)
(check "queue? list" (queue? (list 1 2 3)) false)
(check "queue? empty queue" (queue? #queue()) true)

;; coll?
(check "coll? vector" (coll? [1 2 3]) true)
(check "coll? list" (coll? (list 1 2 3)) true)
(check "coll? map" (coll? {:a 1}) true)
(check "coll? set" (coll? #{1 2 3}) true)
(check "coll? not coll" (coll? 42) false)
(check "coll? nil" (coll? nil) false)

;; sequential?
(check "sequential? vector" (sequential? [1 2 3]) true)
(check "sequential? list" (sequential? '(1 2 3)) true)
(check "sequential? map" (sequential? {:a 1}) false)
(check "sequential? set" (sequential? #{1 2 3}) false)

;; not-empty
(check "not-empty list" (not-empty (list 1 2 3)) '(1 2 3))
(check "not-empty empty list" (not-empty ()) nil)
(check "not-empty vector" (not-empty [1 2 3]) '[1 2 3])
(check "not-empty empty vector" (not-empty []) nil)
(check "not-empty map" (not-empty {:a 1}) '{:a 1})
(check "not-empty empty map" (not-empty {}) nil)

;; int?
(check "int? int" (int? 42) true)
(check "int? float" (int? 3.14) false)

;; integer?
(check "integer? int" (integer? 42) true)
(check "integer? float" (integer? 3.14) false)

;; double?
(check "double? double" (double? 3.14) true)
(check "double? int" (double? 42) false)

;; float?
(check "float? float" (float? 3.14) true)
(check "float? int" (float? 42) false)

;; NaN?
(check "NaN? string" (NaN? "hello") false)
(check "NaN? int" (NaN? 42) false)

;; infinite?
(check "infinite? int" (infinite? 42) false)
(check "infinite? float" (infinite? 3.14) false)

;; Type conversions
(check "int from float" (int 3.7) 3)
(check "int from int" (int 42) 42)
(check "float from int" (float 42) 42.0)
(check "double from int" (double 42) 42.0)
(check "bigint from int" (str (bigint 42)) "42")
(check "bigint from float" (str (bigint 3.14)) "3")
(check "byte" (byte 42) 42)
(check "short" (short 42) 42)
(check "bigdec" (str (bigdec 3.14)) "3.14")
(check "bigdec from int" (str (bigdec 42)) "42")

;; Bitwise ops
(check "bit-not 0" (bit-not 0) -1)
(check "bit-not -1" (bit-not -1) 0)
(check "bit-xor" (bit-xor 5 3) 6)
(check "bit-xor multi" (bit-xor 1 2 4) 7)
(check "bit-and-not" (bit-and-not 5 3) 4)
(check "bit-clear" (bit-clear 5 1) 5)
(check "bit-clear bit 0" (bit-clear 5 0) 4)
(check "bit-set" (bit-set 4 1) 6)
(check "bit-set already set" (bit-set 5 0) 5)
(check "bit-flip clear" (bit-flip 5 2) 1)
(check "bit-flip set" (bit-flip 4 0) 5)
(check "bit-shift-left" (bit-shift-left 3 2) 12)
(check "bit-shift-left zero" (bit-shift-left 5 0) 5)
(check "bit-shift-right" (bit-shift-right 12 2) 3)
(check "bit-shift-right zero" (bit-shift-right 5 0) 5)
(check "unsigned-bit-shift-right neg" (unsigned-bit-shift-right -1 2) 4611686018427387903)
(check "unsigned-bit-shift-right pos" (unsigned-bit-shift-right 12 2) 3)
(check "bit-test set" (bit-test 5 2) true)
(check "bit-test clear" (bit-test 5 1) false)

;; if-not
(check "if-not false 3arg" (if-not false :yes :no) ':yes)
(check "if-not true 3arg" (if-not true :yes :no) ':no)
(check "if-not nil 2arg" (if-not nil :yes) ':yes)
(check "if-not true 2arg" (if-not true :yes) nil)

;; ensure-reduced / unreduced
(check "ensure-reduced already" (reduced? (ensure-reduced (reduced 42))) true)
(check "ensure-reduced plain" (reduced? (ensure-reduced 42)) true)
(check "unreduced" (unreduced (reduced 42)) 42)
(check "unreduced plain" (unreduced 42) 42)

;; next
(check "next" (next '(1 2 3)) '(2 3))
(check "next empty" (next '()) nil)

;; nthnext
(check "nthnext" (nthnext (list 1 2 3 4 5) 2) '(3 4 5))
(check "nthnext zero" (nthnext (list 1 2 3) 0) '(1 2 3))
(check "nthnext beyond" (nthnext (list 1 2) 5) nil)

;; map
(check "map" (doall (map inc (list 1 2 3))) '(2 3 4))

;; reduce
(check "reduce with init" (reduce + 0 (list 1 2 3 4)) 10)
(check "reduce no init" (reduce + (list 1 2 3 4)) 10)

;; filter
(check "filter" (doall (filter (fn [x] (> x 2)) (list 1 2 3 4))) '(3 4))

;; remove
(check "remove" (doall (remove (fn [x] (> x 2)) (list 1 2 3 4))) '(1 2))

;; flatten
(check "flatten" (doall (flatten '((1 2) (3) (4 5)))) '(1 2 3 4 5))

;; take
(check "take" (doall (take 3 (list 1 2 3 4 5))) '(1 2 3))
(check "take all" (doall (take 10 (list 1 2 3))) '(1 2 3))

;; drop
(check "drop" (doall (drop 2 (list 1 2 3 4 5))) '(3 4 5))
(check "drop all" (doall (drop 10 (list 1 2 3))) '())

;; every?
(check "every? true" (every? (fn [x] (> x 0)) (list 1 2 3)) true)
(check "every? false" (every? (fn [x] (> x 1)) (list 1 2 3)) false)

;; some
(check "some found" (some (fn [x] (> x 2)) (list 1 2 3 4)) true)
(check "some not found" (some (fn [x] (> x 10)) (list 1 2 3)) nil)

;; distinct?
(check "distinct? true" (distinct? (list 1 2 3)) true)
(check "distinct? false" (distinct? (list 1 2 1)) false)

;; not
(check "not true" (not true) false)
(check "not false" (not false) true)
(check "not nil" (not nil) true)
(check "not 1" (not 1) false)

;; reductions
(check "reductions with init" (doall (reductions + 0 (list 1 2 3))) '(0 1 3 6))
(check "reductions no init" (doall (reductions + (list 1 2 3))) '(1 3 6))
(check "reductions conj" (doall (reductions conj [] (list 1 2 3))) '([] [1] [1 2] [1 2 3]))

;; map-indexed
(check "map-indexed" (doall (map-indexed (fn [i x] [i x]) (list "a" "b"))) '([0 "a"] [1 "b"]))

;; keep-indexed
(check "keep-indexed" (doall (keep-indexed (fn [i x] (when (even? i) x)) (list "a" "b" "c"))) '("a" "c"))

;; comp
(check "comp single" ((comp inc) 5) 6)
(check "comp two" ((comp inc dec) 10) 10)

;; fnil
(check "fnil" ((fnil str "default") nil) "default")
(check "fnil two defaults" ((fnil / 0 1) nil 5) 0)

;; juxt
(check "juxt two" ((juxt inc dec) 5) '[6 4])

;; partial
(check "partial" ((partial + 10) 5) 15)

;; sort
(check "sort basic" (sort [3 1 4 1 5 9 2 6]) '(1 1 2 3 4 5 6 9))
(check "sort empty" (sort []) '())
(check "sort single" (sort [42]) '(42))
(check "sort strings" (sort ["b" "a" "c"]) '("a" "b" "c"))

;; sort-by
(check "sort-by identity" (sort-by identity [3 1 4]) '(1 3 4))
(check "sort-by str" (sort-by str [10 2 1]) '(1 10 2))

;; cons
(check "cons list first" (first (cons 1 (list 2 3 4))) 1)
(check "cons list rest" (rest (cons 1 (list 2 3 4))) '(2 3 4))
(check "cons nil first" (first (cons 1 nil)) 1)
(check "cons nil rest" (rest (cons 1 nil)) '())

;; cycle
(check "cycle basic" (doall (take 10 (cycle [1 2 3]))) '(1 2 3 1 2 3 1 2 3 1))
(check "cycle single" (doall (take 5 (cycle [42]))) '(42 42 42 42 42))
(check "cycle strings" (doall (take 4 (cycle ["a" "b"]))) '("a" "b" "a" "b"))

;; = / != / not=
(check "= equal ints" (= 1 1) true)
(check "= not equal" (= 1 2) false)
(check "= multiple args" (= 3 3 3) true)
(check "= maps" (= {:a 1} {:a 1}) true)
(check "!= different" (!= 1 2) true)
(check "!= same" (!= 1 1) false)
(check "not= different" (not= 1 2) true)
(check "not= same" (not= 1 1) false)

;; < / > / <= / >=
(check "< ascending" (< 1 2 3) true)
(check "< not ascending" (< 3 2 1) false)
(check "> descending" (> 3 2 1) true)
(check "> not descending" (> 1 2 3) false)
(check "<= ascending eq" (<= 1 1 2) true)
(check "<= not ascending" (<= 3 2 1) false)
(check ">= descending eq" (>= 3 2 2) true)
(check ">= not descending" (>= 1 2 3) false)

;; + / - / * / /
(check "+ basic" (+ 1 2 3) 6)
(check "+ zero args" (+) 0)
(check "+ one arg" (+ 5) 5)
(check "- two args" (- 10 3) 7)
(check "- three args" (- 10 3 2) 5)
(check "* basic" (* 2 3 4) 24)
(check "* zero args" (*) 1)
(check "/ basic" (/ 10 2) 5)

;; numerator / denominator
(check "numerator ratio" (numerator (/ 22 7)) 22)
(check "numerator int" (numerator 42) 42)
(check "numerator neg ratio" (numerator (/ -3 4)) -3)
(check "denominator ratio" (denominator (/ 22 7)) 7)
(check "denominator int" (denominator 42) 1)
(check "denominator neg ratio" (denominator (/ -3 4)) 4)
(check "num ratio" (num (/ 22 7)) 22)
(check "num int" (num 42) 42)
(check "denom ratio" (denom (/ 22 7)) 7)
(check "denom int" (denom 42) 1)

;; rational
(check "rational float" (rational 1.5) (/ 3 2))
(check "rational int" (rational 5) 5)
(check "rational ratio" (rational (/ 22 7)) (/ 22 7))

;; boolean?
(check "boolean? true" (boolean? true) true)
(check "boolean? false" (boolean? false) true)
(check "boolean? nil" (boolean? nil) false)
(check "boolean? int" (boolean? 42) false)
(check "boolean? string" (boolean? "hello") false)

;; find
(check "find existing" (find {:a 1 :b 2} :a) '{:key :a :val 1})
(check "find missing" (find {:a 1} :b) nil)
(check "find key" (key (find {:a 1} :a)) ':a)
(check "find val" (val (find {:a 1} :a)) 1)

;; filterv
(check "filterv even" (filterv even? (list 1 2 3 4)) '[2 4])
(check "filterv empty" (filterv even? (list 1 3 5)) '[])

;; mapv
(check "mapv inc" (mapv inc (list 1 2 3)) '[2 3 4])
(check "mapv str" (mapv str (list 1 2 3)) '["1" "2" "3"])

;; keepv
(check "keepv" (keepv (fn [x] (when (even? x) (* x 2))) (list 1 2 3 4)) '[4 8])
(check "keepv all nil" (keepv (fn [x] nil) (list 1 2 3)) '[])

;; reducev
(check "reducev + 0" (reducev + 0 [1 2 3 4]) 10)
(check "reducev empty" (reducev + 0 []) 0)
(check "reducev conj" (reducev conj [] (list 1 2 3)) '[1 2 3])

;; completing
(check "completing 1 arg" (let [f (completing + 0)] (f 5)) 5)
(check "completing 2 args" (let [f (completing + 0)] (f 5 3)) 8)
(check "completing conj 2 args" (let [f (completing conj [])] (f [1] 2)) '[1 2])

;; memoize
(check "memoize inc" (let [f (memoize inc)] (f 5)) 6)
(check "memoize square" (let [f (memoize (fn [x] (* x x)))] (f 5)) 25)
(check "memoize cached" (let [f (memoize (fn [x] (* x x)))] (f 5) (f 5)) 25)

;; def with string value (regression)
(check "def string value" (do (def greet "hello") greet) "hello")
(check "def string then use" (do (def msg "world") (str msg)) "world")
(check "def qualified access" (do (def user-val 99) user/user-val) 99)

;; defn with string docstring-like body
(check "defn returns string" (do (defn get-greeting [] "hi") (get-greeting)) "hi")
(check "defn string arg" (do (defn echo [s] s) (echo "test")) "test")

;; user namespace vs clojure.core namespace resolution
(check "defn in user ns qualified call" (do (defn sing [] "lalala") (user/sing)) "lalala")
(check "def in user ns qualified read" (do (def my-ans 42) user/my-ans) 42)
(check "clojure.core function from user" (clojure.core/+ 10 20) 30)
(check "clojure.core str qualified" (clojure.core/str "ns-" "test") "ns-test")
(check "user def shadows core" (do (def + (fn [a b] (* a b))) (+ 3 4)) 12)
(check "core still accessible after shadow" (do (def + (fn [a b] (* a b))) (clojure.core/+ 3 4)) 7)

(print-summary)
