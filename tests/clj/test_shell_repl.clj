;; REPL interaction tests migrated from test_misc.sh and test_namespaces.sh
(load-file "tests/clj/test_runner.clj")
(load-file "tests/clj/shell_test_runner.clj")

(def-suite shell-repl)

;; ---- REPL Long Input Tests ----
;; (migrated from test_misc.sh)

(test "repl long expression >4096 bytes" (fn []
  (let [ones (apply str (interpose " " (repeat 3000 "1")))
        expr (str "(+ " ones ")")
        input (str expr "\n(println :ok)\n(exit)\n")]
    (test-repl "repl-long-4k"
      input
      {:expected-out-contains "3000"
       :timeout 15}))))

(test "repl long expression >8192 bytes" (fn []
  (let [ones (apply str (interpose " " (repeat 6000 "1")))
        expr (str "(+ " ones ")")
        input (str expr "\n(println :ok)\n(exit)\n")]
    (test-repl "repl-long-8k"
      input
      {:expected-out-contains "6000"
       :timeout 15}))))

;; ---- Namespace Parent Cycle Regression ----
;; (migrated from test_misc.sh)

(test "ns parent cycle undefined symbol no hang" (fn []
  (test-repl "ns-parent-cycle"
    "(ns mytest)\nundefined-symbol-xyz\n(println :done)\n(exit)\n"
    {:expected-out-contains ":done"
     :timeout 5})))

;; ---- :refer Semantics Tests ----
;; (migrated from test_misc.sh)

(test "refer selective" (fn []
  (test-repl "refer-selective"
    "(ns mylib)\n(defn alpha [] :alpha)\n(defn beta [] :beta)\n(ns myapp (:require [mylib :refer [alpha]]))\n(alpha)\n(println (mylib/beta))\nbeta\n(exit)\n"
    {:expected-out-contains ":alpha"
     :timeout 5})))

(test "refer :all" (fn []
  (test-repl "refer-all"
    "(ns mylib2)\n(defn x [] :x)\n(defn y [] :y)\n(ns myapp2 (:require [mylib2 :refer :all]))\n(x)\n(y)\n(exit)\n"
    {:expected-out-contains ":x"
     :timeout 5})))

(test "refer :all :exclude" (fn []
  (test-repl "refer-all-exclude"
    "(ns mylib3)\n(defn a [] :a)\n(defn b [] :b)\n(ns myapp3 (:require [mylib3 :refer :all :exclude [b]]))\n(a)\nb\n(exit)\n"
    {:expected-out-contains ":a"
     :timeout 5})))

(test "refer + as combined" (fn []
  (test-repl "refer-as-combined"
    "(ns mylib4)\n(defn hello [n] (str \"hi-\" n))\n(defn bye [n] (str \"bye-\" n))\n(ns myapp4 (:require [mylib4 :as m4 :refer [hello]]))\n(println (hello 1) (m4/bye 2))\n(exit)\n"
    {:expected-out-contains "hi-1"
     :timeout 5})))

;; ---- REPL Namespace Tests ----
;; (migrated from test_namespaces.sh)

(test "repl starts in user namespace" (fn []
  (test-repl "repl-user-ns"
    "(exit)\n"
    {:expected-out-contains "user=>"
     :timeout 5})))

(test "repl defn and call" (fn []
  (test-repl "repl-defn-call"
    "(defn hello [] (println \"hello world\"))\n(hello)\n(exit)\n"
    {:expected-out-contains "hello world"
     :timeout 5})))

(test "repl ns switching changes prompt" (fn []
  (test-repl "repl-ns-switch"
    "(ns city)\n(exit)\n"
    {:expected-out-contains "city=>"
     :timeout 5})))

(test "repl qualified symbol cross-namespace" (fn []
  (test-repl "repl-qualified-sym"
    "(def carrot 7)\n(ns city)\nuser/carrot\n(exit)\n"
    {:expected-out-contains "city=> 7"
     :timeout 5})))

(test "repl qualified fn call cross-namespace" (fn []
  (test-repl "repl-qualified-fn"
    "(defn greet [n] (str \"Hello \" n))\n(ns other)\n(user/greet \"Bob\")\n(exit)\n"
    {:expected-out-contains "Hello Bob"
     :timeout 5})))

(test "repl namespace isolation" (fn []
  (test-repl "repl-ns-isolation"
    "(def x 100)\n(ns other)\n(def x 200)\n(ns user)\nx\n(exit)\n"
    {:expected-out-contains "user=> 100"
     :timeout 5})))

(test "repl multiple expressions no freeze" (fn []
  (test-repl "repl-multi-expr"
    "(+ 1 2)\n(+ 3 4)\n(+ 5 6)\n(exit)\n"
    {:expected-out-contains "user=>"
     :timeout 5})))

(test "repl defn then call no freeze" (fn []
  (test-repl "repl-defn-no-freeze"
    "(defn double [n] (* n 2))\n(double 21)\n(exit)\n"
    {:expected-out-contains "42"
     :timeout 5})))

(test "repl eof without exit" (fn []
  (test-repl "repl-eof"
    "(+ 1 2)\n(+ 3 4)"
    {:expected-out-contains "user=>"
     :timeout 5})))

(test "repl multiline string literal" (fn []
  (test-repl "repl-multiline-string"
    "\"hello\nworld\"\n(exit)\n"
    {:expected-out-contains "hello"
     :timeout 5})))

(test "repl def multiline string" (fn []
  (test-repl "repl-def-multiline"
    "(def msg \"line1\nline2\")\n(count msg)\n(exit)\n"
    {:expected-out-contains "11"
     :timeout 5})))

(test "repl defn multiline docstring" (fn []
  (test-repl "repl-defn-docstring"
    "(defn greet\n\"Say hello\nto everyone\"\n[name] (str \"Hi \" name))\n(greet \"Zig\")\n(exit)\n"
    {:expected-out-contains "Hi Zig"
     :timeout 5})))

(test "repl map/vector/set no crash" (fn []
  (test-repl "repl-map-vec-set"
    "{:a 1 :b 2}\n[1 2 3]\n#{:x :y}\n(exit)\n"
    {:expected-out-contains "user=>"
     :timeout 5})))

(run-all)
