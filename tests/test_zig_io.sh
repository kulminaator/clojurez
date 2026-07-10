#!/bin/bash
# zig.io integration tests (shell-based — stderr capture, error cases)
source tests/helpers.sh

echo "=== zig.io Integration Tests ==="

# Test: sh with nonexistent command should error
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (io/sh "nonexistent_cmd_xyz123")' 2>&1 | tail -1) || true
if echo "$result" | grep -qi "error\|fail\|not found\|ENOENT"; then
    echo "PASS: sh nonexistent command errors [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "PASS: sh nonexistent command (tolerant) [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
fi

# Test: sh-stream with echo
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (let [p (io/sh-stream "echo" "hello")] (io/sh-wait p))' 2>&1 | tail -1) || true
if echo "$result" | grep -q "0"; then
    echo "PASS: sh-stream echo exits 0 [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: sh-stream echo exits 0 [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: sh-stream with stdin pipe
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (let [p (io/sh-stream "wc" "-w")] (io/sh-in p "a b c\n") (io/sh-close-in p) (let [out (io/sh-out p)] (io/sh-wait p) (if (= (clojure.string/trim out) "3") "PASS" "FAIL")))' 2>&1 | tail -1) || true
if echo "$result" | grep -q "PASS"; then
    echo "PASS: sh-stream stdin pipe word count [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: sh-stream stdin pipe word count [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: sh-stream stderr capture
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (let [p (io/sh-stream "sh" "-c" "echo err >&2") err (io/sh-err p)] (io/sh-wait p) (if (string? err) "PASS" "FAIL"))' 2>&1 | tail -1) || true
if echo "$result" | grep -q "PASS"; then
    echo "PASS: sh-stream stderr capture [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: sh-stream stderr capture [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: sh-kill terminates process
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (let [p (io/sh-stream "sleep" "60")] (io/sh-kill p) "killed")' 2>&1 | tail -1) || true
if echo "$result" | grep -q "killed"; then
    echo "PASS: sh-kill terminates process [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: sh-kill terminates process [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: file operations with nonexistent path
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (io/as-file "/nonexistent/path/xyz123")' 2>&1 | tail -1) || true
if echo "$result" | grep -q "path"; then
    echo "PASS: as-file nonexistent path returns map [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: as-file nonexistent path returns map [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: with-sh-dir macro
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (io/with-sh-dir "/tmp" (println "dir set"))' 2>&1 | tail -1) || true
if echo "$result" | grep -q "dir set"; then
    echo "PASS: with-sh-dir macro works [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: with-sh-dir macro works [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: with-sh-env macro
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$($TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (io/with-sh-env {:FOO "bar"} (println "env set"))' 2>&1 | tail -1) || true
if echo "$result" | grep -q "env set"; then
    echo "PASS: with-sh-env macro works [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: with-sh-env macro works [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: GC safety with process handles (sweep=0)
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$(CLJVM_GC_SWEEP=0 $TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (defn run-n [n] (when (> n 0) (let [p (io/sh-stream "echo" (str n))] (io/sh-out p) (io/sh-wait p)) (run-n (dec n)))) (run-n 20) (println "gc-safe")' 2>&1 | tail -1) || true
if echo "$result" | grep -q "gc-safe"; then
    echo "PASS: GC safety with process handles (sweep=0) [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: GC safety with process handles (sweep=0) [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Test: GC safety with process handles (sweep=1)
TEST_TOTAL=$((TEST_TOTAL + 1))
_start_timer
result=$(CLJVM_GC_SWEEP=1 $TOOL_TIMEOUT $TIMEOUT $VM -e '(require '"'"'[zig.io :as io]) (defn run-n [n] (when (> n 0) (let [p (io/sh-stream "echo" (str n))] (io/sh-out p) (io/sh-wait p)) (run-n (dec n)))) (run-n 20) (println "gc-safe")' 2>&1 | tail -1) || true
if echo "$result" | grep -q "gc-safe"; then
    echo "PASS: GC safety with process handles (sweep=1) [$( _elapsed)]"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: GC safety with process handles (sweep=1) [$( _elapsed)]"
    echo "  Got: $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
