#!/bin/bash
# Queues: literals, conj, pop, peek, queue?, count
source tests/helpers.sh

echo "=== Queue Tests ==="
run_test "queue literal" '#queue(1 2 3)' "#queue(1 2 3)"
run_test "queue empty" '#queue()' "#queue()"
run_test "conj queue" "(conj #queue(1 2) 3)" "#queue(1 2 3)"
run_test "pop queue" "(pop #queue(1 2 3))" "#queue(2 3)"
run_test "peek queue" "(peek #queue(1 2 3))" "1"
run_test "queue?" "(queue? #queue(1))" "true"
run_test "count queue" "(count #queue(1 2 3))" "3"
