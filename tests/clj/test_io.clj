;; I/O: print, println, spit, slurp
(load-file "tests/clj/clj_test_helper.clj")

;; ---- I/O Tests ----
;; print works (we test that it doesn't error, result is nil)
(check "print works" (do (print "x") nil) nil)

;; ---- File I/O Tests (spit/slurp) ----
(check "spit basic" (spit "/tmp/clojure_vm_test_spit.txt" "hello world") nil)
(check "slurp basic" (slurp "/tmp/clojure_vm_test_spit.txt") "hello world")
(check "spit integer" (spit "/tmp/clojure_vm_test_spit2.txt" 42) nil)
(check "slurp integer" (slurp "/tmp/clojure_vm_test_spit2.txt") "42")
(check "slurp with str" (str (slurp "/tmp/clojure_vm_test_spit.txt")) "hello world")

(print-summary)
