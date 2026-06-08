#!/bin/bash
# Miscellaneous: Namespace, and/or, quasiquote, set!, binding, var, deref
source tests/helpers.sh

echo "=== Namespace Tests ==="
run_test "ns declaration" '(ns my.core)' "nil"

echo ""
echo "=== Binding Tests ==="
run_test "binding single var" '(do (def x 10) (binding [x 20] x))' "20"
run_test "binding multiple vars" '(do (def a 1) (def b 2) (binding [a 10 b 20] (+ a b)))' "30"
run_test "binding value restored after scope" '(do (def x 10) (binding [x 20] x) x)' "10"
run_test "binding with expression" '(do (def x 0) (binding [x (+ 3 4)] x))' "7"
run_test "binding nested" '(do (def x 10) (binding [x 20] (binding [x 30] x)))' "30"

echo ""
echo "=== File Execution: No Eval Output ==="
# When running a script file (clojure file.clj), only explicit println
# output should appear — not the results of def, defn, or other form
# evaluations. Piped stdin (cat file | clojure) runs as REPL and DOES
# print results — that is a separate mode.

# Test 1: lazy-seq should not evaluate more elements than consumed.
# Uses an atom to track evaluation count instead of println side-effects.
# take 3 forces exactly 3 realizations: 1 initial call + 3 forced = 4.
# If more than 3 elements are realized, the counter will be > 4.
cat > /tmp/cljvm_test_lazy_no_overeval.clj << 'CLJEOF'
(def counter (atom 0))

(defn counting-lazy-seq [n]
  (do (swap! counter inc)
      (if (> n 100)
        nil
        (lazy-seq
          (cons n (counting-lazy-seq (inc n)))))))

(def result (reduce + (take 3 (counting-lazy-seq 1))))

(println (str "count=" @counter " result=" result))
CLJEOF

run_test_cmd_full "file-exec: lazy-seq no over-evaluation" \
    "timeout $TIMEOUT $VM /tmp/cljvm_test_lazy_no_overeval.clj 2>&1" \
    "count=4 result=6"

# Test 2: multiple def/defn forms should not produce output when running
# a script file — only the final println should appear.
cat > /tmp/cljvm_test_script_no_eval_output.clj << 'CLJEOF'
(defn add [a b]
  (+ a b))

(defn multiply [a b]
  (* a b))

(def x 10)
(def y 20)
(def sum (add x y))
(def product (multiply x y))

(println (str "sum=" sum " product=" product))
CLJEOF

run_test_cmd_full "file-exec: no eval output from def/defn" \
    "timeout $TIMEOUT $VM /tmp/cljvm_test_script_no_eval_output.clj 2>&1" \
    "sum=30 product=200"

# Cleanup test files
rm -f /tmp/cljvm_test_lazy_no_overeval.clj /tmp/cljvm_test_script_no_eval_output.clj
