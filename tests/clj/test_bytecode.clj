;; Test suite for bytecode compilation
;; These tests exercise the bytecode compiler and VM path.
;; Bytecode is used for functions whose bodies don't contain
;; "real" function calls (arithmetic, comparison, and special
;; forms compile to direct opcodes).

(load-file "tests/clj/clj_test_helper.clj")

;; ============================================================
;; LITERALS AND CONSTANTS
;; ============================================================

(check "bytecode: literal nil"
  ((fn [] nil))
  nil)

(check "bytecode: literal integer"
  ((fn [] 42))
  42)

(check "bytecode: literal string"
  ((fn [] "hello"))
  "hello")

(check "bytecode: literal keyword"
  ((fn [] :foo))
  :foo)

(check "bytecode: literal boolean true"
  ((fn [] true))
  true)

(check "bytecode: literal boolean false"
  ((fn [] false))
  false)

;; ============================================================
;; ARITHMETIC (optimized opcodes: add, sub, mul, div, rem, neg)
;; ============================================================

(check "bytecode: add two args"
  ((fn [a b] (+ a b)) 3 4)
  7)

(check "bytecode: add three args"
  ((fn [a b c] (+ a b c)) 1 2 3)
  6)

(check "bytecode: sub two args"
  ((fn [a b] (- a b)) 10 3)
  7)

(check "bytecode: sub single arg (negation)"
  ((fn [x] (- x)) 5)
  -5)

(check "bytecode: mul"
  ((fn [a b] (* a b)) 6 7)
  42)

(check "bytecode: div"
  ((fn [a b] (/ a b)) 20 4)
  5)

(check "bytecode: rem"
  ((fn [a b] (rem a b)) 17 5)
  2)

(check "bytecode: chained arithmetic"
  ((fn [a b] (+ (* a b) (- a b))) 5 3)
  17)

(check "bytecode: nested arithmetic"
  ((fn [x] (+ (+ x 1) (* x 2))) 3)
  10)

;; ============================================================
;; COMPARISON (optimized opcodes: eq, ne, not)
;; ============================================================

(check "bytecode: eq true"
  ((fn [a b] (= a b)) 5 5)
  true)

(check "bytecode: eq false"
  ((fn [a b] (= a b)) 5 6)
  false)

(check "bytecode: ne true"
  ((fn [a b] (not= a b)) 5 6)
  true)

(check "bytecode: ne false"
  ((fn [a b] (not= a b)) 5 5)
  false)

(check "bytecode: not true"
  ((fn [x] (not x)) nil)
  true)

(check "bytecode: not false"
  ((fn [x] (not x)) "hello")
  false)

(check "bytecode: not on false bool"
  ((fn [x] (not x)) false)
  true)

;; ============================================================
;; IF (conditional)
;; ============================================================

(check "bytecode: if true branch"
  ((fn [x] (if x :yes :no)) 1)
  :yes)

(check "bytecode: if false branch"
  ((fn [x] (if x :yes :no)) nil)
  :no)

(check "bytecode: if with arithmetic"
  ((fn [x] (if (> x 5) :big :small)) 10)
  :big)

(check "bytecode: if nested"
  ((fn [x] (if (> x 10) :big (if (> x 5) :medium :small))) 7)
  :medium)

;; ============================================================
;; DO (sequence of forms)
;; ============================================================

(check "bytecode: do returns last"
  ((fn [] (do 1 2 3)))
  3)

(check "bytecode: do with let"
  ((fn [] (do (let [x 10] x) 20)))
  20)

;; ============================================================
;; LET (variable binding)
;; ============================================================

(check "bytecode: let single binding"
  ((fn [] (let [x 42] x)))
  42)

(check "bytecode: let multiple bindings"
  ((fn [] (let [x 10 y 20] (+ x y))))
  30)

(check "bytecode: let shadowing"
  ((fn [x] (let [x 99] x)) 42)
  99)

(check "bytecode: let with arithmetic and args"
  ((fn [a b] (let [sum (+ a b) diff (- a b)] (* sum diff))) 10 3)
  91)

(check "bytecode: let nested"
  ((fn [] (let [x 1] (let [y (+ x 1)] (+ x y)))))
  3)

;; ============================================================
;; AND / OR (short-circuit logic)
;; ============================================================

(check "bytecode: and all truthy"
  ((fn [a b] (and a b)) 1 2)
  2)

(check "bytecode: and first falsy"
  ((fn [a b] (and a b)) nil 2)
  nil)

(check "bytecode: and single arg"
  ((fn [x] (and x)) 42)
  42)

(check "bytecode: and no args"
  ((fn [] (and)))
  true)

(check "bytecode: or first truthy"
  ((fn [a b] (or a b)) 1 nil)
  1)

(check "bytecode: or both falsy"
  ((fn [] (or nil nil)))
  nil)

(check "bytecode: or second truthy"
  ((fn [a b] (or a b)) nil 42)
  42)

(check "bytecode: or no args"
  ((fn [] (or)))
  nil)

(check "bytecode: and/or mixed"
  ((fn [a b c] (and (or a b) c)) nil 2 3)
  3)

;; ============================================================
;; COND (multi-way conditional)
;; ============================================================

(check "bytecode: cond first match"
  ((fn [x] (cond (= x 1) :one (= x 2) :two :else :other)) 1)
  :one)

(check "bytecode: cond second match"
  ((fn [x] (cond (= x 1) :one (= x 2) :two :else :other)) 2)
  :two)

(check "bytecode: cond else clause"
  ((fn [x] (cond (= x 1) :one (= x 2) :two :else :other)) 3)
  :other)

(check "bytecode: cond no match no else"
  ((fn [x] (cond (= x 1) :one (= x 2) :two)) 3)
  nil)

;; (cond) with no clauses is a pre-existing bug in clojurez (returns ArityError)
;; Real Clojure returns nil for (cond) with no clauses

;; ============================================================
;; WHEN (conditional with body)
;; ============================================================

(check "bytecode: when true"
  ((fn [x] (when x 42)) 1)
  42)

(check "bytecode: when false"
  ((fn [x] (when x 42)) nil)
  nil)

(check "bytecode: when multiple body"
  ((fn [x] (when x 1 2 3)) 1)
  3)

;; ============================================================
;; LOOP / RECUR (tail recursion)
;; ============================================================

(check "bytecode: loop recur counter"
  ((fn [n] (loop [i 0] (if (>= i n) i (recur (+ i 1))))) 5)
  5)

(check "bytecode: loop recur accumulator"
  ((fn [n] (loop [i n s 0] (if (<= i 0) s (recur (- i 1) (+ s i))))) 10)
  55)

(check "bytecode: loop recur two bindings"
  ((fn [] (loop [a 0 b 1] (if (>= b 55) b (recur b (+ a b))))))
  55)

(check "bytecode: loop recur immediate return"
  ((fn [] (loop [x 100] (if true x (recur (+ x 1))))))
  100)

;; ============================================================
;; CASE (multi-way constant dispatch)
;; ============================================================

(check "bytecode: case first match"
  ((fn [x] (case x 1 :one 2 :two 3 :three)) 1)
  :one)

(check "bytecode: case second match"
  ((fn [x] (case x 1 :one 2 :two 3 :three)) 2)
  :two)

(check "bytecode: case last match"
  ((fn [x] (case x 1 :one 2 :two 3 :three)) 3)
  :three)

(check "bytecode: case default"
  ((fn [x] (case x 1 :one 2 :two :else :other)) 99)
  :other)

(check "bytecode: case no match no default"
  ((fn [x] (case x 1 :one 2 :two)) 99)
  nil)

(check "bytecode: case string match"
  ((fn [x] (case x "a" :alpha "b" :beta :else :other)) "a")
  :alpha)

;; ============================================================
;; LETFN (local function definitions)
;; ============================================================

(check "bytecode: letfn single function"
  ((fn [] (letfn [(inc2 [x] (+ x 2))] (inc2 10))))
  12)

(check "bytecode: letfn mutual recursion"
  ((fn [] (letfn [(even? [n] (if (zero? n) true (odd? (- n 1))))
                  (odd? [n] (if (zero? n) false (even? (- n 1))))]
            (odd? 7))))
  true)

(check "bytecode: letfn with let"
  ((fn [] (letfn [(square [x] (* x x))]
            (let [x 5] (square x)))))
  25)

;; ============================================================
;; COLLECTIONS (list, vector, map, cons)
;; ============================================================

(check "bytecode: literal vector"
  ((fn [] [1 2 3]))
  [1 2 3])

(check "bytecode: literal map"
  ((fn [] {:a 1 :b 2}))
  {:a 1 :b 2})

(check "bytecode: cons"
  ((fn [x y] (cons x y)) 1 (cons 2 (cons 3 nil)))
  (cons 1 (cons 2 (cons 3 nil))))

(check "bytecode: list with args"
  ((fn [a b c] (list a b c)) 1 2 3)
  '(1 2 3))

(check "bytecode: vec with args"
  ((fn [a b] (vec (list a b))) 10 20)
  [10 20])

;; ============================================================
;; DEREF / @ (atom deref)
;; ============================================================

(check "bytecode: deref atom"
  ((fn [] (let [a (atom 42)] @a)))
  42)

(check "bytecode: deref after swap"
  ((fn [] (let [a (atom 0)] (swap! a + 10) @a)))
  10)

;; ============================================================
;; SET! (variable mutation)
;; ============================================================

(check "bytecode: set! and read"
  ((fn [] (let [x (atom 1)] (set! x (atom 99)) @x)))
  99)

;; ============================================================
;; FN (function creation)
;; ============================================================

(check "bytecode: fn returns function"
  (fn? ((fn [] (fn [x] x))))
  true)

(check "bytecode: fn called"
  (((fn [] (fn [x] (* x 3)))) 7)
  21)

(check "bytecode: fn with multiple arities"
  (((fn [] (fn ([] 0) ([x] x) ([x y] (+ x y))))) 5 6)
  11)

;; ============================================================
;; VARIABLE REFERENCES
;; ============================================================

(check "bytecode: param reference"
  ((fn [x] x) 42)
  42)

(check "bytecode: multiple params"
  ((fn [x y z] z) 1 2 3)
  3)

(check "bytecode: param used in expression"
  ((fn [x y] (+ (* x x) (* y y))) 3 4)
  25)

;; ============================================================
;; EDGE CASES
;; ============================================================

(check "bytecode: empty body (fn returns nil)" ((fn [])) nil)

(check "bytecode: single literal body"
  ((fn [] 1))
  1)

(check "bytecode: variadic function"
  ((fn [& args] (count args)) 1 2 3 4 5)
  5)

(check "bytecode: deeply nested let"
  ((fn [] (let [a 1] (let [b 2] (let [c 3] (+ a b c))))))
  6)

(check "bytecode: if inside let"
  ((fn [x] (let [y (* x 2)] (if (> y 10) :big :small))) 6)
  :big)

(check "bytecode: cond with arithmetic"
  ((fn [x] (cond (< x 0) :neg (= x 0) :zero :else :pos)) -5)
  :neg)

(check "bytecode: cond with arithmetic zero"
  ((fn [x] (cond (< x 0) :neg (= x 0) :zero :else :pos)) 0)
  :zero)

(check "bytecode: cond with arithmetic pos"
  ((fn [x] (cond (< x 0) :neg (= x 0) :zero :else :pos)) 5)
  :pos)

;; ============================================================
;; COMPLEX COMBINATIONS
;; ============================================================

(check "bytecode: loop with cond"
  ((fn [n] (loop [i 0 acc 0]
              (cond
                (>= i n) acc
                (= (rem i 2) 0) (recur (+ i 1) (+ acc i))
                :else (recur (+ i 1) acc)))) 10)
  20)

(check "bytecode: letfn + loop"
  ((fn [] (letfn [(sum-to [n] (loop [i n s 0] (if (<= i 0) s (recur (- i 1) (+ s i)))))]
            (sum-to 20))))
  210)

(check "bytecode: case + let"
  ((fn [x] (let [y (* x 2)] (case y 4 :four 6 :six :else :other))) 2)
  :four)

(check "bytecode: nested fn calls (closures)"
  ((fn [] ((fn [x] (* x 10)) 5)))
  50)

;; ============================================================
;; BIGINT in bytecode (via delegation)
;; ============================================================

(check "bytecode: bigint literal"
  ((fn [] 99999999999999999999N))
  99999999999999999999N)

(check "bytecode: bigint arithmetic"
  ((fn [a b] (+ a b)) 99999999999999999999N 1N)
  100000000000000000000N)

;; ============================================================
;; REGRESSION TESTS (Phase 0: correctness for bytecode optimizations)
;; ============================================================

;; Regression: nested fn calls with primitives — verifies that
;; let bindings with arithmetic inside bytecode-compiled functions
;; work correctly after stack optimization.
(check "bytecode: nested fn calls with primitives"
  ((fn [x] (let [y (+ x 1) z (* y 2)] (+ z 3))) 10)
  25)

;; Regression: multi-arity with bytecode — verifies that multi-arity
;; functions with bytecode-compiled bodies dispatch correctly.
(check "bytecode: multi-arity with bytecode"
  ((fn ([x] x) ([x y] (+ x y))) 1 2)
  3)

;; Regression: loop with arithmetic — verifies loop/recur with
;; bytecode-compiled arithmetic bodies works correctly.
(check "bytecode: loop with arithmetic"
  ((fn [n] (loop [i 0 s 0] (if (< i n) (recur (+ i 1) (+ s i)) s))) 10)
  45)

;; Regression: float arithmetic in bytecode
(check "bytecode: float add"
  ((fn [a b] (+ a b)) 1.5 2.5)
  4.0)

;; Regression: float arithmetic with integer
(check "bytecode: float-int add"
  ((fn [a b] (+ a b)) 3 1.5)
  4.5)

;; Regression: negative integer arithmetic
(check "bytecode: negative integer add"
  ((fn [a b] (+ a b)) -5 3)
  -2)

;; Regression: large integer arithmetic (near i64 boundary)
(check "bytecode: large integer mul"
  ((fn [a b] (* a b)) 1000000 1000000)
  1000000000000)

;; Regression: comparison with integers
(check "bytecode: eq with integers"
  ((fn [a b] (= a b)) 999999999 999999999)
  true)

;; Regression: boolean result from comparison used in if
(check "bytecode: comparison in if"
  ((fn [a b] (if (= a b) :same :diff)) 42 42)
  :same)

;; ============================================================
;; SUMMARY
;; ============================================================

(println "bytecode tests complete")
