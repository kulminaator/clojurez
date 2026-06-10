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

(defn pos-int? [n]
  (and (int? n) (pos? n)))

(defn neg-int? [n]
  (and (int? n) (neg? n)))

(defn nat-int? [n]
  (and (int? n) (not (neg? n))))

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

(defn cons
  "Returns a list/seq with x as the first element and xs as the rest.
   Unlike (concat (list x) xs), this creates a proper cons cell that
   preserves lazy-seq semantics." [x xs]
  (zig.core/cons x xs))

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

(defn doall*
  "Internal: realizes all elements of a lazy sequence and returns it."
  [coll]
  (zig.core/doall* coll))

(defn doall
  "Realizes all elements of a lazy sequence and returns it."
  [coll]
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

;; ---- Set construction ----

(defn hash-set
  "Returns a set containing the given args."
  [& args]
  (set args))

;; ---- Random functions ----

(defn rand-nth
  "Return a random element of the (sequential) collection. O(1) when possible."
  [coll]
  (nth coll (rand-int (count coll))))

(defn shuffle
  "Return a random permutation of coll. Uses Fisher-Yates shuffle."
  [coll]
  (let [v (vec coll)
        n (count v)]
    (loop [i n result v]
      (if (zero? i)
        result
        (let [j (rand-int i)
              tmp (nth result j)
              result (assoc result j (nth result (- i 1)))
              result (assoc result (- i 1) tmp)]
          (recur (dec i) result))))))

;; ---- Sequence operations ----

(defn drop-last
  "Return a lazy sequence of all but the last n (default 1) items in coll."
  ([coll] (drop-last 1 coll))
  ([n coll]
   (take (- (count coll) n) coll)))

(defn take-last
  "Returns a seq of the last n items in coll."
  [n coll]
  (reverse (take n (reverse coll))))

(defn drop-while
  "Returns a lazy sequence of the items in coll starting from the first item
   for which (pred item) returns logical false."
  [pred coll]
  (lazy-seq
    (when-let [s (seq coll)]
      (if (pred (first s))
        (drop-while pred (rest s))
        s))))

(defn cycle
  "Returns a lazy (infinite) sequence of the items in coll, repeated indefinitely."
  [coll]
  (zig.core/cycle coll))

(defn repeat
  "Returns a lazy (infinite) sequence of x. Also accepts count: (repeat n x)."
  ([x]
   (lazy-seq
     (cons x (repeat x))))
  ([n x]
   (if (pos? n)
     (lazy-seq
       (cons x (repeat (dec n) x)))
     ())))

(defn replicate
  "Returns a lazy sequence of n copies of x. Same as (repeat n x)."
  [n x]
  (repeat n x))

(defn split-at
  "Returns a vector of [(take n coll) (drop n coll)]."
  [n coll]
  [(take n coll) (drop n coll)])

(defn split-with
  "Returns a vector of [(take-while pred coll) (drop-while pred coll)]."
  [pred coll]
  [(take-while pred coll) (drop-while pred coll)])

;; ---- Comparator ----

(defn comparator
  "Returns a comparator (a function of two arguments) that imposes an ordering
   based on f. Returns a function of two arguments that returns -1, 0, or 1."
  [f]
  (fn [a b]
    (if (= a b)
      0
      (if (f a b)
        -1
        1))))

;; ---- Additional sequence operations ----

(defn take-nth
  "Returns a lazy seq of every nth item in coll."
  [n coll]
  (when-let [s (seq coll)]
    (lazy-seq
      (cons (first s) (take-nth n (drop (- n 1) (rest s)))))))

(defn interleave
  "Returns a lazy seq of the first item in each coll, then the second etc."
  ([] ())
  ([c1] (lazy-seq c1))
  ([c1 c2]
     (lazy-seq
       (when-let [s1 (seq c1)]
         (when-let [s2 (seq c2)]
           (cons (first s1) (cons (first s2) (interleave (rest s1) (rest s2)))))))))

(defn partition-all
  "Returns a lazy sequence of lists like partition, but may include
   partitions with fewer than n items at the end."
  [n coll]
  (when-let [s (seq coll)]
    (lazy-seq
      (cons (take n s) (partition-all n (drop n s))))))

(defn partition-by
  "Applies f to each value in coll, splitting it each time f returns a
   new value. Returns a lazy seq of partitions."
  [f coll]
  (when-let [s (seq coll)]
    (let [k (f (first s))
          run (take-while (fn [x] (= (f x) k)) s)]
      (lazy-seq
        (cons (vec run) (partition-by f (drop (count run) s)))))))

(defn frequencies
  "Returns a map from distinct items in coll to the number of times
  they appear."
  [coll]
  (reduce (fn [counts x]
            (assoc counts x (inc (or (get counts x) 0))))
          {} coll))

;; ---- Predicate composition ----

(defn every-pred
  "Takes a set of predicates and returns a function f that returns true if all of its
  composing predicates return a logical true value against all of its arguments.
  Note that f is short-circuiting in that it will stop execution on the first
  argument that triggers a logical false result against the original predicates."
  [& preds]
  (fn [& args]
    (every? (fn [p] (apply p args)) preds)))

(defn some-fn
  "Takes a set of predicates and returns a function f that returns the first logical true value
  returned by one of its composing predicates against any of its arguments,
  else it returns logical false. Note that f is short-circuiting in that it will
  stop execution on the first argument that triggers a logical true result against
  the original predicates."
  [& preds]
  (fn [& args]
    (some (fn [p] (apply p args)) preds)))

;; ---- Counting ----
;; bounded-count is implemented as a Zig built-in for proper collection handling

;; ---- Sequence replacement ----
;; replace is implemented as a Zig built-in for proper collection handling

;; ---- Distinct elements (lazy) ----
;; distinct is implemented as a Zig built-in for proper lazy-seq handling

;; ---- Group by key function ----
;; group-by is implemented as a Zig built-in for proper map/vector handling

;; ---- Reductions (all intermediate reduce results) ----
;; reductions is implemented as a Zig built-in for proper lazy-seq handling

;; ---- Map with index ----
;; map-indexed is implemented as a Zig built-in for proper lazy-seq handling

;; ---- Sort operations ----

(defn sort
  "Returns a sorted sequence of the items in coll, sorted by compare.
   coll must support count and nth." [coll]
  (zig.core/sort coll))

(defn sort-by
  "Returns a sorted sequence of the items in coll, sorted by the comparison
   of (keyfn item). coll must support count and nth." [keyfn coll]
  (zig.core/sort-by keyfn coll))

;; ---- Keep with index ----
;; keep-indexed is implemented as a Zig built-in for proper lazy-seq handling

;; ---- Repeatedly ----
(defn repeatedly
  "Takes a function of no args, presumably with side effects, and
  returns an infinite (or length n if supplied) lazy sequence of calls
  to it."
  ([f] (lazy-seq (cons (f) (repeatedly f))))
  ([n f] (take n (repeatedly f))))

;; ---- Cat ----
(defn cat
  "Concatenate the contents of each collection into one sequence."
  [& colls]
  (apply concat colls))

;; ---- Dedupe ----
(defn dedupe
  "Returns a lazy sequence removing consecutive duplicates in coll."
  [coll]
  (lazy-seq
    (when-let [s (seq coll)]
      (cons (first s)
            (dedupe (drop-while (fn [x] (= x (first s))) (rest s)))))))

;; ---- Random Sample ----
(defn random-sample
  "Returns items from coll with random probability of prob (0.0 - 1.0)."
  [prob coll]
  (filter (fn [_] (< (rand) prob)) coll))

;; ---- Zig-delegated functions ----
;; These are thin wrappers that delegate to zig.core implementations.
;; The actual logic lives in Zig for performance or VM-level access.

(defn iterate
  "Returns a lazy (infinite) sequence of x, (f x), (f (f x)) etc."
  [f x]
  (zig.core/iterate f x))

(defn ==
  "Numeric equality (type-independent). Returns true if all args are
   numerically equal (e.g. (== 1 1.0) => true). For non-numeric args,
   falls back to value equality."
  [& args]
  (apply zig.core/== args))

(defn =
  "Returns true if all args are equal (value equality). Requires at least 2 args."
  [& args]
  (apply zig.core/= args))

(defn !=
  "Returns true if not all args are equal. Requires at least 2 args."
  [& args]
  (apply zig.core/!= args))

(defn not=
  "Returns true if not all args are equal. Alias for !=. Requires at least 2 args."
  [& args]
  (apply zig.core/not= args))

(defn <
  "Returns true if numerically ascending (strictly less than). Requires at least 2 args."
  [& args]
  (apply zig.core/< args))

(defn >
  "Returns true if numerically descending (strictly greater than). Requires at least 2 args."
  [& args]
  (apply zig.core/> args))

(defn <=
  "Returns true if numerically ascending (less than or equal). Requires at least 2 args."
  [& args]
  (apply zig.core/<= args))

(defn >=
  "Returns true if numerically descending (greater than or equal). Requires at least 2 args."
  [& args]
  (apply zig.core/>= args))

;; ---- Comparison ----

(defn compare
  "Compare two values. Returns -1, 0, or 1 indicating less-than, equal-to,
   or greater-than. Supports numbers, strings, and collections."
  [x y]
  (zig.core/compare x y))

(defn rationalize
  "Returns the simplest ratio that is within 0.5 of mag.
   For integers, returns the integer. For floats, returns a ratio.
   For ratios, returns the ratio."
  [x]
  (zig.core/rationalize x))

(defn identical?
  "Returns true if x and y are the same object (by identity/reference),
   not merely equal in value."
  [x y]
  (zig.core/identical? x y))

;; ---- Map operations ----

(defn get
  "Returns the value mapped to key, not-found (nil) if not present."
  [& args]
  (apply zig.core/get args))

;; ---- Collection operations ----

(defn conj
  "Conj[oin]. Returns a new collection with the items added.
   (conj item) returns a list with item.
   (conj coll item) adds item to coll."
  [& args]
  (apply zig.core/conj args))

(defn str
  "With no args, returns the empty string. With one arg, returns
   (.toString arg). With more args, returns the concatenation of
   the .toString of each."
  [& args]
  (apply zig.core/str args))

(defn nano-time
  "Returns current instant's nanosecond time (monotonic clock).
   Useful for measuring elapsed time."
  []
  (zig.core/nano-time))

(defn rand-int
  "Returns a random integer between 0 (inclusive) and n (exclusive)."
  [n]
  (zig.core/rand-int n))

(defn gensym
  "Makes a new symbol with a unique name. If prefix is supplied, the name
   starts with prefix, otherwise it starts with 'G'."
  ([] (zig.core/gensym))
  ([prefix] (zig.core/gensym prefix)))

(defn distinct
  "Returns a lazy sequence of the distinct elements in coll.
   Preserves order of first occurrence."
  [coll]
  (zig.core/distinct coll))

(defn reduced
  "Wrap a value in Reduced to signal early termination of a reduction."
  [v]
  (zig.core/reduced v))

(defn reduced?
  "Returns true if v is a Reduced wrapper."
  [v]
  (zig.core/reduced? v))

(defn keys
  "Returns a sequence of the keys in the map."
  [m]
  (zig.core/keys m))

(defn vals
  "Returns a sequence of the values in the map."
  [m]
  (zig.core/vals m))

(defn rand
  "Returns a random floating point number between 0 (inclusive) and 1.0 (exclusive).
   With an argument n, returns a random float between 0 and n."
  ([] (zig.core/rand))
  ([n] (zig.core/rand n)))

(defn pop
  "Returns a new collection with the last item removed.
   For vectors, removes the last element. For lists, removes the first."
  [coll]
  (zig.core/pop coll))

(defn peek
  "Returns the last item of a collection without removing it.
   For vectors, returns the last element. For lists/queues, returns the first."
  [coll]
  (zig.core/peek coll))

(defn reverse
  "Returns a seq of the items in coll in reverse order."
  [coll]
  (zig.core/reverse coll))

(defn set
  "Returns a set of the items in coll."
  [coll]
  (zig.core/set coll))

(defn disj
  "Returns a new set with the items removed."
  [& args]
  (apply zig.core/disj args))

;; ---- Map operations ----

(defn assoc
  "Associates key(s) with value(s) in a map, returning a new map."
  [& args]
  (apply zig.core/assoc args))

(defn merge
  "Merges multiple maps into one. Later maps override earlier ones for duplicate keys."
  [& args]
  (apply zig.core/merge args))

(defn hash-map
  "Returns a map with the given key-value pairs."
  [& args]
  (apply zig.core/hash-map args))

(defn dissoc
  "Returns a new map without the given keys."
  [& args]
  (apply zig.core/dissoc args))

;; ---- Collection operations ----

(defn contains?
  "Returns true if key is present in the collection."
  [coll key]
  (zig.core/contains? coll key))

(defn last
  "Returns the last item in a collection."
  [coll]
  (zig.core/last coll))

(defn range
  "Returns a lazy sequence of integers from start (inclusive) to end (exclusive),
   with optional step. (range end) starts from 0. (range start end) uses step 1."
  ([end] (zig.core/range 0 end 1))
  ([start end] (zig.core/range start end 1))
  ([start end step] (zig.core/range start end step)))

;; ---- Sequence operations ----

(defn replace
  "Returns a lazy sequence with elements replaced using the given map."
  [smap coll]
  (zig.core/replace smap coll))

(defn group-by
  "Returns a map of key -> (list of items) grouped by the result of f."
  [f coll]
  (zig.core/group-by f coll))

(defn bounded-count
  "Returns the count of coll if it is <= n, else returns n."
  [n coll]
  (zig.core/bounded-count n coll))

;; ---- Arithmetic ----
;; Wrapped Zig builtins. For max performance in tight loops, use zig.core/+ etc.
;; Wrapper overhead: ~16x for computation, plus GC amplification.

(defn +
  "Returns the sum of nums. (+) returns 0."
  ([] (zig.core/+))
  ([a] (zig.core/+ a))
  ([a b] (zig.core/+ a b))
  ([a b & args] (apply zig.core/+ a b args)))

(defn -
  "Subtracts nums from the first. With one arg, returns its negation. (-) throws."
  [& args]
  (apply zig.core/- args))

(defn *
  "Returns the product of nums. (*) returns 1."
  ([] (zig.core/*))
  ([a] (zig.core/* a))
  ([a b] (zig.core/* a b))
  ([& args] (apply zig.core/* args)))

(defn /
  "Divides nums. (/ x) returns the reciprocal. (/) throws."
  [& args]
  (apply zig.core// args))

(defn rem
  "Returns remainder of dividing numerator by denominator.
   Sign follows the dividend."
  [num den]
  (zig.core/rem num den))

(defn mod
  "Returns modulus of numerator and denominator.
   Sign follows the divisor."
  [num den]
  (zig.core/mod num den))

(defn quot
  "Integer division. Truncates toward zero."
  [num den]
  (zig.core/quot num den))

;; ---- Type predicates ----

(defn nil?
  "Returns true if x is nil."
  [x]
  (zig.core/nil? x))

(defn number?
  "Returns true if x is a number (integer, float, bigint, ratio, or decimal)."
  [x]
  (zig.core/number? x))

(defn string?
  "Returns true if x is a string."
  [x]
  (zig.core/string? x))

(defn utf8-valid?
  "Returns true if the string is valid UTF-8."
  [s]
  (zig.core/utf8-valid? s))

;; ---- Sequence operations ----

(defn count
  "Returns the number of items in a collection. For strings, returns code point count."
  [coll]
  (zig.core/count coll))

(defn first
  "Returns the first item of a collection, or nil if empty."
  [coll]
  (zig.core/first coll))

;; ---- Set predicates ----

(defn set?
  "Returns true if x is a set."
  [x]
  (zig.core/set? x))

;; ---- Sequence operations ----

(defn rest
  "Returns a possibly-empty sequence of the items after the first."
  [coll]
  (zig.core/rest coll))

(defn nth
  "Returns the item at index. Returns nil if index is out of bounds."
  ([coll index]
   (zig.core/nth coll index))
  ([coll index not-found]
   (zig.core/nth coll index not-found)))

(defn list
  "Returns a list of the args."
  [& args]
  (apply zig.core/list args))

(defn vec
  "Returns a vector of the args, or converts a collection to a vector."
  [& args]
  (apply zig.core/vec args))

(defn concat
  "Returns a lazy sequence consisting of the items in each collection, in order."
  [& args]
  (apply zig.core/concat args))

(defn seq
  "Returns a sequence of the collection. Returns nil if the collection is empty."
  [coll]
  (zig.core/seq coll))

;; ---- I/O ----

(defn print
  "Prints the string representation of the args to stdout."
  [& args]
  (apply zig.core/print args))

(defn println
  "Prints the string representation of the args to stdout, followed by a newline."
  [& args]
  (apply zig.core/println args))

;; ---- Atoms ----

(defn atom
  "Creates and returns an Atom with an initial value and no validators or watchers."
  [v]
  (zig.core/atom v))

;; ---- Bitwise operations ----

(defn bit-and
  "Returns the bitwise AND of the args."
  [& args]
  (apply zig.core/bit-and args))

(defn bit-or
  "Returns the bitwise OR of the args."
  [& args]
  (apply zig.core/bit-or args))

(defn bit-not
  "Returns the bitwise NOT of the arg."
  [x]
  (zig.core/bit-not x))

(defn bit-xor
  "Returns the bitwise XOR of the args."
  [& args]
  (apply zig.core/bit-xor args))

(defn bit-and-not
  "Returns the bitwise AND NOT (clear bits in x that are set in y)."
  [x y]
  (zig.core/bit-and-not x y))

(defn bit-clear
  "Clears the bit at position n in x (sets it to 0)."
  [x n]
  (zig.core/bit-clear x n))

(defn bit-set
  "Sets the bit at position n in x (sets it to 1)."
  [x n]
  (zig.core/bit-set x n))

(defn bit-flip
  "Flips the bit at position n in x (0 becomes 1, 1 becomes 0)."
  [x n]
  (zig.core/bit-flip x n))

(defn bit-shift-left
  "Shifts the bits of x to the left by n positions."
  [x n]
  (zig.core/bit-shift-left x n))

(defn bit-shift-right
  "Shifts the bits of x to the right by n positions (arithmetic shift, preserves sign)."
  [x n]
  (zig.core/bit-shift-right x n))

(defn unsigned-bit-shift-right
  "Shifts the bits of x to the right by n positions (logical shift, fills with zeros)."
  [x n]
  (zig.core/unsigned-bit-shift-right x n))

(defn bit-test
  "Returns true if the bit at position n in x is set, false otherwise."
  [x n]
  (zig.core/bit-test x n))

;; ---- I/O ----

(defn spit
  "Writes the string content to a file, creating it if it doesn't exist."
  [filename content]
  (zig.core/spit filename content))

(defn slurp
  "Opens and reads the file from the given path, returning its contents as a string."
  [filename]
  (zig.core/slurp filename))

(defn read-line
  "Reads a line from stdin (or the input stream). Returns nil on EOF."
  []
  (zig.core/read-line))

;; ---- Atoms ----

(defn swap!
  "Atomically swaps the value of the atom to be: (apply f current-value & args)."
  [& args]
  (apply zig.core/swap! args))

(defn reset!
  "Reset the atom's value to new-val and return it."
  [a new-val]
  (zig.core/reset! a new-val))

(defn deref
  "Returns the current value of the atom or var."
  [v]
  (zig.core/deref v))

;; ---- Type predicates ----

(defn list?
  "Returns true if x is a list."
  [x]
  (zig.core/list? x))

(defn vector?
  "Returns true if x is a vector."
  [x]
  (zig.core/vector? x))

(defn map?
  "Returns true if x is a map."
  [x]
  (zig.core/map? x))

(defn symbol?
  "Returns true if x is a symbol."
  [x]
  (zig.core/symbol? x))

(defn keyword?
  "Returns true if x is a keyword."
  [x]
  (zig.core/keyword? x))

(defn true?
  "Returns true if x is the value true, false otherwise."
  [x]
  (zig.core/true? x))

(defn false?
  "Returns true if x is the value false, false otherwise."
  [x]
  (zig.core/false? x))

(defn fn?
  "Returns true if x is a function."
  [x]
  (zig.core/fn? x))

(defn queue?
  "Returns true if x is a queue."
  [x]
  (zig.core/queue? x))

(defn coll?
  "Returns true if x is a collection (list, vector, map, set, or queue)."
  [x]
  (zig.core/coll? x))

(defn sequential?
  "Returns true if x is a sequential collection (list or vector)."
  [x]
  (zig.core/sequential? x))

(defn int?
  "Returns true if x is a 64-bit integer."
  [x]
  (zig.core/int? x))

(defn integer?
  "Returns true if x is an integer (64-bit int or BigInt)."
  [x]
  (zig.core/integer? x))

(defn double?
  "Returns true if x is a double-precision floating point number."
  [x]
  (zig.core/double? x))

(defn float?
  "Returns true if x is a floating point number (float or double)."
  [x]
  (zig.core/float? x))

(defn NaN?
  "Returns true if x is a not-a-number (NaN) value."
  [x]
  (zig.core/NaN? x))

(defn infinite?
  "Returns true if x is positive or negative infinity."
  [x]
  (zig.core/infinite? x))

;; ---- Collection predicates ----

(defn empty?
  "Returns true if coll has no items. Different from (not coll) because both
   nil and false return true for not. nil is considered empty."
  [coll]
  (if (nil? coll) true (zig.core/empty? coll)))

(defn not-empty
  "Returns the first item of coll if it is not empty, nil otherwise."
  [coll]
  (zig.core/not-empty coll))

;; ---- Type conversion ----

(defn int
  "Coerce to 64-bit integer. Truncates floats, returns the value for integers."
  [x]
  (zig.core/int x))

(defn float
  "Coerce to floating point number. Returns the value for floats, converts integers."
  [x]
  (zig.core/float x))

(defn double
  "Coerce to double-precision floating point number."
  [x]
  (zig.core/double x))

(defn bigint
  "Coerce to arbitrary-precision integer. Truncates floats to integer part."
  [x]
  (zig.core/bigint x))

(defn bigdec
  "Coerce to arbitrary-precision decimal."
  [x]
  (zig.core/bigdec x))

(defn byte
  "Coerce to byte (truncates to 8 bits)."
  [x]
  (zig.core/byte x))

(defn short
  "Coerce to short (truncates to 16 bits)."
  [x]
  (zig.core/short x))

;; ---- Keyword construction ----

(defn keyword
  "Converts a string or symbol to a keyword. With two args, creates a namespaced keyword."
  ([name] (zig.core/keyword name))
  ([namespace name] (zig.core/keyword namespace name)))

;; ---- Conditional ----

(defn if-not
  "If test is logical false, evaluates then, else evaluates not-then (or nil if not-then omitted)."
  ([test then]
   (zig.core/if-not test then))
  ([test then not-then]
   (zig.core/if-not test then not-then)))

;; ---- Reduction helpers ----

(defn ensure-reduced
  "If v is a Reduced wrapper, returns it. Otherwise wraps v in Reduced."
  [v]
  (zig.core/ensure-reduced v))

(defn unreduced
  "If v is a Reduced wrapper, unwraps and returns the inner value. Otherwise returns v."
  [v]
  (zig.core/unreduced v))

;; ---- Sequence helpers ----

(defn next
  "Returns the rest of the collection after the first element, or nil if empty."
  [coll]
  (zig.core/next coll))

(defn nthnext
  "Returns the nth next of coll. (nthnext coll 1) is equivalent to (next coll)."
  [coll n]
  (if (<= n 0)
    (seq coll)
    (zig.core/nthnext n coll)))

;; ---- Sequence operations ----

(defn map
  "Returns a lazy sequence consisting of the result of applying f to the
   set of first items of each collection, followed by applying f to the set
   of second items in each sequence, and so on."
  [f coll]
  (zig.core/map f coll))

(defn mapcat
  "Returns a lazy sequence which is the concatenation of the results of applying f to the
   elements of the collections. f should return a collection."
  [f coll]
  (zig.core/mapcat f coll))

(defn reduce
  "f should be a function of 2 arguments. If val is not supplied, returns the
   result of applying f to the first 2 items in coll, then applying f to that
   result and the 3rd item, etc. If val is supplied, returns the result of
   applying f to val and the first item in coll, then applying f to that
   result and the 2nd item, etc."
  ([f coll] (zig.core/reduce f coll))
  ([f val coll] (zig.core/reduce f val coll)))

(defn filter
  "Returns a lazy sequence of the items in coll for which (pred item) returns logical true."
  [pred coll]
  (zig.core/filter pred coll))

(defn remove
  "Returns a lazy sequence of the items in coll for which (pred item) returns logical false."
  [pred coll]
  (zig.core/remove pred coll))

(defn flatten
  "Takes any nested combination of sequential things (lists, vectors, etc.)
   and returns the contents as a single, flat sequence."
  [x]
  (zig.core/flatten x))

(defn take
  "Returns a lazy sequence of the first n items in coll."
  [n coll]
  (zig.core/take n coll))

(defn drop
  "Returns a lazy sequence of all but the first n items in coll."
  [n coll]
  (zig.core/drop n coll))

(defn every?
  "Returns true if (pred x) is logical true for every x in coll, else false."
  [pred coll]
  (zig.core/every? pred coll))

(defn some
  "Returns the first logical true value of (pred x) for any x in coll, else nil."
  [pred coll]
  (zig.core/some pred coll))

(defn distinct?
  "Returns true if no two elements in the collection are equal."
  [coll]
  (zig.core/distinct? coll))

;; ---- Boolean ----

(defn not
  "Returns true if x is logical false, true otherwise."
  [x]
  (zig.core/not x))

;; ---- Functional utilities ----
;; apply: kept as global builtin (bootstrapping function — can't wrap without circular dep)

(defn comp
  "Returns a function that is the composition of the supplied functions."
  [& fns]
  (apply zig.core/comp fns))

(defn fnil
  "Returns a function that calls f with nil replaced by the supplied defaults."
  [f & defaults]
  (apply zig.core/fnil (vec (concat (list f) defaults))))

(defn juxt
  "Returns a function that calls each of the supplied functions and returns
   a vector of the results."
  [& fns]
  (apply zig.core/juxt fns))

(defn partial
  "Returns a function that is a partial application of f with the supplied args."
  [f & args]
  (apply zig.core/partial (vec (concat (list f) args))))

(defn trampoline
  "Calls f with the supplied args. If f returns a fn, calls that fn,
   repeating until a non-fn result is returned."
  [f & args]
  (apply zig.core/trampoline (vec (concat (list f) args))))

;; ---- Lazy sequence operations ----

(defn reductions
  "Returns a lazy sequence of the intermediate values of a reduction.
   With init, starts from init. Without init, starts from first element."
  ([f coll] (zig.core/reductions f coll))
  ([f init coll] (zig.core/reductions f init coll)))

(defn map-indexed
  "Returns a lazy sequence of ([i (f i x1)] for each item x1 and index i)."
  [f coll]
  (zig.core/map-indexed f coll))

(defn keep-indexed
  "Returns a lazy sequence of the non-nil results of (f i x)."
  [f coll]
  (zig.core/keep-indexed f coll))

