;; ============================================================
;; Exception support tests
;; ============================================================

(load-file "tests/clj/clj_test_helper.clj")

;; ---- ex-info creation ----

(check "ex-info basic"
  (ex-info "test" {:code 42})
  (ex-info "test" {:code 42}))

(check "ex-info formatting"
  (str (ex-info "boom" {}))
  "#error(clojure.lang/ExceptionInfo: \"boom\")")

(check "ex-info with nil message"
  (ex-message (ex-info nil {:x 1}))
  nil)

;; ---- ex-message ----

(check "ex-message returns message"
  (ex-message (ex-info "hello" {}))
  "hello")

(check "ex-message nil for non-exception"
  (ex-message 42)
  nil)

(check "ex-message nil for nil"
  (ex-message nil)
  nil)

;; ---- ex-data ----

(check "ex-data returns data map"
  (ex-data (ex-info "test" {:a 1 :b 2}))
  {:a 1 :b 2})

(check "ex-data nil for non-exception"
  (ex-data "not an exception")
  nil)

(check "ex-data nil for nil"
  (ex-data nil)
  nil)

;; ---- ex-cause ----

(check "ex-cause returns cause"
  (let [cause (ex-info "root" {:a 1})
        wrapped (ex-info "wrapped" {:b 2} cause)]
    (ex-message (ex-cause wrapped)))
  "root")

(check "ex-cause nil for no cause"
  (ex-cause (ex-info "no cause" {}))
  nil)

(check "ex-cause nil for non-exception"
  (ex-cause 42)
  nil)

(check "ex-cause chain"
  (let [root (ex-info "root" {:a 1})
        mid (ex-info "mid" {:b 2} root)
        top (ex-info "top" {:c 3} mid)]
    (ex-message (ex-cause (ex-cause top))))
  "root")

;; ---- exception? predicate ----

(check "exception? true for exception"
  (exception? (ex-info "test" {}))
  true)

(check "exception? false for non-exception"
  (exception? 42)
  false)

(check "exception? false for nil"
  (exception? nil)
  false)

(check "exception? false for string"
  (exception? "hello")
  false)

;; ---- isa? built-in hierarchy ----

(check "isa? ArithmeticException isa RuntimeException"
  (isa? :clojure.lang/ArithmeticException :clojure.lang/RuntimeException)
  true)

(check "isa? ArithmeticException isa Exception"
  (isa? :clojure.lang/ArithmeticException :clojure.lang/Exception)
  true)

(check "isa? ExceptionInfo isa RuntimeException"
  (isa? :clojure.lang/ExceptionInfo :clojure.lang/RuntimeException)
  true)

(check "isa? FileNotFoundException isa IOException"
  (isa? :clojure.lang/FileNotFoundException :clojure.lang/IOException)
  true)

(check "isa? IOException isa Exception"
  (isa? :clojure.lang/IOException :clojure.lang/Exception)
  true)

(check "isa? IOException NOT isa RuntimeException"
  (isa? :clojure.lang/IOException :clojure.lang/RuntimeException)
  false)

(check "isa? same type"
  (isa? :clojure.lang/Exception :clojure.lang/Exception)
  true)

(check "isa? TimeoutException isa Exception"
  (isa? :clojure.lang/TimeoutException :clojure.lang/Exception)
  true)

(check "isa? NullPointerException isa RuntimeException"
  (isa? :clojure.lang/NullPointerException :clojure.lang/RuntimeException)
  true)

;; ---- parents ----

(check "parents ArithmeticException"
  (parents :clojure.lang/ArithmeticException)
  #{:clojure.lang/RuntimeException})

(check "parents RuntimeException"
  (parents :clojure.lang/RuntimeException)
  #{:clojure.lang/Exception})

(check "parents Exception"
  (parents :clojure.lang/Exception)
  #{:clojure.lang/Throwable})

(check "parents Throwable (root)"
  (parents :clojure.lang/Throwable)
  #{})

(check "parents unknown type"
  (parents :unknown/type)
  #{})

;; ---- derive custom hierarchy ----

(check "derive custom type"
  (do
    (derive :my.app/my-error :clojure.lang/Exception)
    (isa? :my.app/my-error :clojure.lang/Exception))
  true)

(check "derive multi-level custom hierarchy"
  (do
    (derive :my.app/sub-error :my.app/my-error)
    (isa? :my.app/sub-error :clojure.lang/Exception))
  true)

(check "parents custom type"
  (do
    (derive :my.app/custom-err :my.app/base-err)
    (parents :my.app/custom-err))
  #{:my.app/base-err})

;; ---- ex-info with custom :type ----

(check "ex-info custom type in data map"
  (let [e (ex-info "custom" {:type :my.app/my-error :code 500})]
    (str e))
  "#error(my.app/my-error: \"custom\")")

(check "ex-info type keyword"
  (let [e (ex-info "test" {:type :clojure.lang/ArithmeticException})]
    (str e))
  "#error(clojure.lang/ArithmeticException: \"test\")")

;; ---- Exception equality ----

(check "exception equality same message and data"
  (= (ex-info "test" {:x 1}) (ex-info "test" {:x 1}))
  true)

(check "exception equality different message"
  (= (ex-info "a" {}) (ex-info "b" {}))
  false)

(check "exception equality different data"
  (= (ex-info "test" {:x 1}) (ex-info "test" {:x 2}))
  false)

;; ---- type of exception ----

(check "type of exception is :exception"
  (type (ex-info "test" {}))
  :exception)

;; ---- Exception with nil cause ----

(check "ex-info with nil cause"
  (ex-cause (ex-info "test" {} nil))
  nil)

;; ============================================================
;; throw
;; ============================================================

(check "throw ex-info returns exception"
  (try (throw (ex-info "test" {:code 42}))
       (catch Exception e (ex-data e)))
  {:code 42})

(check "throw with message"
  (try (throw (ex-info "boom" {}))
       (catch Exception e (ex-message e)))
  "boom")

;; ============================================================
;; Multiple catch clauses — order matters (most specific first)
;; ============================================================

(check "catch ExceptionInfo before Exception"
  (try (throw (ex-info "test" {}))
       (catch ExceptionInfo e "caught-info")
       (catch Exception e "caught-exception"))
  "caught-info")

(check "catch RuntimeException before Exception"
  (try (throw (ex-info "test" {}))
       (catch RuntimeException e "caught-runtime")
       (catch Exception e "caught-exception"))
  "caught-runtime")

(check "catch Throwable catches everything"
  (try (throw (ex-info "test" {}))
       (catch Throwable e "caught-throwable"))
  "caught-throwable")

;; ============================================================
;; try with no exception
;; ============================================================

(check "try with no exception returns body result"
  (try (+ 1 2) (catch Exception e "caught"))
  3)

(check "try body with multiple expressions"
  (try (println "hello") (+ 1 2) (catch Exception e "caught"))
  3)

;; ============================================================
;; Finally always runs
;; ============================================================

(check "finally runs on normal completion"
  (let [result (atom nil)]
    (try
      (reset! result :body)
      (finally (reset! result :finally)))
    @result)
  :finally)

(check "finally runs on exception"
  (let [result (atom nil)]
    (try
      (reset! result :body)
      (throw (ex-info "boom" {}))
      (catch Exception e (reset! result :caught))
      (finally (reset! result :finally)))
    @result)
  :finally)

(check "finally runs when exception uncaught"
  (let [result (atom nil)]
    (try
      (try
        (throw (ex-info "boom" {}))
        (finally (reset! result :finally)))
      (catch Exception e nil))
    @result)
  :finally)

;; ============================================================
;; Nested try
;; ============================================================

(check "nested try inner catch"
  (try
    (try
      (throw (ex-info "inner" {}))
      (catch ExceptionInfo e (ex-data e)))
    (catch Exception e "outer"))
  {})

(check "nested try outer catch"
  (try
    (try
      (throw (ex-info "inner" {}))
      (catch ArithmeticException e "inner-arith"))
    (catch ExceptionInfo e "outer-info"))
  "outer-info")

;; ============================================================
;; Custom exception types via derive + catch
;; ============================================================

(check "derive and catch custom exception type"
  (do
    (derive :my.app/my-error :clojure.lang/Exception)
    (try
      (throw (ex-info "custom" {:type :my.app/my-error}))
      (catch :my.app/my-error e "caught-custom")
      (catch Exception e "caught-exception")))
  "caught-custom")

(check "catch parent type catches derived exception"
  (do
    (derive :my.app/sub-error :my.app/my-error)
    (derive :my.app/my-error :clojure.lang/Exception)
    (try
      (throw (ex-info "sub" {:type :my.app/sub-error}))
      (catch :clojure.lang/Exception e "caught-parent")))
  "caught-parent")

;; ============================================================
;; ex-info with cause
;; ============================================================

(check "ex-info with cause"
  (let [cause (ex-info "root" {:a 1})
        wrapped (ex-info "wrapped" {:b 2} cause)]
    (= (ex-data (ex-cause wrapped)) {:a 1}))
  true)

(check "ex-cause of exception without cause is nil"
  (ex-cause (ex-info "no cause" {}))
  nil)

;; ============================================================
;; Division by zero → ArithmeticException
;; ============================================================

(check "division by zero throws ArithmeticException"
  (try (/ 1 0)
       (catch ArithmeticException e "caught")
       (catch Exception e "other"))
  "caught")

(check "division by zero ArithmeticException message"
  (try (/ 1 0)
       (catch ArithmeticException e (ex-message e)))
  "Divide by zero")

(check "division by zero catch Exception"
  (try (/ 1 0)
       (catch Exception e "caught"))
  "caught")

(check "division by float zero"
  (try (/ 1.0 0.0)
       (catch ArithmeticException e "caught")
       (catch Exception e "other"))
  "caught")

;; ============================================================
;; throw non-exception is TypeError
;; ============================================================


