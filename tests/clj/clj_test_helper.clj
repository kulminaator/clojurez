;; Test helper for Clojure VM test suites
;; Load with: (load-file "tests/clj/clj_test_helper.clj")
;; Provides: check, check-true, check-false, check-exception

;; Counters for pass/fail tracking
(def passes (atom 0))
(def failures (atom 0))

;; Check a single test: name, expression result, expected value
(defn check [name result expected]
  (if (= result expected)
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected=" expected " got=" result)))))

;; Check that a value is truthy
(defn check-true [name result]
  (if result
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected truthy, got=" result)))))

;; Check that a value is falsy
(defn check-false [name result]
  (if (not result)
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected falsy, got=" result)))))

;; Print summary at the end of a test suite
(defn print-summary []
  (println (str "SUMMARY: " @passes " passed, " @failures " failed")))
