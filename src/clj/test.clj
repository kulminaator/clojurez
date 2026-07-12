; clojure.test implementation for ClojureZ
; Adapted from original Clojure test.clj

(ns clojure.test
  (:require [clojure.string :as str]))

;;; USER-MODIFIABLE GLOBALS

(def *load-tests* true)

(def *stack-trace-depth* nil)

;;; GLOBALS USED BY THE REPORTING FUNCTIONS

(def *report-counters* nil)

(def *initial-report-counters*
  {:test 0, :pass 0, :fail 0, :error 0})

(def *testing-vars* (list))

(def *testing-contexts* (list))

(def *test-out* nil)

(defmacro with-test-out
  "Runs body with output directed to *test-out*."
  [& body]
  `(do ~@body))

;;; UTILITIES FOR REPORTING FUNCTIONS

(defn inc-report-counter
  "Increments the named counter in *report-counters*, a ref to a map."
  [name]
  (when *report-counters*
    (dosync (commute *report-counters* update-in [name] (fnil inc 0)))))

(defn testing-vars-str
  "Returns a string representation of the current test."
  [m]
  (let [file (get m :file)
        line (get m :line)
        var-names (reverse (map name *testing-vars*))]
    (str var-names " (" (or file "?") ":" (or line "?") ")")))

(defn testing-contexts-str
  "Returns a string representation of the current test context."
  []
  (apply str (interpose " " (reverse *testing-contexts*))))

;;; TEST RESULT REPORTING

(defmulti report
  "Generic reporting function, dispatched on :type."
  :type)

(defn do-report
  "Add file and line information to a test result and call report."
  [m]
  (report m))

(defmethod report :default [m]
  (with-test-out (prn m)))

(defmethod report :pass [m]
  (with-test-out (inc-report-counter :pass)))

(defmethod report :fail [m]
  (with-test-out
    (inc-report-counter :fail)
    (println "\nFAIL in" (testing-vars-str m))
    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    (when-let [message (:message m)] (println message))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (pr-str (:actual m)))))

(defmethod report :error [m]
  (with-test-out
    (inc-report-counter :error)
    (println "\nERROR in" (testing-vars-str m))
    (when (seq *testing-contexts*) (println (testing-contexts-str)))
    (when-let [message (:message m)] (println message))
    (println "expected:" (pr-str (:expected m)))
    (print "  actual: ")
    (prn (:actual m))))

(defmethod report :summary [m]
  (with-test-out
    (println "\nRan" (:test m) "tests containing"
             (+ (:pass m) (:fail m) (:error m)) "assertions.")
    (println (:fail m) "failures," (:error m) "errors.")))

(defmethod report :begin-test-ns [m]
  (with-test-out
    (println "\nTesting" (name (ns-name (:ns m))))))

;; Ignore these message types:
(defmethod report :end-test-ns [m])
(defmethod report :begin-test-var [m])
(defmethod report :end-test-var [m])

;;; ASSERTION HELPERS

(defn assert-predicate
  "Returns generic assertion code for any functional predicate.
   The 'expected' argument to 'report' will contain the original form,
   the 'actual' argument will contain the form with all its sub-forms evaluated.
   If the predicate returns false, the 'actual' form will be wrapped in (not ...)."
  [msg form]
  (let [args (rest form)
        pred (first form)
        values-sym (gensym "values")
        result-sym (gensym "result")]
    (list 'let
          (list values-sym (cons 'list args)
                result-sym (list 'apply pred values-sym))
          (list 'if result-sym
                (list 'do-report {:type :pass :message msg
                                  :expected (list 'quote form)
                                  :actual (list 'list (list 'quote pred) values-sym)})
                (list 'do-report {:type :fail :message msg
                                  :expected (list 'quote form)
                                  :actual (list 'list (list 'quote 'not) (list 'cons (list 'quote pred) values-sym))}))
          result-sym)))

(defn assert-any
  "Returns generic assertion code for any test,
   including macros, method calls, or isolated symbols."
  [msg form]
  (let [value-sym (gensym "value")]
    (list 'let
          (list value-sym form)
          (list 'if value-sym
                (list 'do-report {:type :pass :message msg
                                  :expected (list 'quote form)
                                  :actual value-sym})
                (list 'do-report {:type :fail :message msg
                                  :expected (list 'quote form)
                                  :actual value-sym}))
          value-sym)))

;;; ASSERTION METHODS

;; You don't call these, but you can add methods to extend the 'is' macro.
;; These define different kinds of tests, based on the first symbol in the test expression.

(defmulti assert-expr
  "Dispatches assertion handling based on the form's first element.
   :always-fail for nil forms, :default for generic, or the first symbol for special handling."
  (fn [msg form]
    (cond
      (nil? form) :always-fail
      (and (or (list? form) (vector? form)) (not (empty? form))) (first form)
      :else :default)))

(defmethod assert-expr :always-fail [msg form]
  "Nil test: always fail."
  (list 'do-report {:type :fail :message msg}))

(defmethod assert-expr :default [msg form]
  "Generic assertion: predicate or any test."
  (if (and (sequential? form) (fn? (first form)))
    (assert-predicate msg form)
    (assert-any msg form)))

(defmethod assert-expr 'instance? [msg form]
  "Test if x is an instance of the given type."
  (let [klass-sym (gensym "klass")
        object-sym (gensym "object")
        result-sym (gensym "result")
        klass-expr (nth form 1)
        object-expr (nth form 2)]
    (list 'let
          (list klass-sym klass-expr
                object-sym object-expr)
          (list 'let
                (list result-sym (list 'instance? klass-sym object-sym))
                (list 'if result-sym
                      (list 'do-report {:type :pass :message msg
                                        :expected (list 'quote form)
                                        :actual (list 'class object-sym)})
                      (list 'do-report {:type :fail :message msg
                                        :expected (list 'quote form)
                                        :actual (list 'class object-sym)}))
                result-sym))))

(defmethod assert-expr 'thrown? [msg form]
  "Asserts that evaluating body throws an exception of class klass.
   Returns the exception thrown."
  (let [klass (second form)
        body (nthnext form 2)
        e-sym (gensym "e")]
    (cons 'try
          (concat body
                  (list (list 'do-report {:type :fail :message msg
                                         :expected (list 'quote form)
                                         :actual nil})
                        (list 'catch klass e-sym
                              (list 'do-report {:type :pass :message msg
                                                :expected (list 'quote form)
                                                :actual e-sym})
                              e-sym))))))

(defmethod assert-expr 'thrown-with-msg? [msg form]
  "Asserts that evaluating body throws an exception of class klass
   AND that the message matches the regular expression re."
  (let [klass (nth form 1)
        re (nth form 2)
        body (nthnext form 3)
        e-sym (gensym "e")
        m-sym (gensym "m")]
    (cons 'try
          (concat body
                  (list (list 'do-report {:type :fail :message msg
                                         :expected (list 'quote form)
                                         :actual nil})
                        (list 'catch klass e-sym
                              (list 'let
                                    (list m-sym (list 'ex-message e-sym))
                                    (list 'if (list 're-find re m-sym)
                                          (list 'do-report {:type :pass :message msg
                                                            :expected (list 'quote form)
                                                            :actual e-sym})
                                          (list 'do-report {:type :fail :message msg
                                                            :expected (list 'quote form)
                                                            :actual e-sym})))
                              e-sym))))))

;;; ASSERTION MACROS

(defmacro try-expr
  "Used by the 'is' macro to catch unexpected exceptions."
  [msg form]
  (let [t-sym (gensym "t")
        inner (assert-expr msg form)]
    (list 'try
          inner
          (list 'catch 'Throwable t-sym
                (list 'do-report {:type :error :message msg
                                  :expected (list 'quote form)
                                  :actual t-sym})))))

(defmacro is
  "Generic assertion macro. 'form' is any predicate test.
   'msg' is an optional message to attach to the assertion.

   Example: (is (= 4 (+ 2 2)) \"Two plus two should be 4\")

   Special forms:

   (is (thrown? c body)) checks that an instance of c is thrown from
   body, fails if not; then returns the thing thrown.

   (is (thrown-with-msg? c re body)) checks that an instance of c is
   thrown AND that the message on the exception matches (with
   re-find) the regular expression re."
  ([form] `(is ~form nil))
  ([form msg] `(try-expr ~msg ~form)))


;;; TESTING MACRO

(defmacro testing
  "Adds a new string to the list of testing contexts.  May be nested,
   but must occur inside a test function (deftest)."
  [string & body]
  `(binding [*testing-contexts* (conj *testing-contexts* ~string)]
     ~@body))


;;; DEFINING TESTS

(defmacro deftest
  "Defines a test function with no arguments.  Test functions may call
   other tests, so tests may be composed.  If you compose tests, you
   should also define a function named test-ns-hook; run-tests will
   call test-ns-hook instead of testing all vars.

   When *load-tests* is false, deftest is ignored."
  [name & body]
  (when *load-tests*
    `(do
       (def ~name (fn [] (test-var (var ~name))))
       (alter-meta! '~name assoc :test (fn [] ~@body)))))

(defmacro deftest-
  "Like deftest but creates a private var."
  [name & body]
  (when *load-tests*
    `(do
       (def ~name (fn [] (test-var (var ~name))))
       (alter-meta! '~name assoc :test (fn [] ~@body) :private true))))

(defmacro with-test
  "Takes any definition form (that returns a Var) as the first argument.
   Remaining body goes in the :test metadata function for that Var.

   When *load-tests* is false, only evaluates the definition, ignoring
   the tests."
  [definition & body]
  (if *load-tests*
    `(doto ~definition (alter-meta! assoc :test (fn [] ~@body)))
    definition))

(defmacro set-test
  "Sets :test metadata of the named var to a fn with the given body.
   The var must already exist.  Does not modify the value of the var.

   When *load-tests* is false, set-test is ignored."
  [name & body]
  (when *load-tests*
    `(alter-meta! '~name assoc :test (fn [] ~@body))))


;;; DEFINING FIXTURES

(defn- add-ns-meta
  "Adds elements in coll to the current namespace metadata as the value of key."
  [key coll]
  (alter-meta! '*ns* assoc key coll))

(defn use-fixtures
  "Wrap test runs in a fixture function to perform setup and teardown.
   Using a fixture-type of :each wraps every test individually,
   while :once wraps the whole run in a single function."
  [fixture-type & args]
  (case fixture-type
    :each (add-ns-meta :clojure.test/each-fixtures args)
    :once (add-ns-meta :clojure.test/once-fixtures args)
    (throw (ex-info (str "Unknown fixture type: " fixture-type) {}))))

(defn- default-fixture
  "The default, empty, fixture function. Just calls its argument."
  [f]
  (f))

(defn compose-fixtures
  "Composes two fixture functions, creating a new fixture function
   that combines their behavior."
  [f1 f2]
  (fn [g] (f1 (fn [] (f2 g)))))

(defn join-fixtures
  "Composes a collection of fixtures, in order. Always returns a valid
   fixture function, even if the collection is empty."
  [fixtures]
  (if (nil? fixtures)
    default-fixture
    (reduce compose-fixtures default-fixture fixtures)))


;;; RUNNING TESTS: LOW-LEVEL FUNCTIONS

(defn test-var
  "If v has a function in its :test metadata, calls that function,
   with *testing-vars* bound to (conj *testing-vars* v)."
  [v]
  (when-let [t (:test (meta v))]
    (binding [*testing-vars* (conj *testing-vars* v)]
      (do-report {:type :begin-test-var :var v})
      (inc-report-counter :test)
      (try (t)
           (catch Throwable e
             (do-report {:type :error
                         :message "Uncaught exception, not in assertion."
                         :expected nil
                         :actual e})))
      (do-report {:type :end-test-var :var v}))))

(defn test-vars
  "Groups vars by their namespace and runs test-var on them with
   appropriate fixtures applied."
  [vars ns-obj]
  ;; Get each-test fixtures from namespace metadata
  (let [each-fixture-fn (join-fixtures (:clojure.test/each-fixtures (meta ns-obj)))
        test-fns (filter #(and (fn? %) (:test (meta %))) vars)]
    (doseq [v test-fns]
      (each-fixture-fn (fn [] (test-var v))))))

(defn test-all-vars
  "Calls test-vars on every var interned in the namespace, with fixtures."
  [ns-obj]
  ;; Get test vars from namespace interns
  (test-vars (vals (ns-interns ns-obj)) ns-obj))

(defn test-ns
  "If the namespace defines a function named test-ns-hook, calls that.
   Otherwise, calls test-all-vars on the namespace. 'ns' is a
   namespace object or a symbol.

   Internally binds *report-counters* to a ref initialized to
   *initial-report-counters*. Returns the final, dereferenced state of
   *report-counters*."
  [ns]
  (binding [*report-counters* (ref *initial-report-counters*)]
    (let [ns-obj (the-ns ns)
          once-fixture-fn (join-fixtures (:clojure.test/once-fixtures (meta ns-obj)))]
      (do-report {:type :begin-test-ns :ns ns-obj})
      (once-fixture-fn (fn []
        (if-let [v (find-var (symbol (str (ns-name ns-obj)) "test-ns-hook"))]
          ((resolve v))
          (test-all-vars ns-obj))))
      (do-report {:type :end-test-ns :ns ns-obj}))
    @*report-counters*))


;;; RUNNING TESTS: HIGH-LEVEL FUNCTIONS

(defn run-tests
  "Runs all tests in the given namespaces; prints results.
   Returns a map summarizing test results."
  [& namespaces]
  ;; Use loop instead of map because test-ns uses binding (special form)
  ;; and map's evaluation path doesn't support special forms
  (let [results (loop [nss namespaces acc ()]
                  (if (empty? nss)
                    acc
                    (recur (rest nss) (conj acc (test-ns (first nss))))))
        summary (assoc (apply merge-with + results) :type :summary)]
    (do-report summary)
    summary))

(defn run-all-tests
  "Runs all tests in all namespaces; prints results.
   Optional argument is a regular expression; only namespaces with
   names matching the regular expression (with re-matches) will be
   tested."
  ([] (apply run-tests (all-ns)))
  ([re] (apply run-tests (filter #(re-matches re (name (ns-name %))) (all-ns)))))

(defn successful?
  "Returns true if the given test summary indicates all tests
   were successful, false otherwise."
  [summary]
  (and (zero? (get summary :fail 0))
       (zero? (get summary :error 0))))

(defn run-test-var
  "Runs the tests for a single Var, with fixtures executed around
   the test, and summary output after."
  [v]
  (binding [*report-counters* (ref *initial-report-counters*)]
    (let [ns-name (:ns (meta v))
          ns-obj (the-ns ns-name)
          each-fixture-fn (join-fixtures (:clojure.test/each-fixtures (meta ns-obj)))]
      (each-fixture-fn (fn [] (test-var v)))
      (let [summary (assoc @*report-counters* :type :summary)]
        (do-report summary)
        summary))))

(defmacro run-test
  "Runs the tests for a single test var, identified by symbol.
   Returns the summary map."
  [sym]
  `(run-test-var (var ~sym)))
