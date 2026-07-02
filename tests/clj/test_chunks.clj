;; Chunked sequence tests
(load-file "tests/clj/clj_test_helper.clj")

;; chunked-seq? predicate
(check-true "chunked-seq? on range seq" (chunked-seq? (seq (range 1 100))))
(check-false "chunked-seq? on list" (chunked-seq? (list 1 2 3)))
(check-false "chunked-seq? on vector" (chunked-seq? [1 2 3]))
(check-false "chunked-seq? on nil" (chunked-seq? nil))
(check-false "chunked-seq? on integer" (chunked-seq? 42))

;; chunk-first
(check "chunk-first type" (type (chunk-first (seq (range 1 100)))) :chunk)
(check "chunk-first count" (count (chunk-first (seq (range 1 100)))) 32)

;; chunk-rest
(check "chunk-rest type" (type (chunk-rest (seq (range 1 100)))) :lazy_seq)

;; chunk-next
(check "chunk-next type" (type (chunk-next (seq (range 1 100)))) :lazy_seq)

;; chunk-cons
(check "chunk-cons type" (type (chunk-cons (chunk-first (seq (range 1 100))) nil)) :chunked_cons)
(check-true "chunk-cons creates chunked-seq" (chunked-seq? (chunk-cons (chunk-first (seq (range 1 100))) nil)))

;; chunk-buffer, chunk-append, chunk
(check "chunk-buffer type" (type (chunk-buffer 10)) :vector)
(check "chunk-buffer empty" (chunk-buffer 10) [])
(check "chunk-append" (chunk-append [] 1) [1])
(check "chunk-append multiple" (chunk-append (chunk-append [] 1) 2) [1 2])
(check "chunk type" (type (chunk [1 2 3])) :chunk)
(check "chunk count" (count (chunk [1 2 3])) 3)

;; chunk-cons with empty chunk returns rest
(check "chunk-cons empty chunk" (chunk-cons (chunk []) nil) nil)

;; Filter produces chunked output for chunked input
(check-true "filter of range is chunked" (chunked-seq? (seq (filter even? (range 1 100)))))
(check "filter of range values" (vec (filter even? (range 1 11))) [2 4 6 8 10])

;; Filter on list produces lazy-seq (cons-based)
(check "filter of list values" (vec (filter even? (list 1 2 3 4 5 6))) [2 4 6])

;; Map produces chunked output for chunked input
(check-true "map of range is chunked" (chunked-seq? (seq (map inc (range 1 100)))))

;; Reduce works with chunked sequences
(check "reduce + range" (reduce + (range 1 11)) 55)
(check "reduce + range with init" (reduce + 0 (range 1 11)) 55)
(check "reduce + large range" (reduce + (range 1 10001)) 50005000)

;; Reduce works with filter (chunked input)
(check "reduce + filter even" (reduce + (filter even? (range 1 101))) 2550)

;; Reduce works with map
(check "reduce + map inc" (reduce + (map inc (range 1 11))) 65)

;; Reduce works with lazy-seq
(check "reduce lazy-seq" (reduce + (lazy-seq (list 1 2 3 4 5))) 15)
(check "reduce lazy-seq with init" (reduce + 0 (lazy-seq (list 1 2 3 4 5))) 15)

;; Reduce with conj
(check "reduce conj range" (reduce conj [] (range 1 6)) [1 2 3 4 5])

;; Reduce with reduced wrapper
(check "reduce reduced early" (reduce (fn [acc x] (if (> x 3) (reduced acc) (+ acc x))) 0 (range 1 10)) 6)

;; Nested map/filter
(check "nested map filter" (vec (map inc (filter even? (range 1 11)))) [3 5 7 9 11])

;; Count with chunked sequences
(check "count range" (count (range 1 10001)) 10000)
(check "count filter range" (count (filter even? (range 1 101))) 50)

;; First/rest with chunked sequences
(check "first range seq" (first (seq (range 1 100))) 1)
(check "second range seq" (second (seq (range 1 100))) 2)

;; Take with chunked sequences
(check "take range" (vec (take 5 (range 1 100))) [1 2 3 4 5])

;; Drop with chunked sequences
(check "drop range" (vec (take 5 (drop 3 (range 1 100)))) [4 5 6 7 8])
