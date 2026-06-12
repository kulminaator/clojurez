#!/usr/bin/env bash
# Cross-platform timeout that kills the command after N seconds.
# Works on Linux and macOS.
#
# Usage: timeout.sh <seconds> <command> [args...]
# Exit codes:
#   0     - command completed successfully within timeout
#   124   - command timed out (killed)
#   other - command's own exit code

set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <seconds> <command> [args...]" >&2
    exit 1
fi

seconds="$1"
shift

# Convert to tenths of seconds for the polling loop
max_ticks=$((seconds * 10))

# Flag file: watchdog runs while it exists, exits cleanly when removed.
# This avoids killing the watchdog subshell which on macOS causes bash
# to print "Terminated: 15" to stderr — a message that leaks into
# 2>&1 captures and corrupts test output.
FLAG_FILE=$(mktemp /tmp/cljvm_timeout.XXXXXX)
trap 'rm -f "$FLAG_FILE"' EXIT

# Start the command in background
"$@" &
pid=$!

# Watchdog: poll every 0.1s, kill target if still alive after timeout.
# Exits cleanly when the flag file is removed (no kill needed).
(
    ticks=0
    while [ "$ticks" -lt "$max_ticks" ] && [ -f "$FLAG_FILE" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
    fi
) &
watchdog=$!

# Wait for the command to finish
wait "$pid" 2>/dev/null
exit_code=$?

# Remove flag file so watchdog loop condition fails and it exits cleanly.
# Do this BEFORE wait so the watchdog has time to notice and exit.
rm -f "$FLAG_FILE"
wait "$watchdog" 2>/dev/null || true

# If killed by our watchdog (SIGTERM=143, SIGKILL=137), report as timeout
if [ "$exit_code" -eq 143 ] || [ "$exit_code" -eq 137 ]; then
    exit 124
fi

exit "$exit_code"
