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

;; cons is implemented as a Zig built-in for proper lazy-seq support
;; The Clojure version (concat (list x) xs) creates a concrete list
;; which breaks rest/seq semantics for lazy sequences.

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
  ;; doall is implemented as a Zig built-in for proper lazy-seq realization
  (doall* coll))

(defn into-array
  "Returns the collection as a vector."
  [coll]
  (vec coll))

;; ---- Trampoline ----
;; Implemented as Zig built-in because loop/recur is simplified
;; and doesn't support actual tail recursion in this VM

;; ---- Functional utilities ----

(defn constantly
  "Returns a function that takes any number of arguments and returns x."
  [x]
  (fn [& args] x))

(defn complement
  "Takes a fn f and returns a fn that takes the same arguments as f,
   has the same effects, if any, and returns the opposite truth value."
  [f]
  (fn [& args] (not (apply f args))))

;; ---- Collection utilities ----

(defn empty
  "Returns an empty collection of the same category as coll, or nil."
  [coll]
  (cond
    (list? coll) ()
    (vector? coll) []
    (map? coll) {}
    (set? coll) #{}
    (queue? coll) #queue()
    :else nil))

;; ---- Nested associative operations ----

(defn get-in-helper [m ks]
  (if (seq ks)
    (if (map? m)
      (get-in-helper (get m (first ks)) (rest ks))
      nil)
    m))

(defn get-in
  "Returns the value in a nested associative structure,
   where ks is a sequence of keys. Returns nil if the key is not present."
  [m ks]
  (get-in-helper m ks))

(defn assoc-in
  "Associates a value in a nested associative structure, where ks is a
   sequence of keys and v is the new value. If any levels do not exist,
   hash-maps will be created."
  [m ks v]
  (if (empty? (rest ks))
    (assoc m (first ks) v)
    (assoc m (first ks) (assoc-in (or (get m (first ks)) {}) (rest ks) v))))

;; ---- Map construction ----

(defn zipmap-helper [ks vs m]
  (if (and (seq ks) (seq vs))
    (zipmap-helper (rest ks) (rest vs) (assoc m (first ks) (first vs)))
    m))

(defn zipmap
  "Returns a map with the keys mapped to the corresponding vals."
  [keys vals]
  (zipmap-helper keys vals {}))

;; ---- Sequence operations ----

(defn interpose
  "Returns a lazy seq of the elements of coll separated by sep."
  [sep coll]
  (rest (mapcat (fn [x] (list sep x)) coll)))

(defn take-while
  "Returns a lazy sequence of successive items from coll for which (pred item) returns logical true."
  [pred coll]
  (lazy-seq
    (when-let [s (seq coll)]
      (if (pred (first s))
        (cons (first s) (take-while pred (rest s)))
        nil))))

(defn partition
  "Returns a lazy sequence of lists of n elements each, at intervals
   of step. Returns nil if there are fewer than n elements remaining."
  [n coll]
  (when (seq coll)
    (let [head (take n coll)
          tail (drop n coll)]
      (if (= (count head) n)
        (lazy-seq (cons head (partition n tail)))
        nil))))

;; ---- Macros ----

(defmacro when-not
  "Evaluates test. If logical false, evaluates body in an implicit do."
  [test & body]
  (list 'if test nil (cons 'do body)))

(defmacro when-some
  "bindings => binding-form test

   When test is not nil, evaluates body with binding-form bound to the
   value of test."
  [bindings & body]
  (let [form (nth bindings 0)
        tst (nth bindings 1)]
    (list 'let
          (list '__temp tst)
          (list 'if (list 'nil? '__temp)
                nil
                (concat (list 'let (list form '__temp)) body)))))

(defmacro if-let
  "bindings => binding-form test

  If test is true, evaluates then with binding-form bound to the value of
  test, if not, yields else."
  [bindings then else]
  (let [form (nth bindings 0)
        tst (nth bindings 1)]
    (list 'let
          (list '__temp tst)
          (list 'if '__temp
                (concat (list 'let (list form '__temp)) (list then))
                else))))

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

(defmacro doseq
  "Repeatedly executes body for side-effects. Returns nil."
  [seq-exprs & body]
  (letfn [(step [exprs]
            (if (empty? exprs)
              (concat (list 'do) body)
              (let [k (first exprs)
                    v (second exprs)
                    s (gensym "s")
                    sf (step (rest (rest exprs)))]
                (list 'loop
                      (list s (list 'seq v))
                      (list 'when
                            s
                            (list 'let
                                  (list k (list 'first s))
                                  sf)
                            (list 'recur
                                  (list 'seq
                                        (list 'rest s))))))))]
    (step (seq seq-exprs))))

(defmacro when-first
  "bindings => x xs

  Roughly the same as (when (seq xs) (let [x (first xs)] body)) but xs is evaluated only once."
  [bindings & body]
  (let [x (nth bindings 0)
        xs (nth bindings 1)
        s-gensym (gensym "s")]
    `(when-let [~s-gensym (seq ~xs)]
       (let [~x (first ~s-gensym)]
         ~@body))))

(defmacro for
  "List comprehension. Supports :when and :while modifiers."
  [seq-exprs body-expr]
  (let [exprs (seq seq-exprs)
        bind (first exprs)
        coll (second exprs)
        rest-exprs (drop 2 exprs)
        first-key (first rest-exprs)
        has-when (and first-key (= first-key :when))
        has-while (and first-key (= first-key :while))
        test-expr (when (or has-when has-while) (second rest-exprs))
        effective-coll (cond
                         has-when (list 'filter (list 'fn (list bind) test-expr) coll)
                         has-while (list 'take-while (list 'fn (list bind) test-expr) coll)
                         :else coll)
        next-binds (if (or has-when has-while)
                     (drop 2 rest-exprs)
                     rest-exprs)]
    (if (empty? next-binds)
      (list 'map (list 'fn (list bind) body-expr) effective-coll)
      (let [nb (first next-binds)
            nc (second next-binds)
            rest-for (list 'for (concat (list nb nc) (drop 2 next-binds)) body-expr)]
        (list 'mapcat (list 'fn (list bind) rest-for) effective-coll)))))

;; ---- Condition/predicate helpers ----

(defn some?
  "Returns true if x is not nil, false otherwise."
  [x] (not (nil? x)))

(defn boolean
  "Coerce to boolean."
  [x] (if x true false))

(defn not-any?
  "Returns true if (some f coll) is logical false."
  [f coll] (not (some f coll)))

