;; Test runner framework for ClojureZ
;; Provides: def-suite, test, check, check-true, check-false, check-exception,
;;           run-suite, run-all, print-summary
;;
;; Usage:
;;   (load-file "tests/clj/test_runner.clj")
;;
;;   (def-suite arithmetic)
;;   (test "addition" (fn []
;;     (check "1+2=3" (+ 1 2) 3)
;;     (check "1+2+3=6" (+ 1 2 3) 6)))
;;
;;   (run-all)

(def suites (atom []))
(def passes (atom 0))
(def failures (atom 0))

;; ============================================================
;; Assertions
;; ============================================================

(defn check [name result expected]
  "Check that result equals expected."
  (if (= result expected)
    (swap! passes inc)
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected=" expected " got=" result)))))

(defn check-true [name result]
  "Check that result is truthy."
  (if result
    (swap! passes inc)
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected truthy, got=" result)))))

(defn check-false [name result]
  "Check that result is falsy."
  (if (not result)
    (swap! passes inc)
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected falsy, got=" result)))))

(defn check-exception [name f expected-type]
  "Check that calling f throws an exception containing expected-type in the message."
  (try
    (f)
    (swap! failures inc)
    (println (str "FAIL: " name " expected exception, none thrown"))
    (catch Exception e
      (let [msg (ex-message e)]
        (if (and msg (string? msg) (clojure.string/includes? msg (str expected-type)))
          (swap! passes inc)
          (do (swap! failures inc)
              (println (str "FAIL: " name " expected " expected-type " in message, got=" msg))))))))

;; ============================================================
;; Suite definition (macro — no ~@ needed)
;; ============================================================

(defmacro def-suite [name]
  "Define a test suite. name is a symbol (no quotes)."
  (let [suite {:name (str name) :tests []}]
    `(do
       (swap! suites conj ~suite)
       (def ~name ~suite))))

;; ============================================================
;; Test registration (function, not macro — avoids ~@ in maps)
;; ============================================================

(defn test [name body-fn]
  "Register a test case in the current (last) suite.

   name - string test name
   body-fn - zero-arg function that runs checks"
  (let [suites-snap @suites
        suite (last suites-snap)]
    (if (nil? suite)
      (println "ERROR: no active suite — call (def-suite ...) first")
      (let [idx (dec (count suites-snap))
            tests (:tests suite)
            test-id (str (:name suite) "/" name)
            new-test {:id test-id :name name :fn body-fn}
            updated-suite (assoc suite :tests (conj tests new-test))]
        (swap! suites (fn [all] (assoc all idx updated-suite)))))))

;; ============================================================
;; Running tests
;; ============================================================

(defn- run-test [test-map]
  "Run a single test, returning elapsed milliseconds."
  (let [start-ms (/ (nano-time) 1000000)
        _ ((:fn test-map))
        end-ms (/ (nano-time) 1000000)]
    (- end-ms start-ms)))

(defn run-suite [suite-name]
  "Run a specific suite by name (symbol). Returns the suite map."
  (let [suites-snap @suites
        suite (first (filter #(= (:name %) (str suite-name)) suites-snap))]
    (if (nil? suite)
      (do (println (str "ERROR: Suite '" (str suite-name) "' not found"))
          nil)
      (do (println (str "=== Suite: " (:name suite) " ==="))
          (doseq [t (:tests suite)]
            (run-test t))
          suite))))

(defn run-all []
  "Run all registered suites. Returns {:pass N :fail N :total N}."
  (reset! passes 0)
  (reset! failures 0)
  (doseq [suite @suites]
    (println (str "=== Suite: " (:name suite) " ==="))
    (doseq [t (:tests suite)]
      (run-test t)))
  (print-summary)
  {:pass @passes :fail @failures :total (+ @passes @failures)})

(defn print-summary []
  "Print pass/fail summary."
  (println (str "SUMMARY: " @passes " passed, " @failures " failed")))
