;; I/O: print, println, spit, slurp
(load-file "tests/clj/clj_test_helper.clj")

;; ---- I/O Tests ----
;; print works (we test that it doesn't error, result is nil)
(check "print works" (do (print "x") nil) nil)

;; ---- File I/O Tests (spit/slurp) ----
;; Use zig.core/temp-dir for cross-platform compatibility (works on Linux and Windows)
(def tmp-file (str (zig.core/temp-dir) "/clojure_vm_test_spit.txt"))
(def tmp-file2 (str (zig.core/temp-dir) "/clojure_vm_test_spit2.txt"))

(check "spit basic" (spit tmp-file "hello world") nil)
(check "slurp basic" (slurp tmp-file) "hello world")
(check "spit integer" (spit tmp-file2 42) nil)
(check "slurp integer" (slurp tmp-file2) "42")
(check "slurp with str" (str (slurp tmp-file)) "hello world")

(print-summary)
