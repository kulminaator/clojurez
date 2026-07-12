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
