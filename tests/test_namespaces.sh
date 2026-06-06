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

# === REPL Namespace Tests ===

# REPL starts in user namespace (prompt shows user=>)
run_test_cmd "repl starts in user namespace" \
    "echo '(exit)' | ./zig-out/bin/clojurez --repl 2>&1 | grep 'user=>' | head -1 | tr -d '[:space:]'" \
    "user=>"

# REPL defn + function call (regression: used to crash)
run_test_cmd "repl defn and call" \
    "echo '(defn hello [] (println \"hello world\")) (hello) (exit)' | ./zig-out/bin/clojurez --repl 2>&1 | grep 'hello world' | head -1 | tr -d '[:space:]'" \
    "helloworld"

# REPL namespace switching with ns form
run_test_cmd "repl ns switching changes prompt" \
    "printf '(ns city)\n(exit)\n' | ./zig-out/bin/clojurez --repl 2>&1 | grep 'city=>' | head -1 | tr -d '[:space:]'" \
    "city=>"

# REPL def in user ns, access from another ns via qualified symbol
run_test_cmd "repl qualified symbol cross-namespace" \
    "printf '(def carrot 7)\n(ns city)\nuser/carrot\n(exit)\n' | ./zig-out/bin/clojurez --repl 2>&1 | grep 'city=> 7' | head -1 | tr -d '[:space:]'" \
    "city=>7"

# REPL defn in user ns, call from another ns via qualified symbol
run_test_cmd "repl qualified fn call cross-namespace" \
    "printf '(defn greet [n] (str \"Hello \" n))\n(ns other)\n(user/greet \"Bob\")\n(exit)\n' | ./zig-out/bin/clojurez --repl 2>&1 | grep 'Hello' | head -1 | tr -d '[:space:]'" \
    "other=>\"HelloBob\""

# REPL namespace isolation: def in one ns doesn't leak to another
run_test_cmd "repl namespace isolation" \
    "printf '(def x 100)\n(ns other)\n(def x 200)\n(ns user)\nx\n(exit)\n' | ./zig-out/bin/clojurez --repl 2>&1 | grep 'user=> 100' | head -1 | tr -d '[:space:]'" \
    "user=>100"
