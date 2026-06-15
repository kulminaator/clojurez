#!/bin/bash
# Miscellaneous: Namespace, binding, file execution tests
source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10
TOOL_TIMEOUT="tests/timeout.sh"

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

# ============================================================
# CLJVM_DEBUG environment variable tests
# Verifies that the debug logging infrastructure works end-to-end.
# ============================================================

echo ""
echo "=== Debug Output (CLJVM_DEBUG) Tests ==="

# Test 1: CLJVM_DEBUG=1 produces startup/shutdown debug messages on stderr
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$(CLJVM_DEBUG=1 $TOOL_TIMEOUT $TIMEOUT $VM -e '(+ 1 2)' 2>&1) || {
    echo "FAIL: debug output CLJVM_DEBUG=1 (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if echo "$result" | grep -q "clojurez starting" && echo "$result" | grep -q "clojurez shutting down"; then
    echo "PASS: debug output CLJVM_DEBUG=1 shows startup/shutdown"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: debug output CLJVM_DEBUG=1 missing startup/shutdown"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test 2: CLJVM_DEBUG=startup shows only the startup category
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$(CLJVM_DEBUG=startup $TOOL_TIMEOUT $TIMEOUT $VM -e '(+ 1 2)' 2>&1) || {
    echo "FAIL: debug output CLJVM_DEBUG=startup (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
# Should see both startup messages since both use the "startup" category
startup_count=$(echo "$result" | grep -c "clojurez")
if [ "$startup_count" -ge 2 ]; then
    echo "PASS: debug output CLJVM_DEBUG=startup shows startup category"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: debug output CLJVM_DEBUG=startup missing messages"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test 3: CLJVM_DEBUG=gc should NOT show startup messages (different category)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$(CLJVM_DEBUG=gc $TOOL_TIMEOUT $TIMEOUT $VM -e '(+ 1 2)' 2>&1) || {
    echo "FAIL: debug output CLJVM_DEBUG=gc (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if ! echo "$result" | grep -q "clojurez starting"; then
    echo "PASS: debug output CLJVM_DEBUG=gc filters out startup category"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: debug output CLJVM_DEBUG=gc should not show startup messages"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test 4: No CLJVM_DEBUG should produce no debug output
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$(unset CLJVM_DEBUG && $TOOL_TIMEOUT $TIMEOUT $VM -e '(+ 1 2)' 2>&1) || {
    echo "FAIL: debug output no env var (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if ! echo "$result" | grep -q "clojurez starting"; then
    echo "PASS: debug output disabled by default (no CLJVM_DEBUG)"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: debug output should be disabled without CLJVM_DEBUG"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test 5: CLJVM_DEBUG=1 does not crash (regression for the dangling pointer bug)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$(CLJVM_DEBUG=1 $TOOL_TIMEOUT $TIMEOUT $VM -e '(doall (map (fn [x] (* x 2)) (list 1 2 3)))' 2>&1) || {
    echo "FAIL: debug output CLJVM_DEBUG=1 crash regression (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if echo "$result" | grep -q "clojurez starting"; then
    echo "PASS: debug output CLJVM_DEBUG=1 no crash on map (regression)"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: debug output CLJVM_DEBUG=1 crash regression"
    echo "  Got: $(echo "$result" | tr '\n' ' ' | head -c 300)"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
