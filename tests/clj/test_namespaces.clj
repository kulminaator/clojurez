;; Namespace tests: qualified symbols, requires, isolation
;; We define check in clojure.core so it's accessible from all namespaces.
;; This is safe for testing since we restore state after.
(ns clojure.core)
(def passes (atom 0))
(def failures (atom 0))
(defn check [name result expected]
  (if (= result expected)
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected=" expected " got=" result)))))
(defn print-summary []
  (println (str "SUMMARY: " @passes " passed, " @failures " failed")))
(ns user)

;; --- ns declaration returns nil/symbol ---
(check "ns declaration" (ns test.ns.decl) nil)
(check "ns basic declaration" (ns test.ns.basic) nil)
(ns user)

;; --- qualified symbol via alias ---
(ns lib.foo)
(defn greet [] "hi")
(ns my.app (:require [lib.foo :as f]))
(check "qualified symbol via alias" (f/greet) "hi")
(ns user)

;; --- multiple requires ---
(ns lib.a)
(defn get-a [] "A")
(ns lib.b)
(defn get-b [] "B")
(ns main.app (:require [lib.a :as a] [lib.b :as b]))
(check "multiple requires" (str (a/get-a) (b/get-b)) "AB")
(ns user)

;; --- namespace isolation ---
(ns iso.ns1)
(def x 1)
(ns iso.ns2)
(def x 2)
(ns iso.ns1)
(def isolated-x x)
(ns user)
(check "namespace isolation" iso.ns1/isolated-x 1)

;; --- in-ns form ---
(in-ns test.inns)
(defn get-val [] 42)
(ns user)
(check "in-ns creates namespace" (test.inns/get-val) 42)

(print-summary)
