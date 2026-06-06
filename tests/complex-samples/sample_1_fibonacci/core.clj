(defn fibonacci [n]
  (->> [0 1]
       (iterate (fn [[a b]] [b (+ a b)]))
       (map first)
       (take n)))

;; Call the function for the first 10 numbers
(println (fibonacci 10))
