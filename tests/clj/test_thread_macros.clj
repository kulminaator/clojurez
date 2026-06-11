;; Thread Macros: ->, ->>
(load-file "tests/clj/clj_test_helper.clj")

(check "thread-last basic" (->> 1 (+ 2) (* 3)) 9)
(check "thread-first basic" (-> 1 (+ 2) (* 3)) 9)

(print-summary)
