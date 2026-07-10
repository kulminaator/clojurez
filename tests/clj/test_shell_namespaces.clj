;; Namespace support tests migrated from test_namespaces.sh
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")
(require '[zig.io :as io])

(def-suite shell-namespaces)

;; ---- -m with classpath ----

(test "namespace sample with -m" (fn []
  (test-main "ns-sample-main"
    "tests/complex-samples/sample_3_namespaces/src"
    "main"
    {:expected-out "Hello Clojure World"})))

(test "-m without -cp gives error" (fn []
  (test-cmd "m-without-cp"
    ["-m" "main"]
    {:expected-err-contains "Error: -m requires -cp to be set"})))

(test "-cp with multiple dirs" (fn []
  (test-main "cp-multiple-dirs"
    "tests/complex-samples/sample_3_namespaces/src:tests/complex-samples/sample_3_namespaces/src"
    "main"
    {:expected-out "Hello Clojure World"})))

;; ---- Namespace Introspection Functions ----

(test "find-ns nonexistent returns nil" (fn []
  (test-cmd "find-ns-nonexistent"
    ["-e" "(find-ns 'nonexistent.ns.xyz)"]
    {:expected-out ""})))

(test "find-ns clojure.core :name" (fn []
  (test-cmd "find-ns-core"
    ["-e" "(get (find-ns 'clojure.core) :name)"]
    {:expected-out "clojure.core"})))

(test "create-ns returns correct name" (fn []
  (test-cmd "create-ns"
    ["-e" "(get (create-ns 'shell.test.ns) :name)"]
    {:expected-out "shell.test.ns"})))

(test "all-ns count >= 2" (fn []
  (let [result (run-cmd ["-e" "(count (all-ns))"] {:timeout 10})
        count-str (clojure.string/trim (:out result))
        count-val (try (read-string count-str) (catch Exception _ -1))]
    (check-true "all-ns-count" (>= count-val 2)))))

(test "the-ns nonexistent errors" (fn []
  (test-cmd "the-ns-nonexistent"
    ["-e" "(the-ns 'nonexistent.ns.xyz)"]
    {:expected-err-contains "UndefinedNamespace"
     :expected-exit-nonzero true})))

(test "ns-name returns symbol" (fn []
  (test-cmd "ns-name"
    ["-e" "(ns-name 'clojure.core)"]
    {:expected-out "clojure.core"})))

(test "ns-name with ns map arg" (fn []
  (test-cmd "ns-name-map-arg"
    ["-e" "(ns-name (find-ns 'user))"]
    {:expected-out "user"})))

(test "find-ns with ns map arg" (fn []
  (test-cmd "find-ns-map-arg"
    ["-e" "(get (find-ns (find-ns 'user)) :name)"]
    {:expected-out "user"})))

;; ---- requiring-resolve ----

(test "requiring-resolve resolves qualified symbol" (fn []
  (test-cmd "requiring-resolve-qualified"
    ["-e" "((requiring-resolve 'clojure.string/upper-case) \"hello\")"]
    {:expected-out "\"HELLO\""})))

(test "requiring-resolve already-resolved symbol" (fn []
  (test-cmd "requiring-resolve-resolved"
    ["-e" "(requiring-resolve 'clojure.string/lower-case)"]
    {:expected-out "#function"})))

(test "requiring-resolve unqualified existing symbol" (fn []
  (test-cmd "requiring-resolve-unqualified"
    ["-e" "(requiring-resolve 'inc)"]
    {:expected-out "#function"})))

;; ---- require with string argument ----

(test "require with string tracks in loaded-libs" (fn []
  (test-cmd "require-string"
    ["-e" "(require \"clojure.string\") (loaded-libs)"]
    {:expected-out-contains "clojure.string"})))

;; ---- Regression: namespace loading with trampolining ----

(test "ns-loading with trampolining at top level" (fn []
  (test-cmd "ns-trampoline"
    ["-cp" "tests/complex-samples/sample_4_ns_trampoline/src"
     "-e" "(require 'tramp.test) tramp.test/result"]
    {:expected-out "1000"})))

(run-all)
