;; Basic Types Tests: Arithmetic, Comparison, Boolean, Strings, Type checks
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Comparison Tests ----
(check "equal" (= 1 1) true)
(check "not equal" (= 1 2) false)
(check "less than" (< 1 2) true)
(check "greater than" (> 2 1) true)
(check "less equal" (<= 1 1) true)
(check "greater equal" (>= 2 1) true)

;; ---- Boolean Tests ----
(check "true literal" true true)
(check "false literal" false false)
(check "nil literal" nil nil)
(check "not true" (not true) false)
(check "not false" (not false) true)

;; ---- String Tests ----
(check "string literal" "hello" "hello")
(check "string concat" (str "hello" " " "world") "hello world")

;; ---- Type Tests ----
(check "nil?" (nil? nil) true)
(check "nil? not nil" (nil? 1) false)
(check "number?" (number? 42) true)
(check "string?" (string? "hi") true)
(check "list?" (list? '(1 2)) true)

(print-summary)
