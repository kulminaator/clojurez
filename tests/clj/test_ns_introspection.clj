;; Namespace introspection tests: find-ns, create-ns, all-ns, the-ns, ns-name
(load-file "tests/clj/clj_test_helper.clj")

;; ---- find-ns tests ----

;; find-ns returns a map for existing namespace
(check-true "find-ns clojure.core returns map" (map? (find-ns 'clojure.core)))
(check-true "find-ns user returns map" (map? (find-ns 'user)))

;; find-ns returns nil for nonexistent namespace
(check-false "find-ns nonexistent returns nil" (find-ns 'nonexistent.ns.xyz))

;; find-ns returns map with :name key
(check "find-ns :name clojure.core" (get (find-ns 'clojure.core) :name) 'clojure.core)
(check "find-ns :name user" (get (find-ns 'user) :name) 'user)

;; find-ns returns map with :interns key (map)
(check-true "find-ns has :interns key" (map? (get (find-ns 'clojure.core) :interns)))

;; find-ns returns map with :refers key (map)
(check-true "find-ns has :refers key" (map? (get (find-ns 'clojure.core) :refers)))

;; find-ns returns map with :aliases key (map)
(check-true "find-ns has :aliases key" (map? (get (find-ns 'clojure.core) :aliases)))

;; find-ns with namespace map argument (idempotent)
(check "find-ns with ns map returns same name"
       (get (find-ns (find-ns 'user)) :name)
       'user)

;; find-ns clojure.core has interns (owned vars)
(check-true "find-ns clojure.core has interns"
            (pos? (count (get (find-ns 'clojure.core) :interns))))

;; find-ns user interns count (test helper adds some, so just check it's a finite number)
(check-true "find-ns user interns is finite" (integer? (count (get (find-ns 'user) :interns))))

;; find-ns user has no refers
(check "find-ns user has no refers"
       (count (get (find-ns 'user) :refers))
       0)

;; find-ns clojure.core has no refers
(check "find-ns clojure.core has no refers"
       (count (get (find-ns 'clojure.core) :refers))
       0)

;; ---- create-ns tests ----

;; create-ns creates a new namespace and returns a map
(check-true "create-ns returns map" (map? (create-ns 'test.introspect.ns1)))

;; create-ns returns map with correct :name
(check "create-ns :name" (get (create-ns 'test.introspect.ns2) :name) 'test.introspect.ns2)

;; create-ns is idempotent (returns existing ns)
(do
  (create-ns 'test.introspect.ns3)
  (def _ns-a (create-ns 'test.introspect.ns3))
  (check "create-ns idempotent :name" (get _ns-a :name) 'test.introspect.ns3))

;; create-ns new namespace has empty interns
(check "create-ns empty interns"
       (count (get (create-ns 'test.introspect.ns4) :interns))
       0)

;; create-ns new namespace has empty refers
(check "create-ns empty refers"
       (count (get (create-ns 'test.introspect.ns5) :refers))
       0)

;; create-ns new namespace has empty aliases
(check "create-ns empty aliases"
       (count (get (create-ns 'test.introspect.ns6) :aliases))
       0)

;; ---- all-ns tests ----

;; all-ns returns a list
(check-true "all-ns returns list" (list? (all-ns)))

;; all-ns has at least 2 namespaces (user + clojure.core)
(check-true "all-ns count >= 2" (>= (count (all-ns)) 2))

;; all-ns contains user namespace
(check-true "all-ns contains user"
            (some #(= (get % :name) 'user) (all-ns)))

;; all-ns contains clojure.core namespace
(check-true "all-ns contains clojure.core"
            (some #(= (get % :name) 'clojure.core) (all-ns)))

;; all-ns returns namespace maps (each element is a map)
(check-true "all-ns elements are maps"
            (every? map? (all-ns)))

;; all-ns namespace names are unique
(check-true "all-ns names are unique"
            (= (count (vec (map :name (all-ns))))
               (count (set (vec (map :name (all-ns)))))))

;; ---- ns-name tests ----

;; ns-name with symbol argument
(check "ns-name with symbol" (ns-name 'clojure.core) 'clojure.core)
(check "ns-name user" (ns-name 'user) 'user)

;; ns-name with namespace map argument
(check "ns-name with ns map" (ns-name (find-ns 'user)) 'user)

;; ns-name with nonexistent namespace (find-ns returns nil, get on nil errors)
;; We can't test this in Clojure since it errors — tested in shell tests instead

;; ---- the-ns tests ----

;; the-ns returns map for existing namespace
(check-true "the-ns returns map" (map? (the-ns 'user)))

;; the-ns returns correct name
(check "the-ns :name" (get (the-ns 'clojure.core) :name) 'clojure.core)

;; the-ns with namespace map argument
(check "the-ns with ns map" (get (the-ns (find-ns 'user)) :name) 'user)

;; ---- Integration: ns with :require shows refers and aliases ----

;; Create a namespace with :require :refer and check refers
(ns test.introspect.refer (:require [clojure.string :as str :refer [join upper-case]]))
(ns user)

(check-true "refer creates refers"
            (pos? (count (get (find-ns 'test.introspect.refer) :refers))))

;; Check that join and upper-case are in refers
(check-true "refer :join in refers"
            (contains? (get (find-ns 'test.introspect.refer) :refers) 'join))
(check-true "refer :upper-case in refers"
            (contains? (get (find-ns 'test.introspect.refer) :refers) 'upper-case))

;; Check that str alias exists
(check-true "alias :str exists"
            (contains? (get (find-ns 'test.introspect.refer) :aliases) 'str))
(check "alias str target"
       (get (get (find-ns 'test.introspect.refer) :aliases) 'str)
       'clojure.string)

(print-summary)
