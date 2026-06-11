;; Lists and Sequences: list, vec, count, first, rest, nth
(load-file "tests/clj/clj_test_helper.clj")

(check "list" (list 1 2 3) '(1 2 3))
(check "vec" (vec 1 2 3) '[1 2 3])
(check "count list" (count (list 1 2 3)) 3)
(check "first" (first (list 1 2 3)) 1)
(check "rest" (rest (list 1 2 3)) '(2 3))
(check "nth" (nth (list 1 2 3) 1) 2)

(print-summary)
