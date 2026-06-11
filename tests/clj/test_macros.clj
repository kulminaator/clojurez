;; Macros: defmacro, doseq, for
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Macro Tests ----
(check "defmacro basic" (do (defmacro my-if [test then-expr] (list (quote if) test then-expr)) (my-if true 42)) 42)
(check "defmacro false branch" (do (defmacro my-if2 [test then-expr] (list (quote if) test then-expr)) (my-if2 false 42)) nil)
(check "defmacro with arithmetic" (do (defmacro double [x] (list (quote +) x x)) (+ 1 (double 5))) 11)
(check "defmacro variadic" (do (defmacro my-let [bindings & body] (cons (quote let) (cons bindings body))) (my-let [x 1 y 2] (+ x y))) 3)
(check "defmacro returns symbol" (defmacro my-macro [x] x) 'my-macro)

;; doseq
(check "doseq single binding" (do (def __a (atom [])) (doseq [x [1 2 3]] (swap! __a conj x)) @__a) '[1 2 3])
(check "doseq nested bindings" (do (def __b (atom [])) (doseq [x [1 2] y [:a :b]] (swap! __b conj (list x y))) @__b) '[(1 :a) (1 :b) (2 :a) (2 :b)])
(check "doseq with computation" (do (def __c (atom [])) (doseq [x [1 2 3]] (swap! __c conj (* x x))) @__c) '[1 4 9])
(check "doseq empty collection" (do (def __d (atom [])) (doseq [x []] (swap! __d conj x)) @__d) '[])
(check "doseq returns nil" (doseq [x [1 2]] x) nil)
(check "doseq with list" (do (def __e (atom [])) (doseq [x (list 10 20 30)] (swap! __e conj (inc x))) @__e) '[11 21 31])

;; for macro - list comprehension
(check "for single binding" (doall (for [x [1 2 3]] (* x x))) '(1 4 9))
(check "for identity" (doall (for [x [1 2 3]] x)) '(1 2 3))
(check "for empty collection" (doall (for [x []] x)) '())
(check "for with string" (doall (for [x ["a" "b" "c"]] (str x "!"))) '("a!" "b!" "c!"))
(check "for with keyword" (doall (for [x [:a :b :c]] x)) '(:a :b :c))
(check "for with map lookup" (doall (for [k [:a :b]] (get {:a 1 :b 2} k))) '(1 2))
(check "for nested bindings" (doall (for [x [1 2] y [:a :b]] (list x y))) '((1 :a) (1 :b) (2 :a) (2 :b)))
(check "for nested with computation" (doall (for [x [1 2] y [3 4]] (+ x y))) '(4 5 5 6))
(check "for nested three levels" (doall (for [x [1 2] y [3 4] z [5 6]] (list x y z))) '((1 3 5) (1 3 6) (1 4 5) (1 4 6) (2 3 5) (2 3 6) (2 4 5) (2 4 6)))
(check "for nested empty inner" (doall (for [x [1 2] y []] (list x y))) '())
(check "for with :when" (doall (for [x [1 2 3 4 5] :when (> x 2)] (* x x))) '(9 16 25))
(check "for with :when all filtered" (doall (for [x [1 2 3] :when (> x 10)] x)) '())
(check "for with :when none filtered" (doall (for [x [1 2 3] :when (< x 10)] x)) '(1 2 3))
(check "for with :while" (doall (for [x [1 2 3 4 5] :while (< x 4)] (* x x))) '(1 4 9))
(check "for with :while stops early" (doall (for [x [2 4 3 6] :while (even? x)] x)) '(2 4))
(check "for with :while first fails" (doall (for [x [1 2 3] :while (> x 5)] x)) '())
(check "for nested with :when" (doall (for [x [1 2 3] :when (> x 1) y [:a :b]] (list x y))) '((2 :a) (2 :b) (3 :a) (3 :b)))
(check "for with range" (doall (for [x (range 1 6)] (* x x))) '(1 4 9 16 25))
(check "for nested with inner :when" (doall (for [x [1 2] y [1 2 3] :when (> y x)] (list x y))) '((1 2) (1 3) (2 3)))
(check "for with even?" (doall (for [x [1 2 3 4 5] :when (even? x)] x)) '(2 4))
(check "for with odd?" (doall (for [x [1 2 3 4 5] :when (odd? x)] x)) '(1 3 5))
(check "for boolean body" (doall (for [x [1 2 3]] (> x 1))) '(false true true))
(check "for nil body" (doall (for [x [1 2 3]] nil)) '(nil nil nil))

(print-summary)
