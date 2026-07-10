;; Shell-based I/O tests migrated from test_core_library.sh and test_io.sh
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")
;; Tests that require subprocess stdout/stderr capture.

(def-suite shell-print-io)

;; ---- Print/Println Stdout Capture ----
;; (migrated from test_core_library.sh)

(test "print basic" (fn []
  (test-cmd "print-basic"
    ["-e" "(print \"hello\")"]
    {:expected-out "hello"})))

(test "println basic" (fn []
  (test-cmd "println-basic"
    ["-e" "(println \"hello\")"]
    {:expected-out "hello"})))

(test "zig.core/print" (fn []
  (test-cmd "zig-core-print"
    ["-e" "(zig.core/print 1 2 3)"]
    {:expected-out "123"})))

(test "zig.core/println" (fn []
  (test-cmd "zig-core-println"
    ["-e" "(zig.core/println 1 2 3)"]
    {:expected-out "1 2 3"})))

;; ---- I/O Error Tests ----
;; (migrated from test_io.sh)

(test "slurp nonexistent file" (fn []
  (test-cmd "slurp-nonexistent"
    ["-e" "(slurp \"/tmp/clojure_vm_nonexistent_xyz.txt\")"]
    {:expected-err-contains "FileError"})))

(run-all)
