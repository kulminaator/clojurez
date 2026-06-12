;; Special Forms: def, if, quote, do, when, cond, let
(load-file "tests/clj/clj_test_helper.clj")

(check "def" (def x 42) 'x)
(check "if true" (if true 1 2) 1)
(check "if false" (if false 1 2) 2)
(check "quote" '(1 2 3) '(1 2 3))
(check "do" (do 1 2 3) 3)
(check "when" (when true (+ 1 2)) 3)

;; --- binding ---
(def bind-x 0)
(def bind-a 0)
(def bind-b 0)

(check "binding single var" (binding [bind-x 20] bind-x) 20)
(check "binding multiple vars" (binding [bind-a 10 bind-b 20] (+ bind-a bind-b)) 30)
(check "binding value restored after scope" (do (binding [bind-x 20] bind-x) bind-x) 0)
(check "binding with expression" (binding [bind-x (+ 3 4)] bind-x) 7)
(check "binding nested" (binding [bind-x 20] (binding [bind-x 30] bind-x)) 30)

(print-summary)
