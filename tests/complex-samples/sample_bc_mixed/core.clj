;; Sample file with mixed eligible and non-eligible functions

(defn pure-add [a b]
  (+ a b))

(defn impure-print [x]
  (println x))

(defn pure-compare [a b]
  (> a b))
