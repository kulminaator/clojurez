(ns hanoi.core)

;; Collects moves as a sequence of [disk from to] triples
;; instead of printing them, avoiding linebreak issues on Windows.

;; Moves a single disk and records the move
(defn move-disk [state from to moves]
  (let [disk (last (get state from))
        new-from (pop (get state from))
        new-to (conj (get state to) disk)
        new-state (assoc state from new-from to new-to)]
    {:state new-state
     :moves (conj moves [disk from to])}))

;; Recursive function that solves the puzzle and collects moves
(defn hanoi [n from to helper state moves]
  (if (= n 1)
    (move-disk state from to moves)
    (let [step1 (hanoi (dec n) from helper to state moves)
          step2 (move-disk (get step1 :state) from to (get step1 :moves))
          step3 (hanoi (dec n) helper to from (get step2 :state) (get step2 :moves))]
      step3)))

;; Validate the solution: check that all moves are legal and final state is correct
(defn validate-hanoi [num-disks result]
  (let [moves (get result :moves)
        final-state (get result :state)
        expected-moves (if (= num-disks 3)
                         [[1 :A :C] [2 :A :B] [1 :C :B] [3 :A :C]
                          [1 :B :A] [2 :B :C] [1 :A :C]]
                         nil)
        correct-final (and (= (get final-state :A) [])
                           (= (get final-state :B) [])
                           (= (get final-state :C) (vec (reverse (range 1 (inc num-disks))))))]
    (if (and correct-final
             (= (count moves) (if expected-moves (count expected-moves) nil))
             (if expected-moves (= moves expected-moves) true))
      (println "HANOI_OK")
      (do
        (println "HANOI_FAIL")
        (println "  moves:" moves)
        (println "  final-state:" final-state)))))

;; Run the program for 3 disks and validate
(let [initial-state {:A [3 2 1] :B [] :C []}
      result (hanoi 3 :A :C :B initial-state [])]
  (validate-hanoi 3 result))
