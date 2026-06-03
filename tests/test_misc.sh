#!/bin/bash
# Miscellaneous: Namespace, and/or, quasiquote, set!, binding, var, deref
source tests/helpers.sh

echo "=== Namespace Tests ==="
run_test "ns declaration" '(ns my.core)' "nil"
