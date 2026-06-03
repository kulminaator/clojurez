;; Clojure VM Core Library
;; Bootstrapped from Clojure source - keeps the Zig VM lean

;; ---- Basic predicates ----

(defn even? [n]
  (= (rem n 2) 0))

(defn odd? [n]
  (not (even? n)))

(defn zero? [n]
  (= n 0))

(defn pos? [n]
  (> n 0))

(defn neg? [n]
  (< n 0))

;; ---- Identity ----

(defn identity [x]
  x)

;; ---- Math helpers ----

(defn inc [n]
  (+ n 1))

(defn dec [n]
  (- n 1))

(defn abs [n]
  (if (neg? n)
    (- 0 n)
    n))

(defn max [a b]
  (if (> a b) a b))

(defn min [a b]
  (if (< a b) a b))

;; ---- List helpers ----

(defn cons [x xs]
  (concat (list x) xs))

(defn second [xs]
  (first (rest xs)))

(defn third [xs]
  (first (rest (rest xs))))

;; ---- Set operations (built on core set type) ----

(defn union
  "Return a set that is the union of the input sets"
  [s1 s2]
  (if (< (count s1) (count s2))
    (reduce conj s2 s1)
    (reduce conj s1 s2)))

(defn intersection
  "Return a set that is the intersection of the input sets"
  [s1 s2]
  (if (< (count s2) (count s1))
    (recur s2 s1)
    (reduce (fn [result item]
              (if (contains? s2 item)
                result
                (disj result item)))
            s1 s1)))

(defn difference
  "Return a set that is the first set without elements of the remaining sets"
  [s1 s2]
  (reduce disj s1 s2))

(defn subset?
  "Is set1 a subset of set2?"
  [set1 set2]
  (and (<= (count set1) (count set2))
       (every? #(contains? set2 %) set1)))

(defn superset?
  "Is set1 a superset of set2?"
  [set1 set2]
  (and (>= (count set1) (count set2))
       (every? #(contains? set1 %) set2)))

;; ---- Map operations ----

(defn select-keys
  "Returns a map containing only those entries in map whose key is in keys"
  [map keyseq]
  (reduce (fn [ret k]
            (if (contains? map k)
              (assoc ret k (get map k))
              ret))
          {} keyseq))

;; ---- Sequence operations ----

(defn into
  "Returns a new coll consisting of to with all of the items of from conjoined."
  [to from]
  (reduce conj to from))

(defn keep
  "Returns a lazy sequence of the non-nil results of (f item)."
  [f coll]
  (filter identity (map f coll)))

;; ---- Map update ----

(defn update
  "Returns a map with the value at key updated by applying f to the current value."
  [m k f]
  (assoc m k (f (get m k))))

;; ---- Map entry access ----

(defn key
  "Returns the key of the map entry."
  [e]
  (get e :key))

(defn val
  "Returns the value of the map entry."
  [e]
  (get e :val))

;; ---- Sequence operations ----

(defn doall
  "Realizes all elements of a lazy sequence and returns it."
  [coll]
  (dorun coll)
  coll)

(defn into-array
  "Returns the collection as a vector."
  [coll]
  (vec coll))

;; ---- Trampoline ----
;; Implemented as Zig built-in because loop/recur is simplified
;; and doesn't support actual tail recursion in this VM

;; ---- Macros ----

(defmacro when-let
  "bindings => binding-form test

  When test is true, evaluates body with binding-form bound to the value of test."
  [bindings & body]
  (let [form (nth bindings 0)
        tst (nth bindings 1)]
    (list 'let
          (list '__when_let_temp tst)
          (list 'when '__when_let_temp
                (concat (list 'let (list form '__when_let_temp)) body)))))

(defmacro time
  "Evaluates expr and prints the time it took. Returns the value of expr."
  [expr]
  (list 'let
        (list '__start (list 'nano-time) '__ret expr)
        (list 'println (list 'str "Elapsed time: "
                              (list '/ (list '- (list 'nano-time) '__start) 1000000.0)
                              " msecs"))
        '__ret))
