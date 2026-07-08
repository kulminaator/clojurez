;; Test that the trampoline mechanism prevents Zig stack growth
;; during deep Clojure recursion. This is a regression test to catch
;; any future changes that might reintroduce stack growth.
;;
;; If the trampoline is not working, deep recursion would cause a Zig
;; stack overflow and crash. These tests verify that deep recursion
;; completes successfully.
(load-file "tests/clj/clj_test_helper.clj")

;; Test 1: Simple recursion at various depths
(check-true "trampoline-depth-100"
  (do
    (defn dc100 [n] (if (zero? n) 0 (inc (dc100 (dec n)))))
    (= (dc100 100) 100)))

(check-true "trampoline-depth-500"
  (do
    (defn dc500 [n] (if (zero? n) 0 (inc (dc500 (dec n)))))
    (= (dc500 500) 500)))

(check-true "trampoline-depth-1000"
  (do
    (defn dc1000 [n] (if (zero? n) 0 (inc (dc1000 (dec n)))))
    (= (dc1000 1000) 1000)))

(check-true "trampoline-depth-2000"
  (do
    (defn dc2000 [n] (if (zero? n) 0 (inc (dc2000 (dec n)))))
    (= (dc2000 2000) 2000)))

;; Test 2: Mutual recursion
(check-true "trampoline-mutual-recursion"
  (do
    (defn even? [n] (if (zero? n) true (odd? (dec n))))
    (defn odd? [n] (if (zero? n) false (even? (dec n))))
    (and (even? 1000) (odd? 999))))

;; Test 3: Tail-call-like pattern with accumulator
(check-true "trampoline-tail-accumulator"
  (do
    (defn sum-tail [n acc] (if (zero? n) acc (sum-tail (dec n) (+ acc n))))
    (= (sum-tail 1000 0) 500500)))

;; Test 4: Correctness checks
(check "recursive-sum-correctness"
  (do
    (defn sum-to [n acc] (if (zero? n) acc (sum-to (dec n) (+ acc n))))
    (sum-to 100 0))
  5050)

(check "recursive-fibonacci-correctness"
  (do
    (defn fib [n] (if (<= n 1) n (+ (fib (dec n)) (fib (- n 2)))))
    (fib 10))
  55)

;; Test 5: Quasiquote + unquote with user function (regression: eval_macro.zig)
;; Previously crashed with "access of union field 'value' while field 'trampoline' is active"
(check-true "trampoline-quasiquote-unquote-user-fn"
  (do
    (let [f (fn [x] (* x x))]
      (= `(1 2 (~ (f 3)) 4) '(1 2 (9) 4)))))

;; Test 6: Quasiquote + unquote-splicing with user function (regression: eval_macro.zig)
(check-true "trampoline-quasiquote-unquote-splicing-user-fn"
  (do
    (let [f (fn [x] (list (* x x) (* x 3)))]
      (= `(1 ~@ (f 3) 4) '(1 9 9 4)))))

;; Test 7: Nested quasiquote with unquote and user function
(check-true "trampoline-quasiquote-nested-unquote-user-fn"
  (do
    (let [f (fn [x y] (+ x y))]
      (= `((~ (f 1 2)) (~ (f 3 4))) '((3) (7))))))

;; Test 8: Quasiquote with unquote-splicing in list iteration (regression: eval_macro.zig line 41)
(check-true "trampoline-quasiquote-splicing-in-list-iteration"
  (do
    (let [f (fn [] (list 10 20))]
      (= `(a ~@ (f) b) '(a 10 20 b)))))

;; Test 9: Macro expansion with user function call (regression: bytecode.zig tryExpandMacro)
(check-true "trampoline-macro-expansion-with-user-fn"
  (do
    (defmacro m-expand-fn []
      (let [f (fn [x] (* x 5))]
        (f 2)))
    (= (m-expand-fn) 10)))

;; Test 10: Quasiquote with deeply nested unquote and user function
(check-true "trampoline-quasiquote-deep-nested-unquote"
  (do
    (let [f (fn [x] (list x (inc x)))]
      (= `(outer ~(f 1) inner) '(outer (1 2) inner)))))

(print-summary)