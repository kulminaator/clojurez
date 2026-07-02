;; Functions: fn, defn, variadic, multi-arity
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Function Tests ----
(check "fn call" ((fn [x] (* x x)) 5) 25)
(check "defn" (defn square [n] (* n n)) 'square)

;; Variadic function tests
(check "variadic fn all rest" (do (defn var-fn [& args] args) (var-fn 1 2 3)) '(1 2 3))
(check "variadic fn empty rest" (do (defn var-fn2 [& args] args) (var-fn2)) '())
(check "variadic fn mixed" (do (defn var-mix [a b & rest] (list a b rest)) (var-mix 1 2 3 4 5)) '(1 2 (3 4 5)))
(check "variadic fn no extra" (do (defn var-mix2 [a b & rest] (list a b rest)) (var-mix2 1 2)) '(1 2 ()))
(check "variadic fn inline" ((fn [& args] args) 10 20 30) '(10 20 30))
(check "variadic fn with defn" (do (defn my-sum [init & nums] (reduce + init nums)) (my-sum 0 1 2 3 4)) 10)

;; ---- Multi-arity Functions ----
(check "multi-arity defn single arg" (do (defn foo [a] a [a b] (+ a b)) (foo 1)) 1)
(check "multi-arity defn two args" (do (defn foo2 [a] a [a b] (+ a b)) (foo2 1 2)) 3)
(check "multi-arity fn single arg" ((fn [a] a [a b] (+ a b)) 1) 1)
(check "multi-arity fn two args" ((fn [a] a [a b] (+ a b)) 1 2) 3)
(check "multi-arity defn three arities" (do (defn bar [] 0 [a] a [a b] (+ a b)) (bar)) 0)
(check "multi-arity defn three arities 1" (do (defn bar2 [] 0 [a] a [a b] (+ a b)) (bar2 5)) 5)
(check "multi-arity defn three arities 2" (do (defn bar3 [] 0 [a] a [a b] (+ a b)) (bar3 3 4)) 7)

;; ---- Deep Recursion Tests (trampolining) ----
(check "deep recursion 1000" (do (defn _deep-count [n] (if (zero? n) 0 (inc (_deep-count (dec n))))) (_deep-count 1000)) 1000)
(check "deep recursion accumulates" (do (defn _deep-sum [n] (if (zero? n) 0 (+ n (_deep-sum (dec n))))) (_deep-sum 1000)) 500500)
(check "mutual recursion 1000" (do (defn _even? [n] (if (zero? n) true (_odd? (dec n)))) (defn _odd? [n] (if (zero? n) false (_even? (dec n)))) (_even? 1000)) true)

(print-summary)
