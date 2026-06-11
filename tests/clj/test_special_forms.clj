;; Special Forms: def, if, quote, do, when, cond, let
(load-file "tests/clj/clj_test_helper.clj")

(check "def" (def x 42) 'x)
(check "if true" (if true 1 2) 1)
(check "if false" (if false 1 2) 2)
(check "quote" '(1 2 3) '(1 2 3))
(check "do" (do 1 2 3) 3)
(check "when" (when true (+ 1 2)) 3)

(print-summary)
