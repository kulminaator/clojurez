;; Core Library: update, if-not, drop, apply, comp, partial, fnil, juxt, atom,
;; identity, even?, odd?, zero?, pos?, neg?, abs, max, min, cons, second, third,
;; mod, quot, compare, ==, rationalize
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Core Library Tests ----
(check "update" (update {:a 1} :a inc) '{:a 2})
(check "if-not false" (if-not false :yes :no) ':yes)
(check "if-not true" (if-not true :yes :no) ':no)
(check "if-not nil 2arg" (if-not nil :yes) ':yes)
(check "if-not true 2arg" (if-not true :yes) nil)

(check "drop list" (drop 2 (list 1 2 3 4 5)) '(3 4 5))
(check "drop zero" (drop 0 (list 1 2 3)) '(1 2 3))
(check "drop all" (drop 10 (list 1 2)) '())
(check "drop vector" (drop 1 [1 2 3]) '[2 3])

(check "apply +" (apply + (list 1 2 3 4)) 10)
(check "apply + with prefix" (apply + 10 (list 1 2 3)) 16)
(check "apply str" (apply str "hello" (list " " "world")) "hello world")

(check "comp single" (do (defn f [x] (+ x 1)) ((comp f) 5)) 6)
(check "comp two" (do (defn f2 [x] (+ x 1)) (defn g [x] (* x 2)) ((comp g f2) 5)) 12)
(check "comp three" (do (defn f3 [x] (+ x 1)) (defn g2 [x] (* x 2)) (defn h [x] (- x 1)) ((comp h g2 f3) 5)) 11)

(check "partial" (do (def add3 (partial + 3)) (add3 (list 5))) 8)
(check "fnil" (do (def ffnil (fnil / 0 1)) (ffnil 10 5)) 2)
(check "fnil nil arg" (do (def ffnil2 (fnil / 0 1)) (ffnil2 nil 5)) 0)
(check "fnil nil second" (do (def ffnil3 (fnil / 0 1)) (ffnil3 10 nil)) 10)

(check "juxt two" (do (def fjuxt (juxt inc dec)) (fjuxt 5)) '[6 4])
(check "juxt three" (do (def fjuxt2 (juxt str inc dec)) (fjuxt2 5)) '["5" 6 4])

(check "atom create" (deref (atom 5)) 5)
(check "atom reset!" (do (def areset (atom 5)) (reset! areset 10) (deref areset)) 10)
(check "atom swap!" (do (def aswap (atom 5)) (swap! aswap inc) (deref aswap)) 6)
(check "atom swap! with args" (do (def aswap2 (atom 5)) (swap! aswap2 + 3) (deref aswap2)) 8)

(check "identity" (identity 42) 42)

(check "even?" (even? 4) true)
(check "odd?" (odd? 3) true)
(check "zero?" (zero? 0) true)
(check "pos?" (pos? 5) true)
(check "neg?" (neg? (- 0 3)) true)
(check "abs" (abs (- 0 5)) 5)
(check "max" (max 3 7) 7)
(check "min" (min 3 7) 3)
(check "cons first" (first (cons 0 (list 1 2))) 0)
(check "cons rest" (rest (cons 0 (list 1 2))) '(1 2))
(check "second" (second (list 1 2 3)) 2)
(check "third" (third (list 1 2 3)) 3)

;; ---- Mod Tests ----
(check "mod positive" (mod 7 3) 1)
(check "mod neg dividend" (mod -7 3) 2)
(check "mod neg divisor" (mod 7 -3) -2)
(check "mod both neg" (mod -7 -3) -1)
(check "mod zero" (mod 0 5) 0)
(check "mod exact" (mod 6 3) 0)
(check "mod float" (mod 7.5 3.0) 1.5)
(check "mod float neg" (mod -7.5 3.0) 1.5)

;; ---- Quot Tests ----
(check "quot positive" (quot 7 3) 2)
(check "quot neg dividend" (quot -7 3) -2)
(check "quot neg divisor" (quot 7 -3) -2)
(check "quot both neg" (quot -7 -3) 2)
(check "quot zero" (quot 0 5) 0)
(check "quot exact" (quot 6 3) 2)

;; ---- Compare Tests ----
(check "compare less" (compare 1 2) -1)
(check "compare greater" (compare 2 1) 1)
(check "compare equal" (compare 1 1) 0)
(check "compare int float" (compare 1 1.0) 0)
(check "compare string lt" (compare "a" "b") -1)
(check "compare string gt" (compare "b" "a") 1)
(check "compare string eq" (compare "a" "a") 0)
(check "compare nil less" (compare nil 1) -1)
(check "compare nil greater" (compare 1 nil) 1)
(check "compare nil nil" (compare nil nil) 0)

;; ---- Double Eq Tests ----
(check "== int float equal" (== 1 1.0) true)
(check "== int int equal" (== 1 1) true)
(check "== int int not equal" (== 1 2) false)
(check "== float float equal" (== 1.0 1.0) true)
(check "== float float not equal" (== 1.0 2.0) false)
(check "== multiple equal" (== 1 1.0 1) true)
(check "== multiple not equal" (== 1 2 3) false)
(check "== zero args" (==) true)
(check "== one arg" (== 5) true)

;; ---- Rationalize Tests ----
(check "rationalize int" (rationalize 5) 5)
(check "rationalize 1.0" (rationalize 1.0) 1)
(check "rationalize 1.5" (rationalize 1.5) (/ 3 2))
(check "rationalize 0.1" (rationalize 0.1) (/ 1 10))
(check "rationalize 0.25" (rationalize 0.25) (/ 1 4))
(check "rationalize 2.0" (rationalize 2.0) 2)
(check "rationalize 0.33" (rationalize 0.33) (/ 33 100))
(check "rationalize neg" (rationalize -1.5) (/ -3 2))

(print-summary)
