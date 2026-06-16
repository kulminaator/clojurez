#!/bin/bash
# Namespace support tests (I/O dependent: stdin, -cp -m, REPL)
source tests/helpers.sh

VM="./zig-out/bin/clojurez"
TIMEOUT=10
TOOL_TIMEOUT="tests/timeout.sh"

echo "=== Namespace Tests ==="

# -m with classpath (sample_3_namespaces)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -cp tests/complex-samples/sample_3_namespaces/src -m main 2>&1) || {
    echo "FAIL: namespace sample with -m (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "Hello Clojure World" ]; then
    echo "PASS: namespace sample with -m"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: namespace sample with -m"
    echo "  Expected: Hello Clojure World"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# -cp flag error when -m used without -cp
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -m main 2>&1 | head -1) || {
    echo "FAIL: -m without -cp gives error (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "Error: -m requires -cp to be set" ]; then
    echo "PASS: -m without -cp gives error"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: -m without -cp gives error"
    echo "  Expected: Error: -m requires -cp to be set"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# -cp with multiple directories (colon-separated)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT $VM -cp tests/complex-samples/sample_3_namespaces/src:tests/complex-samples/sample_3_namespaces/src -m main 2>&1) || {
    echo "FAIL: -cp with multiple dirs (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "Hello Clojure World" ]; then
    echo "PASS: -cp with multiple dirs"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: -cp with multiple dirs"
    echo "  Expected: Hello Clojure World"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

echo ""
echo "=== REPL Namespace Tests ==="

# REPL starts in user namespace (prompt shows user=>)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "echo '(exit)' | $VM --repl 2>&1 | grep 'user=>' | head -1 | tr -d '[:space:]'") || {
    echo "FAIL: repl starts in user namespace (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "user=>" ]; then
    echo "PASS: repl starts in user namespace"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl starts in user namespace"
    echo "  Expected: user=>"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL defn + function call (regression: used to crash)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "echo '(defn hello [] (println \"hello world\")) (hello) (exit)' | $VM --repl 2>&1 | grep 'hello world' | head -1 | tr -d '[:space:]'") || {
    echo "FAIL: repl defn and call (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "helloworld" ]; then
    echo "PASS: repl defn and call"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl defn and call"
    echo "  Expected: helloworld"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL namespace switching with ns form
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(ns city)\n(exit)\n' | $VM --repl 2>&1 | grep 'city=>' | head -1 | tr -d '[:space:]'") || {
    echo "FAIL: repl ns switching changes prompt (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "city=>" ]; then
    echo "PASS: repl ns switching changes prompt"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl ns switching changes prompt"
    echo "  Expected: city=>"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL def in user ns, access from another ns via qualified symbol
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(def carrot 7)\n(ns city)\nuser/carrot\n(exit)\n' | $VM --repl 2>&1 | grep 'city=> 7' | head -1 | tr -d '[:space:]'") || {
    echo "FAIL: repl qualified symbol cross-namespace (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "city=>7" ]; then
    echo "PASS: repl qualified symbol cross-namespace"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl qualified symbol cross-namespace"
    echo "  Expected: city=>7"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL defn in user ns, call from another ns via qualified symbol
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(defn greet [n] (str \"Hello \" n))\n(ns other)\n(user/greet \"Bob\")\n(exit)\n' | $VM --repl 2>&1 | grep 'Hello' | head -1 | tr -d '[:space:]'") || {
    echo "FAIL: repl qualified fn call cross-namespace (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "other=>\"HelloBob\"" ]; then
    echo "PASS: repl qualified fn call cross-namespace"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl qualified fn call cross-namespace"
    echo "  Expected: other=>\"HelloBob\""
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL namespace isolation: def in one ns doesn't leak to another
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(def x 100)\n(ns other)\n(def x 200)\n(ns user)\nx\n(exit)\n' | $VM --repl 2>&1 | grep 'user=> 100' | head -1 | tr -d '[:space:]'") || {
    echo "FAIL: repl namespace isolation (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "user=>100" ]; then
    echo "PASS: repl namespace isolation"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl namespace isolation"
    echo "  Expected: user=>100"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Regression: REPL freeze after first expression (readSliceShort blocked on TTY)
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(+ 1 2)\n(+ 3 4)\n(+ 5 6)\n(exit)\n' | $VM --repl 2>&1 | grep -c 'user=>'") || {
    echo "FAIL: repl multiple expressions no freeze (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "4" ]; then
    echo "PASS: repl multiple expressions no freeze"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl multiple expressions no freeze"
    echo "  Expected: 4"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Regression: REPL with function definitions and calls across multiple lines
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(defn double [n] (* n 2))\n(double 21)\n(exit)\n' | $VM --repl 2>&1 | grep '42' | head -1 | tr -d '[:space:]'") || {
    echo "FAIL: repl defn then call no freeze (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "user=>42" ]; then
    echo "PASS: repl defn then call no freeze"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl defn then call no freeze"
    echo "  Expected: user=>42"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Regression: REPL handles EOF without explicit exit
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(+ 1 2)\n(+ 3 4)' | $VM --repl 2>&1 | grep -c 'user=>'") || {
    echo "FAIL: repl eof without exit (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "3" ]; then
    echo "PASS: repl eof without exit"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl eof without exit"
    echo "  Expected: 3"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL multiline string literal
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '\"hello\nworld\"\n(exit)\n' | $VM --repl 2>&1 | grep -c 'hello'" ) || {
    echo "FAIL: repl multiline string literal (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" -ge "1" ]; then
    echo "PASS: repl multiline string literal"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl multiline string literal"
    echo "  Expected: output containing 'hello'"
    echo "  Got:      $result matches"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL def with multiline string value
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(def msg \"line1\nline2\")\n(count msg)\n(exit)\n' | $VM --repl 2>&1 | grep '11' | head -1 | tr -d '[:space:]'" ) || {
    echo "FAIL: repl def multiline string (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "user=>11" ]; then
    echo "PASS: repl def multiline string"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl def multiline string"
    echo "  Expected: user=>11"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# REPL defn with multiline docstring
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '(defn greet\n\"Say hello\nto everyone\"\n[name] (str \"Hi \" name))\n(greet \"Zig\")\n(exit)\n' | $VM --repl 2>&1 | grep 'Hi Zig' | head -1 | tr -d '[:space:]'" ) || {
    echo "FAIL: repl defn multiline docstring (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "user=>\"HiZig\"" ]; then
    echo "PASS: repl defn multiline docstring"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl defn multiline docstring"
    echo "  Expected: user=>\"HiZig\""
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# Regression: REPL must not crash on map literals (double-free in deinit)
# Previously, returning a map from the REPL would crash with
# "panic: switch on corrupt value" due to double-deinit of map entries.
TEST_TOTAL=$((TEST_TOTAL + 1))
result=$($TOOL_TIMEOUT $TIMEOUT bash -c "printf '{:a 1 :b 2}\n[1 2 3]\n#{:x :y}\n(exit)\n' | $VM --repl 2>&1 | grep -c 'user=>'" ) || {
    echo "FAIL: repl map/vector/set no crash (timeout or error)"
    TEST_FAIL=$((TEST_FAIL + 1))
}
if [ "$result" = "4" ]; then
    echo "PASS: repl map/vector/set no crash"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "FAIL: repl map/vector/set no crash"
    echo "  Expected: 4 prompts"
    echo "  Got:      $result"
    TEST_FAIL=$((TEST_FAIL + 1))
fi
