;; Destructuring: vector, nested vector, & rest in let
(load-file "tests/clj/clj_test_helper.clj")

(check "vector destructure" ((fn [[a b]] (+ a b)) [1 2]) 3)
(check "nested destructure" ((fn [[[a b] c]] (+ a b c)) [[1 2] 3]) 6)
(check "let destructuring & rest" (let [[a b & rest] (list 1 2 3 4 5)] (list a b rest)) '(1 2 (3 4 5)))
(check "let destructuring & rest empty" (let [[a & rest] (list 1)] (list a rest)) '(1 ()))
(check "let destructuring & rest all" (let [[& rest] (list 1 2 3)] rest) '(1 2 3))

(print-summary)
