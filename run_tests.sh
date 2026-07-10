#!/bin/bash
# ClojureZ test runner
# Usage: ./run_tests.sh [test_name]  |  NOBUILD=1 ./run_tests.sh
set -e; VM="./zig-out/bin/clojurez"; TO=15
[ "$NOBUILD" != "1" ] && { echo "Building VM..."; zig build 2>&1; echo ""; }

run_clj() {
    local f="$1" n=$(basename "$1" .clj) to=$TO s=$(date +%s) out rc=0
    [ "$n" = "test_clojure_string" ] && to=30
    out=$("$VM" --timeout "$to" "$f" 2>&1) || rc=$?; local d=$(( $(date +%s) - s ))
    if [ "$rc" -eq 124 ]; then echo "TIMEOUT: $n (${to}s) [${d}s]"; return 1; fi
    if [ "$rc" -ne 0 ]; then echo "CRASH: $n (exit $rc) [${d}s]"; echo "$out"|head -30; return 1; fi
    local fc=$(echo "$out"|grep -c "^FAIL:" || true)
    [ "$fc" -gt 0 ] && { echo "FAIL: $n ($fc failure(s)) [${d}s]"; return 1; }
    echo "PASS: $n [${d}s]"; return 0
}

P=0; F=0; T=0; echo "=== Clojure Test Suites ==="
if [ $# -gt 0 ]; then
    for name in "$@"; do
        f="tests/clj/test_${name}.clj"; [ -f "$f" ] || { echo "Error: not found: $f"; exit 1; }
        T=$((T+1)); run_clj "$f" && P=$((P+1)) || F=$((F+1))
    done; echo "Clojure suites: $P passed, $F failed (out of $T)"
    [ "$F" -eq 0 ] && exit 0 || exit 1
fi
f="tests/clj/test_smoke.clj"
[ -f "$f" ] && { T=$((T+1)); run_clj "$f" && P=$((P+1)) || { F=$((F+1)); echo "ABORT: Smoke failed."; exit 1; }; }
for f in tests/clj/test_*.clj; do
    [ -f "$f" ] || continue; n=$(basename "$f" .clj)
    case "$n" in test_smoke|test_runner|shell_*) continue ;; esac
    T=$((T+1)); run_clj "$f" && P=$((P+1)) || F=$((F+1))
done
echo "Clojure suites: $P passed, $F failed (out of $T)"; echo ""

echo "=== Clojure Shell Test Suites ==="
SO=$("$VM" --timeout 120 tests/run_all.clj 2>&1) || SRC=$?
echo "$SO"; SF=$(echo "$SO"|grep "SUMMARY:"|awk '{s+=$4} END {print s+0}')
T=$((T+1)); [ "${SRC:-0}" -eq 0 ] && [ "$SF" -eq 0 ] && P=$((P+1)) || F=$((F+1))
echo ""

echo "=== Bash Debug Tests ==="; BP=0; BF=0; BT=0
source tests/test_debug.sh
echo "Bash debug tests: $BP passed, $BF failed (out of $BT)"; echo ""

GT=$((T+BT)); GP=$((P+BP)); GF=$((F+BF))
[ "$GF" -eq 0 ] && echo "ALL TESTS PASSED: $GP/$GT" || echo "RESULT: $GP passed, $GF failed (out of $GT)"
[ "$GF" -eq 0 ] && exit 0 || exit 1
