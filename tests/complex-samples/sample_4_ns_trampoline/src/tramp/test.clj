(ns tramp.test)
;; Regression test: namespace loading with trampolining at top level.
;; Previously crashed with "access of union field 'value' while field 'trampoline' is active"
;; in eval_ns.zig loadNamespaceFile when a top-level form triggered trampolining.
(defn make-inc [x] (fn [] (+ x 1)))
(def result (trampoline make-inc 999))
