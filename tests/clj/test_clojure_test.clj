; Tests for clojure.test assertion system (Phase 3)

(load-file "tests/clj/clj_test_helper.clj")
(load-file "src/clj/test.clj")

;; Test from clojure.test namespace
(in-ns 'clojure.test)

(def test-results (atom []))

;; Test basic assertions return correct values
(swap! test-results conj (= (is (= 4 (+ 2 2))) true))
(swap! test-results conj (= (is "hello") "hello"))
(swap! test-results conj (= (is (not nil)) true))
(swap! test-results conj (= (is (> 5 3)) true))
(swap! test-results conj (= (is (< 3 5)) true))
(swap! test-results conj (= (is (list? (list 1 2))) true))
(swap! test-results conj (= (is (vector? [1 2])) true))

;; Test thrown? returns exception
(swap! test-results conj (= (type (is (thrown? ArithmeticException (/ 1 0)))) :exception))

;; Test thrown-with-msg? returns exception
(swap! test-results conj (= (type (is (thrown-with-msg? ArithmeticException #"Divide" (/ 1 0)))) :exception))

;; Test instance?
(swap! test-results conj (= (is (instance? :integer 42)) true))
(swap! test-results conj (= (is (instance? :string "hello")) true))
(swap! test-results conj (= (is (instance? :keyword :foo)) true))
(swap! test-results conj (= (is (instance? :list (list 1 2))) true))
(swap! test-results conj (= (is (instance? :map {:a 1})) true))
(swap! test-results conj (= (is (instance? :vector [1 2])) true))

;; Test custom message
(swap! test-results conj (= (is (= 1 1) "should pass") true))

;; Test assert-expr returns code forms (list or cons)
(defn code-form? [x]
  (or (list? x) (= (type x) :cons)))

(swap! test-results conj (code-form? (assert-expr nil '(= 1 1))))
(swap! test-results conj (code-form? (assert-expr nil nil)))
(swap! test-results conj (code-form? (assert-expr nil '(instance? :integer 42))))
(swap! test-results conj (code-form? (assert-expr nil '(thrown? Exception (/ 1 0)))))
(swap! test-results conj (code-form? (assert-expr nil '(thrown-with-msg? Exception #"test" (/ 1 0)))))

;; Test assert-any
(swap! test-results conj (code-form? (assert-any "msg" '(+ 1 2))))

;; Test assert-predicate
(swap! test-results conj (code-form? (assert-predicate "msg" '(even? 4))))

;; Test report counters structure
(swap! test-results conj (map? *initial-report-counters*))
(swap! test-results conj (contains? *initial-report-counters* :test))
(swap! test-results conj (contains? *initial-report-counters* :fail))
(swap! test-results conj (contains? *initial-report-counters* :error))

;; Go back to user namespace for check
(in-ns 'user)

;; Check all results
(check "clojure.test/all-assertions" (every? true? @clojure.test/test-results) true)

(println "All clojure.test assertion tests passed!")
