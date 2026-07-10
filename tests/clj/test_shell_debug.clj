;; Debug output (CLJVM_DEBUG) tests migrated from test_misc.sh
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")
;;
;; NOTE: Tests requiring CLJVM_DEBUG env var are skipped because
;; the :env option is not yet implemented in zig.io/sh-execute.
;; These tests remain in test_misc.sh until :env support is added.

(def-suite shell-debug)

;; Test: No CLJVM_DEBUG should produce no debug output (no env var needed)
(test "debug output disabled by default" (fn []
  (let [result (run-cmd ["-e" "(+ 1 2)"] {:timeout 10})
        full-out (str (:out result) "\n" (:err result))]
    (check-false "debug-default-off" (clojure.string/includes? full-out "clojurez starting")))))

(run-all)
