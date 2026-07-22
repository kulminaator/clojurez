;; Shell tests for --generate-bytecode CLI option with -e input
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

(def-suite shell-bytecode-gen)

(test "generate-bytecode simple arithmetic" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn add [a b] (+ a b))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-simple/ADD" (clojure.string/includes? out "ADD"))
    (check-true "bcode-simple/LOAD_VAR" (clojure.string/includes? out "LOAD_VAR"))
    (check-true "bcode-simple/STOP" (clojure.string/includes? out "STOP")))))

(test "generate-bytecode with comparison" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn gt? [a b] (> a b))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-compare/GT" (clojure.string/includes? out "GT")))))

(test "generate-bytecode literal constants" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn get-42 [] 42)"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-constants/PUSH_CONST" (clojure.string/includes? out "PUSH_CONST"))
    (check-true "bcode-constants/42" (clojure.string/includes? out "42")))))

(test "generate-bytecode skips non-eligible functions" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn mixed [x] (println x))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-skip/Skipping" (clojure.string/includes? out "Skipping"))
    (check-true "bcode-skip/not supported" (clojure.string/includes? out "not supported")))))

(test "generate-bytecode anonymous fn" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(fn [x y] (* x y))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-anon/MUL" (clojure.string/includes? out "MUL"))
    (check-true "bcode-anon/Anonymous function" (clojure.string/includes? out "Anonymous function")))))

(test "generate-bytecode expression form" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(+ 1 2 3)"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-expr/ADD" (clojure.string/includes? out "ADD"))
    (check-true "bcode-expr/Expression" (clojure.string/includes? out "Expression")))))

(test "generate-bytecode from file" (fn []
  (let [result (run-cmd ["--generate-bytecode" "tests/complex-samples/sample_bc_eligible/core.clj"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-file/Function:" (clojure.string/includes? out "Function:"))
    (check-true "bcode-file/Disassembly" (clojure.string/includes? out "Disassembly"))
    (check-true "bcode-file/ADD" (clojure.string/includes? out "ADD"))
    (check-true "bcode-file/MUL" (clojure.string/includes? out "MUL")))))

(test "generate-bytecode file mixed eligible and non-eligible" (fn []
  (let [result (run-cmd ["--generate-bytecode" "tests/complex-samples/sample_bc_mixed/core.clj"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-mixed/Function:" (clojure.string/includes? out "Function:"))
    (check-true "bcode-mixed/ADD" (clojure.string/includes? out "ADD"))
    (check-true "bcode-mixed/GT" (clojure.string/includes? out "GT"))
    (check-true "bcode-mixed/Skipping" (clojure.string/includes? out "Skipping"))
    (check-true "bcode-mixed/not supported" (clojure.string/includes? out "not supported")))))

(test "generate-bytecode multi-arity function" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn foo ([] 0) ([x] x) ([x y] (+ x y)))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-multi/arity-0" (clojure.string/includes? out "arity 0"))
    (check-true "bcode-multi/arity-1" (clojure.string/includes? out "arity 1"))
    (check-true "bcode-multi/arity-2" (clojure.string/includes? out "arity 2")))))

(test "generate-bytecode if form" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn abs [x] (if (< x 0) (- 0 x) x))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-if/JUMP_IF_NIL" (clojure.string/includes? out "JUMP_IF_NIL"))
    (check-true "bcode-if/LT" (clojure.string/includes? out "LT"))
    (check-true "bcode-if/SUB" (clojure.string/includes? out "SUB")))))

(test "generate-bytecode loop/recur" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn factorial [n] (loop [i n acc 1] (if (<= i 1) acc (recur (- i 1) (* acc i)))))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-loop/LOOP_START" (clojure.string/includes? out "LOOP_START"))
    (check-true "bcode-loop/RECUR" (clojure.string/includes? out "RECUR"))
    (check-true "bcode-loop/MUL" (clojure.string/includes? out "MUL"))
    (check-true "bcode-loop/SUB" (clojure.string/includes? out "SUB")))))

(test "generate-bytecode let form" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn test [x] (let [y (+ x 1)] (* y y)))"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-let/STORE_VAR" (clojure.string/includes? out "STORE_VAR"))
    (check-true "bcode-let/LOAD_VAR" (clojure.string/includes? out "LOAD_VAR"))
    (check-true "bcode-let/MUL" (clojure.string/includes? out "MUL")))))

(test "generate-bytecode empty function" (fn []
  (let [result (run-cmd ["--generate-bytecode" "-e" "(defn empty-fn [] nil)"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-empty/PUSH_NIL" (clojure.string/includes? out "PUSH_NIL"))
    (check-true "bcode-empty/STOP" (clojure.string/includes? out "STOP")))))

(test "generate-bytecode with no input" (fn []
  (test-cmd "bcode-no-input" ["--generate-bytecode"]
    {:expected-err-contains "requires -e or a file"
     :expected-exit 1})))

(test "generate-bytecode with --help" (fn []
  (let [result (run-cmd ["--generate-bytecode" "--help"] {:timeout 10})
        out (:out result)]
    (check-true "bcode-help/Usage" (clojure.string/includes? out "Usage"))
    (check-true "bcode-help/generate-bytecode" (clojure.string/includes? out "--generate-bytecode")))))

(run-all)
