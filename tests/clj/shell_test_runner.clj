;; Shell test runner — subprocess-based test helpers for ClojureZ
;; Provides: run-cmd, test-cmd, test-repl, test-file, test-main
;;
;; These helpers spawn child clojurez processes to test features that
;; require process isolation (REPL, file execution, -cp/-m, stderr capture).
;;
;; Usage:
;;   (load-file "tests/clj/test_runner.clj")
;;   (load-file "tests/clj/shell_test_runner.clj")
;;
;;   (def-suite shell-tests)
;;   (test "print hello"
;;     (test-cmd "print-hello"
;;       ["-e" "(print \"hello\")"]
;;       {:expected-out "hello"}))

(require '[zig.io :as io])

;; ============================================================
;; VM binary detection
;; ============================================================

(defn- find-vm []
  "Find the clojurez VM binary path."
  (or
    ;; Check current directory
    (let [p "./zig-out/bin/clojurez"]
      (when (try (io/file-exists? p) (catch #_Throwable _ nil)) p))
    ;; Try common build output paths
    (let [p "../zig-out/bin/clojurez"]
      (when (try (io/file-exists? p) (catch #_Throwable _ nil)) p))
    ;; Fallback: just use the standard path
    "./zig-out/bin/clojurez"))

(def vm-path (atom nil))

(defn vm! []
  "Return the VM binary path, resolving once."
  (or @vm-path
      (do (reset! vm-path (find-vm))
          @vm-path)))

;; ============================================================
;; Core subprocess runner
;; ============================================================

(defn run-cmd
  "Run a clojurez subprocess with given args and optional timeout.

   Returns {:exit int :out string :err string}.

   Args:
     args - vector of command-line arguments (e.g. [\"-e\" \"(+ 1 2)\"])
     opts - map with optional keys:
       :timeout - seconds (default 10)
       :env - map of env vars (string -> string)
       :dir - working directory"
  ([args] (run-cmd args {}))
  ([args opts]
   (let [timeout (or (:timeout opts) 10)
         env (:env opts)
         dir (:dir opts)
         cmd-args (vec (concat (list (vm!) "--timeout" (str timeout)) args))]
     (if (or env dir)
       (let [sh-args (concat cmd-args
                              (when env (list :env env))
                              (when dir (list :dir dir)))]
         (apply io/sh sh-args))
       (apply io/sh cmd-args)))))

(defn run-cmd-stream
  "Run a clojurez subprocess using sh-stream (for stdin piping).

   Returns a handle for sh-in/sh-out/sh-err/sh-wait/sh-close-in.

   Args:
     args - vector of command-line arguments
     opts - map with optional :timeout (default 10)"
  ([args] (run-cmd-stream args {}))
  ([args opts]
   (let [timeout (or (:timeout opts) 10)
         cmd-args (vec (concat (list "--timeout" (str timeout)) args))]
     (apply io/sh-stream (vm!) cmd-args))))

;; ============================================================
;; Test helpers — integrate with test_runner framework
;; ============================================================

(defn test-cmd
  "Test a clojurez command against expected results.

   name - test name string
   args - vector of command-line arguments
   expectations - map with any of:
     :expected-out - expected stdout (exact match after trim)
     :expected-out-contains - substring that must appear in stdout
     :expected-err-contains - substring that must appear in stderr
     :expected-exit - expected exit code
     :expected-exit-nonzero - true to expect any non-zero exit
     :expected-crash - true to expect crash (non-zero exit)

   Uses check/check-true from test_runner framework."
  [name args expectations]
  (let [result (run-cmd args {:timeout (or (:timeout expectations) 10)})
        exit (:exit result)
        out (:out result)
        err (:err result)
        out-trimmed (clojure.string/trim out)
        err-trimmed (clojure.string/trim err)]

    ;; :expected-out (exact match after trim)
    (when-let [exp-out (:expected-out expectations)]
      (check (str name "/out") out-trimmed (clojure.string/trim exp-out)))

    ;; :expected-out-contains
    (when-let [exp-contains (:expected-out-contains expectations)]
      (check-true (str name "/out-contains")
        (when (string? out) (clojure.string/includes? out exp-contains))))

    ;; :expected-err-contains
    (when-let [exp-err (:expected-err-contains expectations)]
      (check-true (str name "/err-contains")
        (when (string? err) (clojure.string/includes? err exp-err))))

    ;; :expected-exit
    (when-let [exp-exit (:expected-exit expectations)]
      (check (str name "/exit") exit exp-exit))

    ;; :expected-exit-nonzero
    (when (:expected-exit-nonzero expectations)
      (check-true (str name "/exit-nonzero") (not= exit 0)))

    ;; :expected-crash
    (when (:expected-crash expectations)
      (check-true (str name "/crash") (not= exit 0)))))

(defn test-repl
  "Test REPL interaction by piping input to clojurez --repl.

   name - test name string
   input - string of REPL input (expressions separated by newlines)
   expectations - map with any of:
     :expected-out-contains - substring that must appear in output
     :expected-out-matches - regex pattern for output
     :expected-exit - expected exit code (default 0)
     :timeout - seconds (default 10)"
  [name input expectations]
  (let [timeout (or (:timeout expectations) 10)
        handle (run-cmd-stream ["--repl"] {:timeout timeout})]
    (io/sh-in handle input)
    (io/sh-close-in handle)
    (let [out (io/sh-out handle)
          err (io/sh-err handle)
          exit (io/sh-wait handle)
          full-out (str out "\n" err)]

      (when-let [exp-contains (:expected-out-contains expectations)]
        (check-true (str name "/out-contains")
          (clojure.string/includes? full-out exp-contains)))

      (when-let [exp-exit (:expected-exit expectations)]
        (check (str name "/exit") exit exp-exit)))))

(defn test-file
  "Test running a clojurez script file.

   name - test name string
   filepath - path to the .clj file to run
   expectations - map with any of:
     :expected-out - expected stdout (exact match after trim)
     :expected-out-contains - substring in stdout
     :expected-exit - expected exit code
     :timeout - seconds (default 10)"
  [name filepath expectations]
  (test-cmd name [filepath] expectations))

(defn test-main
  "Test running with -cp and -m flags.

   name - test name string
   classpath - classpath directory
   main-ns - main namespace symbol or string
   expectations - map with any of:
     :expected-out - expected stdout (exact match after trim)
     :expected-out-contains - substring in stdout
     :expected-exit - expected exit code
     :timeout - seconds (default 10)"
  [name classpath main-ns expectations]
  (test-cmd name ["-cp" classpath "-m" (str main-ns)] expectations))
