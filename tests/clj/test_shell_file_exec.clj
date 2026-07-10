;; File execution tests migrated from test_misc.sh
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")
(require '[zig.io :as io])

(def-suite shell-file-exec)

;; ---- File Execution: No Eval Output ----

(test "lazy-seq no over-evaluation" (fn []
  (let [tmp-file (str (zig.core/temp-dir) "/cljvm_test_lazy_no_overeval.clj")]
    (spit tmp-file
      "(def counter (atom 0))\n\n(defn counting-lazy-seq [n]\n  (do (swap! counter inc)\n      (if (> n 100)\n        nil\n        (lazy-seq\n          (cons n (counting-lazy-seq (inc n)))))))\n\n(def result (reduce + (take 3 (counting-lazy-seq 1))))\n\n(println (str \"count=\" @counter \" result=\" result))\n")
    (test-cmd "lazy-no-overeval"
      [tmp-file]
      {:expected-out "count=4 result=6"})
    (try (io/delete-file tmp-file) (catch Exception _ nil)))))

(test "no eval output from def/defn" (fn []
  (let [tmp-file (str (zig.core/temp-dir) "/cljvm_test_script_no_eval_output.clj")]
    (spit tmp-file
      "(defn add [a b]\n  (+ a b))\n\n(defn multiply [a b]\n  (* a b))\n\n(def x 10)\n(def y 20)\n(def sum (add x y))\n(def product (multiply x y))\n\n(println (str \"sum=\" sum \" product=\" product))\n")
    (test-cmd "no-eval-output"
      [tmp-file]
      {:expected-out "sum=30 product=200"})
    (try (io/delete-file tmp-file) (catch Exception _ nil)))))

(run-all)
