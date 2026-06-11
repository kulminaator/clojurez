;; Queues: literals, conj, pop, peek, queue?, count
(load-file "tests/clj/clj_test_helper.clj")

(check "queue literal" #queue(1 2 3) '#queue(1 2 3))
(check "queue empty" #queue() '#queue())
(check "conj queue" (conj #queue(1 2) 3) '#queue(1 2 3))
(check "pop queue" (pop #queue(1 2 3)) '#queue(2 3))
(check "peek queue" (peek #queue(1 2 3)) 1)
(check "queue?" (queue? #queue(1)) true)
(check "count queue" (count #queue(1 2 3)) 3)

(print-summary)
