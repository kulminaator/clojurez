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

;; Test are macro — tabular assertions
(swap! test-results conj (= (are [x y] (= x y)
  2 (+ 1 1)
  4 (* 2 2)) true))

(swap! test-results conj (= (are [a b c] (= (+ a b) c)
  1 1 2
  3 4 7
  10 20 30) true))

;; Test deftest creates a function with :test metadata
(deftest sample-test
  (is (= 1 1)))
(swap! test-results conj (fn? sample-test))
(swap! test-results conj (fn? (:test (meta sample-test))))

;; Test testing macro binds *testing-contexts*
(swap! test-results conj (= (testing "context" (count *testing-contexts*)) 1))

;; Test testing macro is nestable
(swap! test-results conj (= (testing "outer" (testing "inner" (count *testing-contexts*))) 2))

;; Test ref? type predicate
(swap! test-results conj (ref? (ref 42)))
(swap! test-results conj (not (ref? 42)))
(swap! test-results conj (not (ref? nil)))

;; Test commutative? type predicate
(def non-comm-ref (ref 1))
(def comm-ref (ref 2 :commutative true))
(swap! test-results conj (not (commutative? non-comm-ref)))
(swap! test-results conj (commutative? comm-ref))
(swap! test-results conj (not (commutative? 42)))

;; Test prefer-method and preferences
(defmulti test-mm :type)
(defmethod test-mm :a [x] :a)
(defmethod test-mm :b [x] :b)
(defmethod test-mm :c [x] :c)
(prefer-method test-mm :a :b)
(prefer-method test-mm :a :c)
(def test-prefs (preferences test-mm))
(swap! test-results conj (map? test-prefs))
(swap! test-results conj (contains? test-prefs :a))
(swap! test-results conj (= (count (get test-prefs :a)) 2))

;; Test successful? with a zero-failure summary
(swap! test-results conj (successful? {:test 1 :pass 1 :fail 0 :error 0 :type :summary}))
(swap! test-results conj (not (successful? {:test 1 :pass 0 :fail 1 :error 0 :type :summary})))
(swap! test-results conj (not (successful? {:test 1 :pass 0 :fail 0 :error 1 :type :summary})))

;; Test dosync/alter/commute with refs
(def test-r (ref 0))
(dosync (alter test-r + 10))
(swap! test-results conj (= @test-r 10))
(dosync (commute test-r + 5))
(swap! test-results conj (= @test-r 15))
(dosync (ref-set test-r 100))
(swap! test-results conj (= @test-r 100))

;; Test get-method and methods
(swap! test-results conj (fn? (get-method test-mm :a)))
(swap! test-results conj (map? (methods test-mm)))
(swap! test-results conj (fn? (dispatch-fn test-mm)))

;; Go back to user namespace for check
(in-ns 'user)

;; Check all results
(check "clojure.test/all-tests" (every? true? @clojure.test/test-results) true)

(println "All clojure.test tests passed!")
