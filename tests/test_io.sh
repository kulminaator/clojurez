#!/bin/bash
# I/O: print, println, spit, slurp
source tests/helpers.sh

echo "=== I/O Tests ==="
# println prints to stdout and returns nil
# We can't easily test println output in this framework, so we just verify it doesn't error
# Instead test print which also works
run_test "print works" '(do (print "x") nil)' "xnil"

echo ""
echo "=== File I/O Tests (spit/slurp) ==="
# spit writes content to a file, returns nil
run_test "spit basic" '(spit "/tmp/clojure_vm_test_spit.txt" "hello world")' "nil"
# slurp reads file contents as string
run_test "slurp basic" '(slurp "/tmp/clojure_vm_test_spit.txt")' '"hello world"'
# spit with integer (converted to string)
run_test "spit integer" '(spit "/tmp/clojure_vm_test_spit2.txt" 42)' "nil"
run_test "slurp integer" '(slurp "/tmp/clojure_vm_test_spit2.txt")' '"42"'
# slurp and str operations
run_test "slurp with str" '(str (slurp "/tmp/clojure_vm_test_spit.txt"))' '"hello world"'
# slurp nonexistent file should error (we test it doesn't crash)
run_test_cmd "slurp nonexistent" 'timeout 10 ./main -e '"'"'(slurp "/tmp/clojure_vm_nonexistent_xyz.txt")'"'"' 2>&1 | head -1' 'error: FileError'

# Clean up temp files
rm -f /tmp/clojure_vm_test_spit.txt /tmp/clojure_vm_test_spit2.txt
