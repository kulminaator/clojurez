#!/bin/bash
# Namespace support tests
source tests/helpers.sh

echo "=== Namespace Tests ==="

# Basic ns declaration
run_test "ns basic declaration" \
    "(ns my.ns)" \
    "nil"

# ns with require and as alias (using inline definitions)
run_test "ns with require and alias" \
    "(ns user) (ns lib.foo) (defn greet [] \"hi\") (ns my.app (:require [lib.foo :as f]))" \
    "nil"

# Qualified symbol resolution (via file)
run_test_cmd "qualified symbol via alias" \
    "echo '(ns user) (ns lib.foo) (defn greet [] \"hi\") (ns my.app (:require [lib.foo :as f])) (f/greet)' | ./zig-out/bin/clojurez /dev/stdin 2>&1 | tail -1" \
    "\"hi\""

# Multiple requires (via file)
run_test_cmd "multiple requires" \
    "echo '(ns user) (ns lib.a) (defn get-a [] \"A\") (ns lib.b) (defn get-b [] \"B\") (ns main (:require [lib.a :as a] [lib.b :as b])) (str (a/get-a) (b/get-b))' | ./zig-out/bin/clojurez /dev/stdin 2>&1 | tail -1" \
    "\"AB\""

# Namespace isolation: def in one ns doesn't affect another (via file)
run_test_cmd "namespace isolation" \
    "echo '(ns user) (ns ns1) (def x 1) (ns ns2) (def x 2) (ns ns1) x' | ./zig-out/bin/clojurez /dev/stdin 2>&1 | tail -1" \
    "1"

# -m with classpath (sample_3_namespaces)
run_test_cmd "namespace sample with -m" \
    "./zig-out/bin/clojurez -cp tests/complex-samples/sample_3_namespaces/src -m main" \
    "Hello Clojure World"

# -cp flag error when -m used without -cp
run_test_cmd "-m without -cp gives error" \
    "./zig-out/bin/clojurez -m main 2>&1 | head -1" \
    "Error: -m requires -cp to be set"

# -cp with multiple directories (colon-separated)
run_test_cmd "-cp with multiple dirs" \
    "./zig-out/bin/clojurez -cp tests/complex-samples/sample_3_namespaces/src:tests/complex-samples/sample_3_namespaces/src -m main" \
    "Hello Clojure World"
