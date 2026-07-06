;; Smoke test — fast validation of core language features.
;; Covers: let, limited recursion, loop/recur, anonymous functions, closures.
;; Runs in seconds. If this fails, the full test suite is aborted.
(load-file "tests/clj/clj_test_helper.clj")

;; === Basic let ===
(check "let/basic" (let [x 5] x) 5)
(check "let/nested" (let [x 1] (let [y (+ x 2)] y)) 3)
(check "let/multi-bind" (let [a 1 b 2 c 3] (+ a b c)) 6)
(check "let/shadowing" (let [x 1] (let [x 2] x)) 2)
(check "let/nil-body" (let [x 1] nil) nil)

;; === Anonymous functions ===
(check "fn/basic" ((fn [x] (* x x)) 5) 25)
(check "fn/multi-arg" ((fn [a b] (+ a b)) 3 4) 7)
(check "fn/no-arg" ((fn [] 42)) 42)
(check "fn/nested" ((fn [x] ((fn [y] (* x y)) 3)) 4) 12)

;; === Anonymous function shorthand ===
(check "fn-shorthand/basic" (#(* % %) 7) 49)
(check "fn-shorthand/add" (#(+ % 10) 5) 15)

;; === defn + call ===
(defn double [x] (* x 2))
(check "defn/basic" (double 21) 42)

(defn add-three [a b c] (+ a b c))
(check "defn/multi-arg" (add-three 1 2 3) 6)

;; === Recursion (limited, 100 levels) ===
(defn factorial [n]
  (if (<= n 1)
    1
    (* n (factorial (- n 1)))))
(check "recursion/factorial-5" (factorial 5) 120)
(check "recursion/factorial-10" (factorial 10) 3628800)
(check "recursion/factorial-12" (factorial 12) 479001600)

;; === loop/recur ===
(check "loop-recur/sum"
  (loop [i 1 acc 0]
    (if (> i 100)
      acc
      (recur (inc i) (+ acc i))))
  5050)

(check "loop-recur/countdown"
  (loop [n 1000]
    (if (<= n 0)
      :done
      (recur (- n 1))))
  :done)

(check "loop-recur/factorial"
  (loop [n 10 acc 1]
    (if (<= n 1)
      acc
      (recur (- n 1) (* acc n))))
  3628800)

;; === Closures ===
(defn make-adder [n]
  (fn [x] (+ x n)))
(check "closure/basic" ((make-adder 10) 5) 15)
(check "closure/multiple" ((make-adder 100) 200) 300)

;; === letfn (mutual recursion) ===
(check "letfn/odd-even"
  (letfn [(odd? [n] (if (zero? n) false (even? (- n 1))))
          (even? [n] (if (zero? n) true (odd? (- n 1))))]
    (odd? 7))
  true)

;; === Collections basics ===
(check "map/basic" (get {:a 1 :b 2} :a) 1)
(check "vec/basic" (nth [10 20 30] 1) 20)
(check "list/basic" (= (list 1 2 3) (list 1 2 3)) true)

;; === Conditionals ===
(check "if/truthy" (if true :yes :no) :yes)
(check "if/falsy" (if nil :yes :no) :no)
(check "cond/basic" (cond (= 1 1) :one :else :other) :one)
(check "cond/else" (cond (= 1 2) :one :else :other) :other)

;; === Boolean ===
(check "and/basic" (and true true true) true)
(check "and/short-circuit" (and false true) false)
(check "or/basic" (or false false true) true)
(check "or/short-circuit" (or true false) true)
(check "not/basic" (not true) false)
(check "not/nil" (not nil) true)

;; === Equality ===
(check "eq/numbers" (= 42 42) true)
(check "eq/strings" (= "hello" "hello") true)
(check "eq/not-equal" (= 1 2) false)

print-summary
