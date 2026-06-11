;; Lazy Sequences: lazy-seq, loop/recur, gensym
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Loop/Recur Multiple Bindings ----
(check "loop recur two bindings" (loop [x 0 y 10] (if (< x y) (recur (+ x 1) (- y 1)) x)) 5)
(check "loop recur three bindings" (loop [a 0 b 1 c 2] (if (< a 5) (recur (+ a 1) (+ b 1) (+ c 1)) a)) 5)
(check "loop recur single binding" (loop [x 0] (if (< x 3) (recur (+ x 1)) x)) 3)
(check "loop recur no recur" (loop [x 10] x) 10)

;; ---- Take with Lazy-seq from Variables ----
(check "take from lazy-seq variable" (let [xs (lazy-seq (list 1 2 3 4 5))] (doall (take 3 xs))) '(1 2 3))
(check "take all from lazy-seq variable" (let [xs (lazy-seq (list 1 2))] (doall (take 5 xs))) '(1 2))
(check "take zero from lazy-seq variable" (let [xs (lazy-seq (list 1 2 3))] (doall (take 0 xs))) '())

;; ---- Lazy-seq Scoping ----
(check "lazy-seq uses let helper" (let [f (fn [x] (+ x 1))] (doall (lazy-seq (list (f 5))))) '(6))
(check "lazy-seq multiple let refs" (let [inc2 (fn [x] (+ x 2))] (doall (lazy-seq (list (inc2 1) (inc2 2) (inc2 3))))) '(3 4 5))

;; ---- Gensym ----
(check "gensym returns symbol" (symbol? (gensym)) true)
(check "gensym unique" (let [a (gensym) b (gensym)] (if (= a b) false true)) true)
(check "gensym with prefix" (let [g (gensym "tmp")] (and (symbol? g) (string? (str g)))) true)

(print-summary)
