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

# ============================================================
# REPL: Long input lines (>4096 bytes) should not be truncated
# ============================================================
echo ""
echo "=== REPL Long Input Tests ==="

# Test: REPL handles a single expression > 4096 bytes correctly
# Generate a (+ 1 1 1 ...) expression with 3000 ones = ~6000 chars
LONG_EXPR_4K=$(python3 -c "n=3000; print('(+ ' + ' '.join(['1']*n) + ')')")
LONG_EXPR_4K_LEN=${#LONG_EXPR_4K}
echo "  (long expr length: $LONG_EXPR_4K_LEN chars)"

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '%s\n(println :ok)\n(exit)\n' '$LONG_EXPR_4K' | $VM --repl 2>&1" ) || {
    echo "FAIL: repl long expression >4096 bytes (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
# Check that the long expression evaluated correctly AND the next expression ran
if echo "$result" | grep -q "3000" && echo "$result" | grep -q ":ok"; then
    echo "PASS: repl long expression >4096 bytes"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl long expression >4096 bytes"
    echo "  Expected output to contain: 3000 and :ok"
    echo "  Got:      $(echo "$result" | tr '\n' ' ' | head -c 200)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: REPL handles a single expression > 8192 bytes (2x buffer) correctly
LONG_EXPR_8K=$(python3 -c "n=6000; print('(+ ' + ' '.join(['1']*n) + ')')")
LONG_EXPR_8K_LEN=${#LONG_EXPR_8K}
echo "  (long expr length: $LONG_EXPR_8K_LEN chars)"

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '%s\n(println :ok)\n(exit)\n' '$LONG_EXPR_8K' | $VM --repl 2>&1" ) || {
    echo "FAIL: repl long expression >8192 bytes (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if echo "$result" | grep -q "6000" && echo "$result" | grep -q ":ok"; then
    echo "PASS: repl long expression >8192 bytes"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl long expression >8192 bytes"
    echo "  Expected output to contain: 6000 and :ok"
    echo "  Got:      $(echo "$result" | tr '\n' ' ' | head -c 200)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# ============================================================
# Regression: namespace parent chain must not cycle
# ============================================================
# When (ns clojure.core) is evaluated, clojure.core's parent must NOT
# be set to itself. If it is, env.get() loops forever on undefined symbols.
# This test references an undefined symbol from a child namespace —
# it must produce an error, NOT hang.

echo ""
echo "=== Namespace Parent Cycle Regression ==="

TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(ns mytest)\nundefined-symbol-xyz\n(println :done)\n(exit)\n' | $VM --repl 2>&1" ) || {
    # Timeout (exit 124) means the cycle still exists and caused a hang
    if [ $? -eq 124 ]; then
        echo "FAIL: ns parent cycle: undefined symbol caused hang (cycle not fixed)"
    else
        echo "FAIL: ns parent cycle: timeout or error"
    fi
    TEST_FAIL=$((TEST_FAIL + 1))
}
# Must see the error AND :done (proving execution continued past the error)
if echo "$result" | grep -qi "UndefinedSymbol\|Error" && echo "$result" | grep -q ":done"; then
    echo "PASS: ns parent cycle: undefined symbol gives error, no hang"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: ns parent cycle: expected error + :done in output"
    echo "  Got:      $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# ============================================================
# :refer semantics tests
# ============================================================
# Tests that :refer copies vars into the local namespace (original Clojure
# behavior), not just via parent chain. Supports :refer [x y], :refer :all,
# :exclude, :rename, and :as + :refer combined.

echo ""
echo "=== :refer Semantics Tests ==="

# Test: :refer [specific-symbols] copies only listed vars
# Uses REPL so errors are handled gracefully
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "
printf '(ns mylib)\n(defn alpha [] :alpha)\n(defn beta [] :beta)\n(ns myapp (:require [mylib :refer [alpha]]))\n(alpha)\n(println (mylib/beta))\nbeta\n(exit)\n' | $VM --repl 2>&1
") || {
    echo "FAIL: refer selective (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
# alpha should work (referred), mylib/beta should work (via alias), beta alone should error
if echo "$result" | grep -q ":alpha" && echo "$result" | grep -q ":beta" && echo "$result" | grep -qi "UndefinedSymbol"; then
    echo "PASS: refer selective [:refer [alpha]]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: refer selective [:refer [alpha]]"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: :refer :all copies all vars
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "
printf '(ns mylib2)\n(defn x [] :x)\n(defn y [] :y)\n(ns myapp2 (:require [mylib2 :refer :all]))\n(x)\n(y)\n(exit)\n' | $VM --repl 2>&1
") || {
    echo "FAIL: refer :all (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if echo "$result" | grep -q ":x" && echo "$result" | grep -q ":y"; then
    echo "PASS: refer :all"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: refer :all"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: :refer :all with :exclude
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "
printf '(ns mylib3)\n(defn a [] :a)\n(defn b [] :b)\n(ns myapp3 (:require [mylib3 :refer :all :exclude [b]]))\n(a)\nb\n(exit)\n' | $VM --repl 2>&1
") || {
    echo "FAIL: refer :all :exclude (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
# a should work, b should error (excluded)
if echo "$result" | grep -q ":a" && echo "$result" | grep -qi "UndefinedSymbol"; then
    echo "PASS: refer :all :exclude"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: refer :all :exclude"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: :as + :refer combined (alias for qualified, refer for unqualified)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "
printf '(ns mylib4)\n(defn hello [n] (str \"hi-\" n))\n(defn bye [n] (str \"bye-\" n))\n(ns myapp4 (:require [mylib4 :as m4 :refer [hello]]))\n(println (hello 1) (m4/bye 2))\n(exit)\n' | $VM --repl 2>&1
") || {
    echo "FAIL: refer + as combined (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if echo "$result" | grep -q "hi-1" && echo "$result" | grep -q "bye-2"; then
    echo "PASS: refer + as combined"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: refer + as combined"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
