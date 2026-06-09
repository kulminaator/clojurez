#!/bin/bash
# Test runner for Clojure VM
# All tests must complete within 10 seconds each
#
# This script orchestrates the domain-based test suite in tests/
# Each test file sources tests/helpers.sh for shared infrastructure.

set -e

# Source helpers to get build_vm and counter variables
source tests/helpers.sh

# Build the VM once (copies core.clj into zig package for @embedFile)
# Skip with NOBUILD=1 to just run tests against existing build
if [ "$NOBUILD" != "1" ]; then
    build_vm
else
    echo "Skipping build (NOBUILD=1)."
    echo ""
fi

# Run all domain-based test suites
# We source each file so counters accumulate in the same shell
echo "Running test suites..."
echo ""

source tests/test_basic_types.sh
echo ""

source tests/test_lists_sequences.sh
echo ""

source tests/test_special_forms.sh
echo ""

source tests/test_functions.sh
echo ""

source tests/test_macros.sh
echo ""

source tests/test_maps.sh
echo ""

source tests/test_sets.sh
echo ""

source tests/test_queues.sh
echo ""

source tests/test_collections.sh
echo ""

source tests/test_thread_macros.sh
echo ""

source tests/test_sequence_functions.sh
echo ""

source tests/test_destructuring.sh
echo ""

source tests/test_core_library.sh
echo ""

source tests/test_core_library_new.sh
echo ""

source tests/test_new_core_functions.sh
echo ""

source tests/test_io.sh
echo ""

source tests/test_utf8.sh
echo ""

source tests/test_lazy_seq.sh
echo ""

source tests/test_samples.sh
echo ""

source tests/test_misc.sh
echo ""

source tests/test_condition_forms.sh
echo ""

source tests/test_namespaces.sh
echo ""

source tests/test_big_numbers.sh

echo ""
echo "========================================"
echo "=== Test Summary ==="
echo "Total: $TEST_TOTAL, Passed: $TEST_PASS, Failed: $TEST_FAIL"
echo "========================================"

if [ $TEST_FAIL -gt 0 ]; then
    exit 1
fi
