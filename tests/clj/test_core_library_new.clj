;; New Core Library Functions: constantly, complement, empty, get-in, assoc-in,
;; zipmap, interpose, when-not, when-some, if-let
(load-file "tests/clj/clj_test_helper.clj")

;; constantly
(check "constantly returns fn" (fn? (constantly 42)) true)
(check "constantly calls with no args" ((constantly 42)) 42)
(check "constantly calls with args" ((constantly 42) 1 2 3) 42)

;; complement
(check "complement returns fn" (fn? (complement nil?)) true)
(check "complement nil? true" ((complement nil?) 1) true)
(check "complement nil? false" ((complement nil?) nil) false)
(check "complement even?" ((complement even?) 3) true)
(check "complement even? even" ((complement even?) 4) false)

;; empty
(check "empty list" (empty (list 1 2)) '())
(check "empty vector" (empty [1 2]) '[])
(check "empty map" (empty {:a 1}) '{})
(check "empty set" (empty #{1 2}) '#{})
(check "empty queue" (empty #queue(1 2)) '#queue())

;; get-in
(check "get-in nested" (get-in {:a {:b {:c 42}}} [:a :b :c]) 42)
(check "get-in single key" (get-in {:a 1} [:a]) 1)
(check "get-in missing key" (get-in {:a 1} [:b]) nil)
(check "get-in deep missing" (get-in {:a {:b 1}} [:a :c :d]) nil)

;; assoc-in
(check "assoc-in existing" (assoc-in {:a {:b 1}} [:a :c] 2) '{:a {:b 1 :c 2}})
(check "assoc-in create nested" (assoc-in {} [:a :b :c] 42) '{:a {:b {:c 42}}})
(check "assoc-in single key" (assoc-in {:a 1} [:b] 2) '{:a 1 :b 2})

;; zipmap
(check "zipmap equal length" (zipmap (list :a :b :c) (list 1 2 3)) '{:a 1 :b 2 :c 3})
(check "zipmap keys longer" (zipmap (list :a :b) (list 1)) '{:a 1})
(check "zipmap empty" (zipmap (list) (list)) '{})

;; interpose
(check "interpose basic" (interpose "," (list 1 2 3)) '(1 "," 2 "," 3))
(check "interpose empty" (interpose 0 (list)) '())
(check "interpose single" (interpose 0 (list 1)) '(1))
(check "interpose two" (interpose "-" (list "a" "b")) '("a" "-" "b"))

;; when-not
(check "when-not false" (when-not false "yes") "yes")
(check "when-not true" (when-not true "yes") nil)
(check "when-not multi body" (when-not false (+ 1 2)) 3)

;; when-some
(check "when-some value" (when-some [x 5] (* x 2)) 10)
(check "when-some nil" (when-some [x nil] (* x 2)) nil)
(check "when-some string" (when-some [x "hi"] (str x " there")) "hi there")

;; if-let
(check "if-let truthy" (if-let [x 5] (* x 2) "nope") 10)
(check "if-let nil" (if-let [x nil] (* x 2) "nope") "nope")
(check "if-let false" (if-let [x false] "yes" "no") "no")

(print-summary)
