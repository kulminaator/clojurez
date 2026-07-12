;; Performance benchmarks for ClojureZ
;; Run with: ./zig-out/bin/clojurez tests/clj/test_performance.clj
;;
;; This file measures timing for key operations. It is NOT a correctness
;; test — correctness is covered by the existing test suites.
;; Use this to track performance regressions across optimization phases.

(defn bench
  "Run f, print elapsed milliseconds and result."
  [name f]
  (let [start (zig.core/nano-time)
        result (f)
        end (zig.core/nano-time)]
    (println name "elapsed-ms:" (/ (- end start) 1000000.0) "result:" result)
    result))

;; ------------------------------------------------------------------
;; Benchmark: reduce over range (no map)
;; This exercises the reduce fast path for concrete integer sequences.
;; ------------------------------------------------------------------
(bench "reduce-range-250k"
  #(reduce + (range 1 250000)))

;; ------------------------------------------------------------------
;; Benchmark: reduce + map inc
;; This is the canonical benchmark — map inc creates 250K function calls,
;; each going through the bytecode VM. The bottleneck is function call
;; machinery (Env.put → HAMT allocation) and bytecode VM overhead.
;; ------------------------------------------------------------------
(bench "reduce-map-inc-250k"
  #(reduce + (map inc (range 1 250000))))

;; ------------------------------------------------------------------
;; Benchmark: reduce + map identity
;; Same as above but with identity instead of inc. If this is similar
;; to map-inc, the bottleneck is the function call machinery, not
;; the arithmetic body.
;; ------------------------------------------------------------------
(bench "reduce-map-identity-250k"
  #(reduce + (map identity (range 1 250000))))

;; ------------------------------------------------------------------
;; Benchmark: loop/recur sum
;; Tests the AST interpreter path for loop/recur.
;; When loop/recur compiles to bytecode, this should be dramatically faster.
;; ------------------------------------------------------------------
(defn sum-loop [e]
  (loop [i 1 acc 0]
    (if (< i e)
      (recur (+ i 1) (+ acc i))
      acc)))
(bench "loop-recur-10k"
  #(sum-loop 10000))

;; ------------------------------------------------------------------
;; Benchmark: user-defined + wrapper
;; Tests a custom function that wraps +. This exercises the same
;; bytecode path as inc but with a user-defined function.
;; ------------------------------------------------------------------
(defn my-add [a b] (+ a b))
(bench "reduce-my-add-map-inc-250k"
  #(reduce my-add (map inc (range 1 250000))))

;; ------------------------------------------------------------------
;; Benchmark: reduce with fn (anonymous)
;; Tests the slow path — anonymous fn in reduce body.
;; This is the worst case since the fn cannot be bytecode-compiled
;; (it contains a "real" function call).
;; ------------------------------------------------------------------
(bench "reduce-fn-inc-250k"
  #(reduce (fn [acc _] (+ acc 1)) 0 (range 1 250000)))
