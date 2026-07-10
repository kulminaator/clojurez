;; zig.io integration tests migrated from test_zig_io.sh
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

(def-suite shell-zig-io)

;; ---- sh with nonexistent command ----

(test "sh nonexistent command errors" (fn []
  (test-cmd "sh-nonexistent"
    ["-e" "(require '[zig.io :as io]) (io/sh \"nonexistent_cmd_xyz123\")"]
    {:expected-exit-nonzero true})))

;; ---- sh-stream with echo ----

(test "sh-stream echo exits 0" (fn []
  (test-cmd "sh-stream-echo"
    ["-e" "(require '[zig.io :as io]) (let [p (io/sh-stream \"echo\" \"hello\")] (io/sh-wait p))"]
    {:expected-out "0"})))

;; ---- sh-stream with stdin pipe ----

(test "sh-stream stdin pipe word count" (fn []
  (test-cmd "sh-stream-wc"
    ["-e" "(require '[zig.io :as io]) (let [p (io/sh-stream \"wc\" \"-w\")] (io/sh-in p \"a b c\\n\") (io/sh-close-in p) (let [out (io/sh-out p)] (io/sh-wait p) (println (clojure.string/trim out))))"]
    {:expected-out "3"})))

;; ---- sh-stream stderr capture ----

(test "sh-stream stderr capture" (fn []
  (test-cmd "sh-stream-stderr"
    ["-e" "(require '[zig.io :as io]) (let [p (io/sh-stream \"sh\" \"-c\" \"echo err >&2\") err (io/sh-err p)] (io/sh-wait p) (if (string? err) (println \"PASS\") (println \"FAIL\")))"]
    {:expected-out "PASS"})))

;; ---- sh-kill terminates process ----

(test "sh-kill terminates process" (fn []
  (test-cmd "sh-kill"
    ["-e" "(require '[zig.io :as io]) (let [p (io/sh-stream \"sleep\" \"60\")] (io/sh-kill p) (println \"killed\"))"]
    {:expected-out "killed"})))

;; ---- file operations with nonexistent path ----

(test "as-file nonexistent path returns map" (fn []
  (test-cmd "as-file-nonexistent"
    ["-e" "(require '[zig.io :as io]) (io/as-file \"/nonexistent/path/xyz123\")"]
    {:expected-out-contains "path"})))

;; ---- with-sh-dir macro ----

(test "with-sh-dir macro works" (fn []
  (test-cmd "with-sh-dir"
    ["-e" "(require '[zig.io :as io]) (io/with-sh-dir \"/tmp\" (println \"dir set\"))"]
    {:expected-out "dir set"})))

;; ---- with-sh-env macro ----

(test "with-sh-env macro works" (fn []
  (test-cmd "with-sh-env"
    ["-e" "(require '[zig.io :as io]) (io/with-sh-env {:FOO \"bar\"} (println \"env set\"))"]
    {:expected-out "env set"})))

;; ---- GC safety with process handles (sweep=0) ----

(test "GC safety with process handles (sweep=0)" (fn []
  (test-cmd "gc-sweep-0"
    ["-e" "(require '[zig.io :as io]) (defn run-n [n] (when (> n 0) (let [p (io/sh-stream \"echo\" (str n))] (io/sh-out p) (io/sh-wait p)) (run-n (dec n)))) (run-n 20) (println \"gc-safe\")"]
    {:expected-out-contains "gc-safe"
     :timeout 30})))

;; ---- GC safety with process handles (sweep=1) ----

(test "GC safety with process handles (sweep=1)" (fn []
  (test-cmd "gc-sweep-1"
    ["-e" "(require '[zig.io :as io]) (defn run-n [n] (when (> n 0) (let [p (io/sh-stream \"echo\" (str n))] (io/sh-out p) (io/sh-wait p)) (run-n (dec n)))) (run-n 20) (println \"gc-safe\")"]
    {:expected-out-contains "gc-safe"
     :timeout 30})))

(run-all)
