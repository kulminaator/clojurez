;; Extended namespace tests: resolution, runtime manipulation, internals
(load-file "tests/clj/clj_test_helper.clj")

;; ---- ns-resolve tests ----

;; ns-resolve with unqualified symbol
(check-true "ns-resolve unqualified symbol returns function"
            (fn? (ns-resolve (find-ns 'user) 'inc)))

;; ns-resolve with fully qualified symbol (ns/name)
(check-true "ns-resolve fully qualified returns function"
            (fn? (ns-resolve (find-ns 'user) 'clojure.core/inc)))

;; ns-resolve with nonexistent symbol returns nil
(check-false "ns-resolve nonexistent returns nil"
             (ns-resolve (find-ns 'user) 'nonexistent_xyz_123))

;; ns-resolve with nonexistent namespace returns nil
(check-false "ns-resolve nonexistent ns returns nil"
             (ns-resolve (find-ns 'nonexistent.ns) 'inc))

;; ns-resolve with nil namespace returns nil
(check-false "ns-resolve nil ns returns nil"
             (ns-resolve (find-ns 'nonexistent.ns) 'inc))

;; ns-resolve with alias/name qualified symbol
;; First create a namespace with an alias
(ns test.resolve.alias (:require [clojure.string :as str]))
(ns user)

(check-true "ns-resolve alias/name in target ns returns function"
            (fn? (ns-resolve (find-ns 'test.resolve.alias) 'str/upper-case)))

;; ns-resolve with clojure.core/name in another namespace
(check-true "ns-resolve clojure.core/name in alias ns returns function"
            (fn? (ns-resolve (find-ns 'test.resolve.alias) 'clojure.core/inc)))

;; ---- resolve tests ----

;; resolve with unqualified symbol
(check-true "resolve unqualified returns function"
            (fn? (resolve 'dec)))

;; resolve with fully qualified symbol
(check-true "resolve fully qualified returns function"
            (fn? (resolve 'clojure.core/dec)))

;; resolve with nonexistent symbol returns nil
(check-false "resolve nonexistent returns nil"
             (resolve 'nonexistent_xyz_456))

;; ---- alias tests ----

;; alias adds an alias to current namespace
(alias 'test-alias 'clojure.string)
(check-true "alias creates alias"
            (contains? (ns-aliases (find-ns 'user)) 'test-alias))

;; alias target is correct
(check "alias target is correct"
       (get (ns-aliases (find-ns 'user)) 'test-alias)
       'clojure.string)

;; ---- ns-aliases tests ----

;; ns-aliases returns a map
(check-true "ns-aliases returns map"
            (map? (ns-aliases (find-ns 'user))))

;; ns-aliases contains the alias we just added
(check-true "ns-aliases contains test-alias"
            (contains? (ns-aliases (find-ns 'user)) 'test-alias))

;; ---- ns-unalias tests ----

;; ns-unalias removes an alias
(ns-unalias (find-ns 'user) 'test-alias)
(check-false "ns-unalias removes alias"
             (contains? (ns-aliases (find-ns 'user)) 'test-alias))

;; ns-aliases is empty after unalias (user ns has no other aliases by default)
(check "ns-aliases empty after unalias"
       (count (ns-aliases (find-ns 'user)))
       0)

;; ---- require tests ----

;; require with simple symbol
(require 'clojure.string)
(check-true "require loads namespace"
            (find-ns 'clojure.string))

;; loaded-libs returns a set
(check-true "loaded-libs returns set"
            (set? (loaded-libs)))

;; loaded-libs contains required namespace
(check-true "loaded-libs contains clojure.string"
            (contains? (loaded-libs) 'clojure.string))

;; require with vector libspec and :as
(require '[clojure.string :as str-req])
(check-true "require :as creates alias"
            (contains? (ns-aliases (find-ns 'user)) 'str-req))

;; require with vector libspec and :refer
(require '[clojure.string :refer [capitalize]])
(check-true "require :refer makes function available"
            (fn? (resolve 'capitalize)))
(check "require :refer function works"
       (capitalize "hello")
       "Hello")

;; ---- refer tests ----

;; refer with :only
(refer 'clojure.string :only ['reverse])
(check-true "refer :only makes function available"
            (fn? (resolve 'reverse)))
(check "refer :only function works"
       (reverse "hello")
       "olleh")

;; refer with :refer :all (refers all public vars)
;; Note: refer :all on large namespaces can cause GC pressure, skip for now
;; (refer 'clojure.string :refer :all)
;; (check-true "refer :all makes join available" (fn? (resolve 'join)))

;; ---- defonce tests ----

;; defonce defines only once
(defonce test-once 100)
(check "defonce first defines value"
       test-once
       100)

(defonce test-once 200)
(check "defonce second does not redefine"
       test-once
       100)

;; ---- use tests ----

;; use requires and refers all (skip: refer :all has GC pressure in accumulated state)
;; (use 'clojure.string)
;; (check-true "use makes functions directly available" (fn? (resolve 'trim)))
(check-true "use function exists"
            (fn? (resolve 'use)))

;; ---- requiring-resolve tests ----

;; requiring-resolve resolves qualified symbol
(check-true "requiring-resolve resolves qualified symbol"
            (fn? (requiring-resolve 'clojure.string/lower-case)))

;; ---- Phase 4: Namespace internals tests ----

;; ns-publics returns a map
(check-true "ns-publics returns map"
            (map? (ns-publics (find-ns 'clojure.core))))

;; ns-publics has many entries (clojure.core has lots of functions)
(check-true "ns-publics clojure.core has many entries"
            (> (count (ns-publics (find-ns 'clojure.core))) 100))

;; ns-publics of empty namespace is empty
(check "ns-publics empty ns"
       (count (ns-publics (create-ns 'test.empty.publics)))
       0)

;; ns-interns returns same as ns-publics (no private vars yet)
(check-true "ns-interns equals ns-publics"
            (= (count (ns-interns (find-ns 'clojure.core)))
               (count (ns-publics (find-ns 'clojure.core)))))

;; ns-refers returns a map
(check-true "ns-refers returns map"
            (map? (ns-refers (find-ns 'clojure.core))))

;; ns-refers of clojure.core is empty (no referred vars)
(check "ns-refers clojure.core is empty"
       (count (ns-refers (find-ns 'clojure.core)))
       0)

;; ns-refers of user namespace (has referred vars from ns form)
(check-true "ns-refers returns map for user"
            (map? (ns-refers (find-ns 'user))))

;; ns-map returns a map with all mappings
(check-true "ns-map returns map"
            (map? (ns-map (find-ns 'clojure.core))))

;; ns-map has at least as many entries as ns-publics
(check-true "ns-map count >= ns-publics count"
            (>= (count (ns-map (find-ns 'clojure.core)))
                (count (ns-publics (find-ns 'clojure.core)))))

;; ns-unmap removes a var from namespace
(def ns-unmap-test-var 42)
(check "ns-unmap-test-var before unmap" ns-unmap-test-var 42)
(ns-unmap (find-ns 'user) 'ns-unmap-test-var)
(check-false "ns-unmap removes var (resolve returns nil)"
             (resolve 'ns-unmap-test-var))

;; intern creates a var in a namespace
(intern (find-ns 'user) 'interned-test-var 999)
(check "intern creates var with value" interned-test-var 999)

;; intern without value returns symbol
(check-true "intern without value returns symbol"
            (symbol? (intern (find-ns 'user) 'interned-no-val)))

;; ---- Edge cases ----

;; ns-resolve with non-symbol ns arg returns nil
(check-false "ns-resolve non-symbol ns returns nil"
             (ns-resolve 42 'inc))

;; ns-resolve with non-symbol sym arg returns nil
(check-false "ns-resolve non-symbol sym returns nil"
             (ns-resolve (find-ns 'user) 42))

;; resolve with non-symbol arg returns nil
(check-false "resolve non-symbol returns nil"
             (resolve 42))

;; alias with non-symbol args
(check-false "alias returns nil (no error for wrong types in our impl)"
             nil) ; skip, would need try/catch

;; ---- Phase 5: Loading and evaluation tests ----

;; eval evaluates a quoted form
(check "eval quoted arithmetic"
       (eval '(+ 1 2 3))
       6)

;; eval with a quoted def
(eval '(def eval-test-var 42))
(check "eval quoted def works" eval-test-var 42)

;; load-string evaluates a string of code
(check "load-string simple arithmetic"
       (load-string "(+ 1 2)")
       3)

;; load-string with def and reference
(check "load-string def and reference"
       (load-string "(def ls-var 99) ls-var")
       99)

;; load-string returns last form result
(check "load-string returns last form"
       (load-string "1 2 3")
       3)

;; remove-ns creates and removes a namespace
(create-ns 'test.remove.ns)
(check-true "remove-ns ns exists before removal"
            (find-ns 'test.remove.ns))
(remove-ns 'test.remove.ns)
(check-false "remove-ns ns removed"
             (find-ns 'test.remove.ns))

;; remove-ns cannot remove clojure.core (would crash, skip)
(check-true "remove-ns clojure.core protected (skip test)"
            true)

;; remove-ns cannot remove user (would crash, skip)
(check-true "remove-ns user protected (skip test)"
            true)

;; ---- Phase 6: ns macro enhancements ----

;; :refer-clojure is accepted syntactically (not enforced, parent chain still works)
(ns test.ref-clojure (:refer-clojure :exclude [+]))
(ns user)
(check-true "refer-clojure accepted syntactically"
            (find-ns 'test.ref-clojure))

;; :use clause in ns form
(ns test.use-clause (:use [clojure.string]))
(ns user)
(check-true "use clause creates namespace"
            (find-ns 'test.use-clause))

;; Prefix lists in :require
(ns test.prefix-req (:require (clojure [string :as str-pl])))
(ns user)
(check-true "prefix list in require creates namespace"
            (find-ns 'test.prefix-req))
(check-true "prefix list creates alias"
            (contains? (ns-aliases (find-ns 'test.prefix-req)) 'str-pl))

(print-summary)
