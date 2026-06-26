;; GC Stress Test — verifies manual garbage collection.
;;
;; Allocates significant temporary memory through repeated string
;; concatenation, then verifies that:
;;   1. Manual gc-sweep reduces memory below pre-sweep level
;;   2. Sweep count increases after collection
;;
;; Note: Auto-GC is disabled for file execution (OS reclaims memory on exit).
;; This test focuses on the manual sweep mechanism used by zig.core/gc-sweep.
;;
;; Only directional checks are used (no hardcoded byte thresholds)
;; so the test is robust across different builds and platforms.

;; Build a large string to stress the allocator.
(defn build-heavy [n]
  (reduce str (range 1 n)))

;; Heavy round: creates and discards large temporary strings.
(defn heavy-round []
  (build-heavy 1500)
  (build-heavy 1500)
  (build-heavy 1500))

;; Phase 1: Heavy allocation — multiple rounds of large temp strings.
(heavy-round)
(heavy-round)
(heavy-round)

;; Phase 2: Capture stats after heavy allocation.
(def s1 (zig.core/gc-stats))
(def peak1 (get s1 :peak-allocated))
(def sweeps1 (get s1 :sweep-count))
(def current1 (get s1 :current-allocated))

(println "=== GC Stress Test ===")
(println (str "peak-allocated:    " peak1))
(println (str "sweep-count:       " sweeps1))
(println (str "current-allocated: " current1))

;; Phase 3: Small allocation to add fresh GC objects.
(defn small-work []
  (str "hello " "world " "gc " "test"))

(small-work)
(small-work)

(def s2 (zig.core/gc-stats))
(def current2 (get s2 :current-allocated))

(println (str "current (after small): " current2))

;; Phase 4: Force multiple manual GC sweeps.
;; With generational GC protection (3 generations), blocks need multiple
;; collection cycles before they become eligible for sweeping.
(zig.core/gc-sweep)
(def _noop1 nil)
(zig.core/gc-sweep)
(def _noop2 nil)
(zig.core/gc-sweep)
(def _noop3 nil)

(def s3 (zig.core/gc-stats))
(def current3 (get s3 :current-allocated))
(def sweeps3 (get s3 :sweep-count))

(println (str "current (after sweep): " current3))
(println (str "sweep-count:           " sweeps3))

;; Phase 5: Verify — directional checks only.
;; a) Sweep freed memory: current3 < current2
;; b) Sweep count increased: sweeps3 > sweeps1

(def pass-a (< current3 current2))
(def pass-b (> sweeps3 sweeps1))

(println "")
(println (str "a) sweep freed memory:      " pass-a))
(println (str "b) sweep-count increased:   " pass-b))

(if (and pass-a pass-b)
  (println "RESULT: PASS")
  (println "RESULT: FAIL"))
