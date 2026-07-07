;; defrecord tests: creation, factories, map operations, equality,
;;                  metadata, protocols, merge/into, edge cases
(load-file "tests/clj/clj_test_helper.clj")

;; --- Basic defrecord creation ---
(defrecord Person [name age])
(check "defrecord returns symbol" (string? (str Person)) true)

;; --- Factory: ->Person (positional) ---
(def p1 (->Person "Alice" 30))
(check "factory ->Person: record?" (record? p1) true)
(check "factory ->Person: name" (get p1 :name) "Alice")
(check "factory ->Person: age" (get p1 :age) 30)
(check "factory ->Person: type" (type p1) :user.Person)

;; --- Factory: map->Person ---
(def p2 (map->Person {:name "Bob" :age 25}))
(check "factory map->Person: record?" (record? p2) true)
(check "factory map->Person: name" (get p2 :name) "Bob")
(check "factory map->Person: age" (get p2 :age) 25)

;; --- map->Person with extra keys (extmap) ---
(def p3 (map->Person {:name "Carol" :age 35 :extra "data"}))
(check "map->Person extra: name" (get p3 :name) "Carol")
(check "map->Person extra: extra key" (get p3 :extra) nil)

;; --- map->Person with missing keys ---
(def p4 (map->Person {:name "Dave"}))
(check "map->Person missing: name" (get p4 :name) "Dave")
(check "map->Person missing: age nil" (get p4 :age) nil)

;; --- get on records ---
(check "get: field" (get p1 :name) "Alice")
(check "get: default" (get p1 :missing "default") "default")
(check "get: no default" (get p1 :missing) nil)

;; --- assoc on records ---
(def p5 (assoc p1 :age 31))
(check "assoc field: record?" (record? p5) true)
(check "assoc field: updated" (get p5 :age) 31)
(check "assoc field: unchanged" (get p5 :name) "Alice")

;; --- assoc with new key (extmap) ---
(def p6 (assoc p1 :city "NYC"))
(check "assoc extmap: record?" (record? p6) true)
(check "assoc extmap: city" (get p6 :city) "NYC")
(check "assoc extmap: name unchanged" (get p6 :name) "Alice")

;; --- assoc multiple pairs ---
(def p7 (assoc p1 :age 31 :city "NYC"))
(check "assoc multi: age" (get p7 :age) 31)
(check "assoc multi: city" (get p7 :city) "NYC")

;; --- dissoc on records ---
(def p8 (dissoc p1 :name))
(check "dissoc field: demoted to map" (record? p8) false)
(check "dissoc field: age preserved" (get p8 :age) 30)

(def p9 (dissoc p6 :city))
(check "dissoc extmap: still record" (record? p9) true)
(check "dissoc extmap: city removed" (get p9 :city) nil)
(check "dissoc extmap: name preserved" (get p9 :name) "Alice")

;; --- contains? on records ---
(check "contains? field" (contains? p1 :name) true)
(check "contains? missing" (contains? p1 :missing) false)
(check "contains? extmap" (contains? p6 :city) true)

;; --- seq on records ---
(def s (seq p1))
(check "seq: not nil" (nil? s) false)
(check "seq: count" (count s) 2)

;; --- count on records ---
(check "count: basic" (count p1) 2)
(check "count: with extmap" (count p6) 3)

;; --- keys on records ---
(def k (keys p1))
(check "keys: count" (count k) 2)
(check "keys: has name" (contains? (set k) :name) true)
(check "keys: has age" (contains? (set k) :age) true)

;; --- vals on records ---
(def v (vals p1))
(check "vals: count" (count v) 2)

;; --- record equality ---
(check "eq: same fields" (= (->Person "Alice" 30) (->Person "Alice" 30)) true)
(check "eq: diff name" (= (->Person "Alice" 30) (->Person "Bob" 30)) false)
(check "eq: diff age" (= (->Person "Alice" 30) (->Person "Alice" 31)) false)

;; --- equality with extmap ---
(check "eq: same extmap"
  (= (assoc (->Person "Alice" 30) :x 1)
     (assoc (->Person "Alice" 30) :x 1))
  true)
(check "eq: diff extmap"
  (= (assoc (->Person "Alice" 30) :x 1)
     (assoc (->Person "Alice" 30) :x 2))
  false)

;; --- equality with different record types ---
(defrecord Other [name age])
(check "eq: diff types" (= (->Person "Alice" 30) (->Other "Alice" 30)) false)

;; --- metadata ---
(def pm (with-meta (->Person "Alice" 30) {:role "admin"}))
(check "meta: returns map" (map? (meta pm)) true)
(check "meta: role" (get (meta pm) :role) "admin")
(check "with-meta: fields preserved" (get pm :name) "Alice")
(check "with-meta: still record" (record? pm) true)

;; --- metadata not compared for equality ---
(check "eq: meta ignored"
  (= (->Person "Alice" 30) (with-meta (->Person "Alice" 30) {:x 1}))
  true)

;; --- record printing ---
(check "print format starts with #"
  (let [s (str (->Person "Alice" 30))]
    (= (subs s 0 1) "#"))
  true)

;; --- record as function (lookup) ---
(check "record as fn: field" ((->Person "Alice" 30) :name) "Alice")
(check "record as fn: default" ((->Person "Alice" 30) :missing "default") "default")

;; --- keyword as function on record ---
(check "keyword on record: field" (:name (->Person "Alice" 30)) "Alice")
(check "keyword on record: missing" (:missing (->Person "Alice" 30)) nil)

;; --- merge with records ---
(check "merge: update field"
  (let [m (merge (->Person "Alice" 30) {:age 31})]
    (and (record? m) (= (get m :age) 31)))
  true)
(check "merge: add extmap key"
  (let [m (merge (->Person "Alice" 30) {:city "NYC"})]
    (and (record? m) (= (get m :city) "NYC")))
  true)
(check "merge: multiple maps"
  (let [m (merge (->Person "Alice" 30) {:age 31} {:city "NYC"})]
    (and (record? m) (= (get m :age) 31) (= (get m :city) "NYC")))
  true)

;; --- into with records ---
(check "into: update field"
  (let [m (into (->Person "Alice" 30) {:age 31})]
    (and (record? m) (= (get m :age) 31)))
  true)
(check "into: add extmap key"
  (let [m (into (->Person "Alice" 30) {:city "NYC"})]
    (and (record? m) (= (get m :city) "NYC")))
  true)

;; --- conj on records ---
(check "conj: vector entry"
  (let [m (conj (->Person "Alice" 30) [:city "NYC"])]
    (and (record? m) (= (get m :city) "NYC")))
  true)
(check "conj: list entry"
  (let [m (conj (->Person "Alice" 30) '(:city "NYC"))]
    (and (record? m) (= (get m :city) "NYC")))
  true)

;; --- reduce on records ---
(check "reduce: over record"
  (let [result (reduce (fn [acc [k v]] (conj acc (str k "=" v))) [] (->Person "Alice" 30))]
    (= (count result) 2))
  true)

;; --- reduce on maps (needed for into) ---
(check "reduce: over map"
  (let [result (reduce (fn [acc [k v]] (conj acc (str k "=" v))) [] {:a 1 :b 2})]
    (= (count result) 2))
  true)

;; --- Protocol implementation on records ---
(defprotocol Greetable (greet [this]))
(defrecord Greeter [name]
  Greetable
    (greet [this] (str "Hi, I'm " name)))
(check "protocol: greet" (greet (->Greeter "Alice")) "Hi, I'm Alice")
(check "protocol: satisfies?" (satisfies? Greetable (->Greeter "Alice")) true)

;; --- Multiple protocols on records ---
(defprotocol Introduce (intro [this]))
(defrecord MultiProto [name age]
  Greetable
    (greet [this] (str "Hello, " name))
  Introduce
    (intro [this] (str "I am " name ", " age " years old")))
(check "multi-protocol: greet" (greet (->MultiProto "Bob" 25)) "Hello, Bob")
(check "multi-protocol: intro" (intro (->MultiProto "Bob" 25)) "I am Bob, 25 years old")

;; --- Empty record ---
(defrecord Empty [])
(def e (->Empty))
(check "empty record: record?" (record? e) true)
(check "empty record: count" (count e) 0)
(check "empty record: seq nil" (nil? (seq e)) true)

;; --- Record with many fields ---
(defrecord ManyFields [a b c d e f g h i j])
(def mf (->ManyFields 1 2 3 4 5 6 7 8 9 10))
(check "many fields: count" (count mf) 10)
(check "many fields: first" (get mf :a) 1)
(check "many fields: last" (get mf :j) 10)

;; --- extend-type after defrecord ---
(defprotocol ExtraMethod (extra [this]))
(extend-type :user.Person ExtraMethod
  (extra [this] (str "extra: " (get this :name))))
(check "extend-type after defrecord" (extra (->Person "Alice" 30)) "extra: Alice")

;; --- coll? and map? on records ---
(check "coll? on record" (coll? (->Person "Alice" 30)) true)
(check "map? on record" (map? (->Person "Alice" 30)) true)

(print-summary)
