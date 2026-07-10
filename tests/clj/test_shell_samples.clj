;; Complex sample program tests migrated from test_samples.sh
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

(def-suite shell-samples)

;; ---- Hanoi Sample ----

(test "hanoi sample" (fn []
  (let [expected (clojure.string/trim (slurp "tests/complex-samples/sample_2_hanoi/expected_output.txt"))]
    (test-cmd "hanoi"
      ["tests/complex-samples/sample_2_hanoi/hanoi/core.clj"]
      {:expected-out expected
       :timeout 30}))))

;; ---- Fibonacci Sample ----

(test "fibonacci sample" (fn []
  (test-cmd "fibonacci"
    ["tests/complex-samples/sample_1_fibonacci/core.clj"]
    {:expected-out "(0 1 1 2 3 5 8 13 21 34)"
     :timeout 30})))

;; ---- Namespace Sample ----

(test "namespace sample" (fn []
  (let [expected (clojure.string/trim (slurp "tests/complex-samples/sample_3_namespaces/expected_output.txt"))]
    (test-main "ns-sample"
      "tests/complex-samples/sample_3_namespaces/src"
      "main"
      {:expected-out expected
       :timeout 30}))))

;; ---- GC Stress Sample ----
;; Original test uses "tail -1" to get only the last line

(test "gc stress sample" (fn []
  (let [expected (clojure.string/trim (slurp "tests/complex-samples/sample_4_gc_stress/expected_output.txt"))
        result (run-cmd ["tests/complex-samples/sample_4_gc_stress/core.clj"] {:timeout 30})
        out-lines (clojure.string/split-lines (:out result))
        last-line (clojure.string/trim (last out-lines))]
    (check "gc-stress/out" last-line expected))))

(run-all)
