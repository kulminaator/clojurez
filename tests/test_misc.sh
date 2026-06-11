#!/bin/bash
# Miscellaneous: Namespace, binding, file execution tests
source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10
TOOL_TIMEOUT="tests/timeout.sh"

echo "=== Namespace Tests ==="
run_test "ns declaration" '(ns my.core)' ""

echo ""
echo "=== Binding Tests ==="
run_test "binding single var" '(do (def x 10) (binding [x 20] x))' "20"
run_test "binding multiple vars" '(do (def a 1) (def b 2) (binding [a 10 b 20] (+ a b)))' "30"
run_test "binding value restored after scope" '(do (def x 10) (binding [x 20] x) x)' "10"
run_test "binding with expression" '(do (def x 0) (binding [x (+ 3 4)] x))' "7"
run_test "binding nested" '(do (def x 10) (binding [x 20] (binding [x 30] x)))' "30"

echo ""
echo "=== File Execution: No Eval Output ==="

# Test 1: lazy-seq should not evaluate more elements than consumed.
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

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM /tmp/cljvm_test_lazy_no_overeval.clj 2>&1) || {
    echo "FAIL: file-exec: lazy-seq no over-evaluation (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "count=4 result=6" ]; then
    echo "PASS: file-exec: lazy-seq no over-evaluation"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: file-exec: lazy-seq no over-evaluation"
    echo "  Expected: count=4 result=6"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

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

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM /tmp/cljvm_test_script_no_eval_output.clj 2>&1) || {
    echo "FAIL: file-exec: no eval output from def/defn (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "sum=30 product=200" ]; then
    echo "PASS: file-exec: no eval output from def/defn"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: file-exec: no eval output from def/defn"
    echo "  Expected: sum=30 product=200"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Cleanup test files
rm -f /tmp/cljvm_test_lazy_no_overeval.clj /tmp/cljvm_test_script_no_eval_output.clj
