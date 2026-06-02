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
