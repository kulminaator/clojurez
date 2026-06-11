;; Arithmetic Tests for Clojure VM
;; Run with: ./zig-out/bin/clojurez tests/clj/test_arithmetics.clj

(load-file "tests/clj/clj_test_helper.clj")

;; ---- Addition ----

(check "add two" (+ 1 2) 3)
(check "add many" (+ 1 2 3 4) 10)
(check "add zero args" (+) 0)
(check "add single" (+ 5) 5)
(check "add negatives" (+ -3 7) 4)
(check "add floats" (+ 1.5 2.5) 4.0)

;; ---- Subtraction ----

(check "subtract" (- 10 3) 7)
(check "subtract single negation" (- 5) -5)
(check "subtract multiple" (- 10 3 2) 5)
(check "subtract to negative" (- 3 10) -7)

;; ---- Multiplication ----

(check "multiply" (* 6 7) 42)
(check "multiply zero" (* 5 0) 0)
(check "multiply many" (* 2 3 4) 24)
(check "multiply negatives" (* -2 3) -6)
(check "multiply two negatives" (* -2 -3) 6)

;; ---- Division ----

(check "divide" (/ 10 2) 5)
(check "divide float" (/ 10.0 3) 3.3333333333333335)
(check "divide ratio" (/ 10 3) (/ 10 3))
(check "divide single reciprocal" (/ 2) (/ 1 2))

;; ---- Modulo / Remainder ----

(check "rem positive" (rem 10 3) 1)
(check "rem negative dividend" (rem -10 3) -1)
(check "rem negative divisor" (rem 10 -3) 1)
(check "mod positive" (mod 10 3) 1)
(check "mod negative dividend" (mod -10 3) 2)

;; ---- Quotient ----

(check "quot positive" (quot 10 3) 3)
(check "quot negative" (quot -10 3) -3)

;; ---- Summary ----

(print-summary)
