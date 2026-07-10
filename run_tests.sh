#!/bin/bash
# ClojureZ test runner
# Usage: ./run_tests.sh [test_name]  |  NOBUILD=1 ./run_tests.sh
set -e; VM="./zig-out/bin/clojurez"; TO=15

# Directory for per-test log files (useful for CI debugging)
LOG_DIR=".test_logs"
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

run_clj() {
    local f="$1" n=$(basename "$1" .clj) to=$TO s=$(date +%s) rc=0
    [ "$n" = "test_clojure_string" ] && to=30
    local logfile="$LOG_DIR/${n}.log"

    # Pipe through cat to force line-buffered stdout (direct file redirect
    # causes block buffering which can garble output). Capture VM exit code
    # via PIPESTATUS[0] (cat's exit is PIPESTATUS[1], always 0).
    "$VM" --timeout "$to" "$f" 2>&1 | cat >"$logfile"
    rc=${PIPESTATUS[0]}
    local out
    out=$(cat "$logfile")
    local d=$(( $(date +%s) - s ))

    if [ "$rc" -eq 124 ]; then
        echo "TIMEOUT: $n (${to}s) [${d}s]"
        echo "  --- Last 60 lines of output (full log: $logfile) ---"
        tail -60 "$logfile"
        echo "  --- end of output ---"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "CRASH: $n (exit $rc) [${d}s]"
        echo "  --- Full output (log: $logfile) ---"
        cat "$logfile"
        echo "  --- end of output ---"
        return 1
    fi
    local fc
    fc=$(echo "$out" | grep -c "^FAIL:" || true)
    if [ "$fc" -gt 0 ]; then
        echo "FAIL: $n ($fc failure(s)) [${d}s]"
        echo "  --- FAIL lines (full log: $logfile) ---"
        echo "$out" | grep "^FAIL:"
        echo "  --- end of FAIL lines ---"
        return 1
    fi
    echo "PASS: $n [${d}s]"
    return 0
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
local_log="$LOG_DIR/shell_suites.log"
SRC=0
"$VM" --timeout 120 tests/run_all.clj 2>&1 | cat >"$local_log"
SRC=${PIPESTATUS[0]}
SO=$(cat "$local_log")
echo "$SO"; SF=$(echo "$SO"|grep "SUMMARY:"|awk '{s+=$4} END {print s+0}')
T=$((T+1)); [ "${SRC:-0}" -eq 0 ] && [ "$SF" -eq 0 ] && P=$((P+1)) || { F=$((F+1));
    if [ "${SRC:-0}" -eq 124 ]; then
        echo "TIMEOUT: shell_suites (120s)"
        echo "  --- Last 60 lines of output (full log: $local_log) ---"
        tail -60 "$local_log"
        echo "  --- end of output ---"
    elif [ "${SRC:-0}" -ne 0 ]; then
        echo "CRASH: shell_suites (exit ${SRC:-0})"
        echo "  --- Full output (log: $local_log) ---"
        cat "$local_log"
        echo "  --- end of output ---"
    fi
}
echo ""

echo "=== Bash Debug Tests ==="; BP=0; BF=0; BT=0
source tests/test_debug.sh
echo "Bash debug tests: $BP passed, $BF failed (out of $BT)"; echo ""

GT=$((T+BT)); GP=$((P+BP)); GF=$((F+BF))
[ "$GF" -eq 0 ] && echo "ALL TESTS PASSED: $GP/$GT" || echo "RESULT: $GP passed, $GF failed (out of $GT)"
[ "$GF" -eq 0 ] && exit 0 || exit 1
