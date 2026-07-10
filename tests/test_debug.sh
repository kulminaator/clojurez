#!/bin/bash
# CLJVM_DEBUG environment variable tests (cannot be migrated to Clojure
# because io/sh :env option is not yet implemented)
VM="./zig-out/bin/clojurez"; TIMEOUT=10
_start() { _ds=$(date +%s); }
_elap() { local e=$(( $(date +%s) - _ds )); [ "$e" -ge 60 ] && echo "$((e/60))m$((e%60))s" || echo "${e}s"; }

echo "=== Debug Output (CLJVM_DEBUG) Tests ==="

# Test 1: CLJVM_DEBUG=1 produces startup/shutdown debug messages on stderr
BT=$((BT+1)); _start
r=$(CLJVM_DEBUG=1 $VM --timeout $TIMEOUT -e '(+ 1 2)' 2>&1) || { echo "FAIL: debug CLJVM_DEBUG=1 [$( _elap)] (error)"; BF=$((BF+1)); }
if echo "$r" | grep -q "clojurez starting" && echo "$r" | grep -q "clojurez shutting down"; then
    echo "PASS: debug CLJVM_DEBUG=1 shows startup/shutdown [$( _elap)]"; BP=$((BP+1))
else echo "FAIL: debug CLJVM_DEBUG=1 missing startup/shutdown [$( _elap)]"; BF=$((BF+1)); fi

# Test 2: CLJVM_DEBUG=startup shows only the startup category
BT=$((BT+1)); _start
r=$(CLJVM_DEBUG=startup $VM --timeout $TIMEOUT -e '(+ 1 2)' 2>&1) || { echo "FAIL: debug CLJVM_DEBUG=startup [$( _elap)] (error)"; BF=$((BF+1)); }
sc=$(echo "$r" | grep -c "clojurez")
if [ "$sc" -ge 2 ]; then
    echo "PASS: debug CLJVM_DEBUG=startup shows startup category [$( _elap)]"; BP=$((BP+1))
else echo "FAIL: debug CLJVM_DEBUG=startup missing messages [$( _elap)]"; BF=$((BF+1)); fi

# Test 3: CLJVM_DEBUG=gc should NOT show startup messages (different category)
BT=$((BT+1)); _start
r=$(CLJVM_DEBUG=gc $VM --timeout $TIMEOUT -e '(+ 1 2)' 2>&1) || { echo "FAIL: debug CLJVM_DEBUG=gc [$( _elap)] (error)"; BF=$((BF+1)); }
if ! echo "$r" | grep -q "clojurez starting"; then
    echo "PASS: debug CLJVM_DEBUG=gc filters out startup category [$( _elap)]"; BP=$((BP+1))
else echo "FAIL: debug CLJVM_DEBUG=gc should not show startup [$( _elap)]"; BF=$((BF+1)); fi

# Test 4: CLJVM_DEBUG=1 does not crash (regression for dangling pointer bug)
BT=$((BT+1)); _start
r=$(CLJVM_DEBUG=1 $VM --timeout $TIMEOUT -e '(doall (map (fn [x] (* x 2)) (list 1 2 3)))' 2>&1) || { echo "FAIL: debug CLJVM_DEBUG=1 crash regression [$( _elap)] (error)"; BF=$((BF+1)); }
if echo "$r" | grep -q "clojurez starting"; then
    echo "PASS: debug CLJVM_DEBUG=1 no crash on map (regression) [$( _elap)]"; BP=$((BP+1))
else echo "FAIL: debug CLJVM_DEBUG=1 crash regression [$( _elap)]"; BF=$((BF+1)); fi
