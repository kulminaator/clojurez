;; Unified test entry point for ClojureZ
;; Run all shell-based tests in a single clojurez process.
;;
;; Usage:
;;   ./zig-out/bin/clojurez --timeout 120 tests/run_all.clj
;;
;; This runs all shell-based tests (subprocess, REPL, file execution, etc.)
;; that have been migrated from bash scripts to Clojure.
;;
;; To run all tests including Clojure-based suites, use run_tests.sh.

(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

;; ---- Load all shell test suites ----
;; Each file registers its suite(s) and tests but does NOT run them.

(load-file "tests/clj/test_shell_print_io.clj")
(load-file "tests/clj/test_shell_file_exec.clj")
(load-file "tests/clj/test_shell_repl.clj")
(load-file "tests/clj/test_shell_namespaces.clj")
(load-file "tests/clj/test_shell_samples.clj")
(load-file "tests/clj/test_shell_zig_io.clj")
(load-file "tests/clj/test_shell_debug.clj")

;; ---- Run all suites ----
;; Each test file calls (run-all) independently when loaded.
;; No additional run-all needed here.
