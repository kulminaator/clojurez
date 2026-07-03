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

(print-summary)