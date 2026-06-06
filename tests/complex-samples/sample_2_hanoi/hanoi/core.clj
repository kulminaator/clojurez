(ns hanoi.core)

;; Helper function to print the current board state clearly
(defn print-state [state]
  (println "Current State:")
  (println "  Peg A:" (get state :A))
  (println "  Peg B:" (get state :B))
  (println "  Peg C:" (get state :C))
  (println "----------------------"))

;; Moves a single disk from the 'from' peg to the 'to' peg in the state map
(defn move-disk [state from to]
  (let [disk (last (get state from))             ;; Get the top disk
        new-from (pop (get state from))          ;; Remove it from the source peg
        new-to (conj (get state to) disk)        ;; Add it to the destination peg
        new-state (assoc state from new-from to new-to)] ;; Update the state map
    (println "Moving disk" disk "from" from "to" to)
    (print-state new-state)
    new-state))                                  ;; Return the new state for the next step

;; Recursive function that solves the puzzle and passes the state along
(defn hanoi [n from to helper state]
  (if (= n 1)
    (move-disk state from to)
    (let [state1 (hanoi (dec n) from helper to state)
          state2 (move-disk state1 from to)
          state3 (hanoi (dec n) helper to from state2)]
      state3)))

;; Main function to initialize and run the simulation
(defn run-hanoi [num-disks]
  ;; Disks are represented by numbers, e.g., [3 2 1] (largest to smallest)
  (let [initial-state {:A (vec (reverse (range 1 (inc num-disks))))
                       :B []
                       :C []}]
    (println "=== INITIAL STATE ===")
    (print-state initial-state)
    
    (let [final-state (hanoi num-disks :A :C :B initial-state)]
      (println "=== FINAL SOLUTION STATE ===")
      (print-state final-state))))

;; Run the program for 3 disks
(run-hanoi 3)
