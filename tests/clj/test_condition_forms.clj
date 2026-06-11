;; Condition forms: not, not=, =, identical?, nil?, some?, zero?, pos?, neg?,
;; even?, odd?, boolean, and, or, if, when, when-not, if-not, cond, case,
;; cond->, cond->>, if-let, when-let, some, every?, not-any?
(load-file "tests/clj/clj_test_helper.clj")

;; not
(check "not true" (not true) false)
(check "not false" (not false) true)
(check "not nil" (not nil) true)
(check "not 1" (not 1) false)

;; not=
(check "not= same" (not= 1 1) false)
(check "not= diff" (not= 1 2) true)
(check "not= multi same" (not= 1 1 1) false)
(check "not= multi diff" (not= 1 2 3) true)

;; =
(check "= same" (= 1 1) true)
(check "= diff" (= 1 2) false)
(check "= multi" (= 1 1 1) true)

;; identical?
(check "identical? same int" (identical? 1 1) true)
(check "identical? diff int" (identical? 1 2) false)
(check "identical? same atom" (do (def id-a (atom 5)) (identical? id-a id-a)) true)
(check "identical? diff atom" (do (def id-b (atom 5)) (def id-c (atom 5)) (identical? id-b id-c)) false)
(check "identical? same string" (identical? "hello" "hello") true)
(check "identical? diff string" (identical? "hello" "world") false)

;; nil?
(check "nil? nil" (nil? nil) true)
(check "nil? int" (nil? 1) false)

;; some?
(check "some? int" (some? 1) true)
(check "some? nil" (some? nil) false)
(check "some? true" (some? true) true)
(check "some? false" (some? false) true)
(check "some? empty string" (some? "") true)

;; zero?
(check "zero? 0" (zero? 0) true)
(check "zero? 1" (zero? 1) false)
(check "zero? -1" (zero? (- 0 1)) false)

;; pos?
(check "pos? 1" (pos? 1) true)
(check "pos? 0" (pos? 0) false)
(check "pos? -1" (pos? (- 0 1)) false)

;; neg?
(check "neg? -1" (neg? (- 0 1)) true)
(check "neg? 0" (neg? 0) false)
(check "neg? 1" (neg? 1) false)

;; even?
(check "even? 2" (even? 2) true)
(check "even? 3" (even? 3) false)
(check "even? 0" (even? 0) true)

;; odd?
(check "odd? 3" (odd? 3) true)
(check "odd? 2" (odd? 2) false)
(check "odd? 1" (odd? 1) true)

;; boolean
(check "boolean true" (boolean true) true)
(check "boolean false" (boolean false) false)
(check "boolean nil" (boolean nil) false)
(check "boolean 1" (boolean 1) true)
(check "boolean 0" (boolean 0) true)

;; and
(check "and true true" (and true true) true)
(check "and true false" (and true false) false)
(check "and false true" (and false true) false)
(check "and no args" (and) true)

;; or
(check "or true false" (or true false) true)
(check "or false true" (or false true) true)
(check "or false false" (or false false) false)
(check "or no args" (or) nil)

;; if
(check "if true" (if true :yes :no) ':yes)
(check "if false" (if false :yes :no) ':no)
(check "if no else" (if true :yes) ':yes)

;; when
(check "when true" (when true :yes) ':yes)
(check "when false" (when false :yes) nil)

;; when-not
(check "when-not false" (when-not false :yes) ':yes)
(check "when-not true" (when-not true :yes) nil)

;; if-not
(check "if-not false" (if-not false :yes :no) ':yes)
(check "if-not true" (if-not true :yes :no) ':no)

;; cond
(check "cond first" (cond (= 1 1) :yes :else :no) ':yes)
(check "cond else" (cond (= 1 2) :yes :else :no) ':no)
(check "cond no match" (cond (= 1 2) :a (= 3 4) :b) nil)

;; case
(check "case match 1" (case 1 1 "one" 2 "two" :else "default") "one")
(check "case match 2" (case 2 1 "one" 2 "two" :else "default") "two")
(check "case default" (case 3 1 "one" 2 "two" :else "default") "default")
(check "case no match no default" (case 3 1 "one" 2 "two") nil)
(check "case string" (case "a" "a" :yes "b" :no :else :default) ':yes)
(check "case keyword" (case :x :x :yes :y :no :else :default) ':yes)

;; cond->
(check "cond-> true step" (cond-> 1 true inc) 2)
(check "cond-> false step" (cond-> 1 false inc) 1)
(check "cond-> multi true" (cond-> 1 true inc true inc) 3)
(check "cond-> multi mixed" (cond-> 1 true inc false dec) 2)
(check "cond-> list form" (cond-> [1] true (conj 2)) '[1 2])

;; cond->>
(check "cond->> true step" (cond->> 1 true inc) 2)
(check "cond->> false step" (cond->> 1 false inc) 1)
(check "cond->> multi true" (cond->> 1 true inc true inc) 3)
(check "cond->> multi mixed" (cond->> 1 true inc false dec) 2)
(check "cond->> list form first" (first (cond->> (list 1) true (cons 2))) 2)
(check "cond->> list form rest" (rest (cond->> (list 1) true (cons 2))) '(1))

;; if-let
(check "if-let truthy" (if-let [x 1] x :nope) 1)
(check "if-let nil" (if-let [x nil] x :nope) ':nope)

;; when-let
(check "when-let truthy" (when-let [x 1] x) 1)
(check "when-let nil" (when-let [x nil] x) nil)

;; some
(check "some found" (some #(> % 2) (list 1 2 3 4)) true)
(check "some not found" (some #(> % 10) (list 1 2 3 4)) nil)

;; every?
(check "every? all" (every? #(> % 0) (list 1 2 3)) true)
(check "every? not all" (every? #(> % 1) (list 1 2 3)) false)
(check "every? empty" (every? #(> % 0) (list)) true)

;; not-any?
(check "not-any? none" (not-any? #(> % 10) (list 1 2 3)) true)
(check "not-any? some" (not-any? #(> % 1) (list 1 2 3)) false)
(check "not-any? empty" (not-any? #(> % 0) (list)) true)

(print-summary)
