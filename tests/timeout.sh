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

# Start the command in background
"$@" &
pid=$!

# Watchdog: poll every 0.1s, kill if still alive after timeout
(
    ticks=0
    while [ "$ticks" -lt "$max_ticks" ]; do
        # Check if the process is still running
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    # If we get here, either timed out or process finished
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

# Clean up the watchdog (suppress all output including job termination messages)
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" >/dev/null 2>&1 || true

# If killed by our watchdog (SIGTERM=143, SIGKILL=137), report as timeout
if [ "$exit_code" -eq 143 ] || [ "$exit_code" -eq 137 ]; then
    exit 124
fi

exit "$exit_code"
