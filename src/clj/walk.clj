; walk.clj - generic tree walker with replacement
; Adapted from original Clojure walk.clj for ClojureZ

(ns clojure.walk)

(defn walk
  "Traverses form, an arbitrary data structure. inner and outer are
   functions. Applies inner to each element of form, building up a
   data structure of the same type, then applies outer to the result.
   Recognizes all Clojure data structures."
  [inner outer form]
  (cond
    (list? form) (outer (with-meta (apply list (doall (map inner form))) (meta form)))
    (vector? form) (outer (with-meta (vec (doall (map inner form))) (meta form)))
    (map? form) (outer (with-meta
      (reduce (fn [acc k] (assoc acc (inner k) (inner (get form k)))) {} (keys form))
      (meta form)))
    (set? form) (outer (with-meta
      (into (empty form) (doall (map inner (into [] form))))
      (meta form)))
    (record? form) (outer (with-meta
      (reduce (fn [acc k] (assoc acc k (inner (get form k)))) {} (keys form))
      (meta form)))
    (queue? form) (outer (into (empty form) (doall (map inner (into [] form)))))
    (seq? form) (outer (with-meta (vec (doall (map inner (into [] form)))) (meta form)))
    :else (outer form)))

(defn postwalk
  "Performs a depth-first, post-order traversal of form. Calls f on
   each sub-form, uses f's return value in place of the original.
   Recognizes all Clojure data structures."
  [f form]
  (walk (partial postwalk f) f form))

(defn prewalk
  "Like postwalk, but does pre-order traversal."
  [f form]
  (walk (partial prewalk f) identity (f form)))

(defn keywordize-keys
  "Recursively transforms all map keys from strings to keywords."
  [m]
  (postwalk (fn [x]
              (if (map? x)
                (reduce (fn [acc k]
                          (assoc acc
                            (if (string? k) (keyword k) k)
                            (get x k)))
                        {} (keys x))
                x))
            m))

(defn stringify-keys
  "Recursively transforms all map keys from keywords to strings."
  [m]
  (postwalk (fn [x]
              (if (map? x)
                (reduce (fn [acc k]
                          (assoc acc
                            (if (keyword? k) (name k) k)
                            (get x k)))
                        {} (keys x))
                x))
            m))

(defn prewalk-replace
  "Recursively transforms form by replacing keys in smap with their
   values. Like clojure/replace but works on any data structure.
   Does replacement at the root of the tree first."
  [smap form]
  (prewalk (fn [x] (if (contains? smap x) (smap x) x)) form))

(defn postwalk-replace
  "Recursively transforms form by replacing keys in smap with their
   values. Like clojure/replace but works on any data structure.
   Does replacement at the leaves of the tree first."
  [smap form]
  (postwalk (fn [x] (if (contains? smap x) (smap x) x)) form))
