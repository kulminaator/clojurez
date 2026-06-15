;; GC Stress Test — verifies automatic and manual garbage collection.
;;
;; Allocates significant temporary memory through repeated string
;; concatenation, then verifies that:
;;   1. Auto-GC kicked in during heavy allocation
;;   2. Manual gc-sweep reduces memory below pre-sweep level
;;   3. Sweep count increases after each collection
;;
;; Only directional checks are used (no hardcoded byte thresholds)
;; so the test is robust across different builds and platforms.

;; This test is expected to fail if GC is turned off.

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

;; Phase 4: Force a manual GC sweep.
(zig.core/gc-sweep)

;; Deferred sweep runs at the next safe point (between forms).
(def _noop nil)

(def s3 (zig.core/gc-stats))
(def current3 (get s3 :current-allocated))
(def sweeps3 (get s3 :sweep-count))

(println (str "current (after sweep): " current3))
(println (str "sweep-count:           " sweeps3))

;; Phase 5: Verify — directional checks only.
;; a) Auto-GC triggered: sweeps1 > 0
;; b) Peak is significant: peak1 > current1 (peak exceeded steady state)
;; c) Sweep freed memory: current3 < current2
;; d) Sweep count increased: sweeps3 > sweeps1

(def pass-a (> sweeps1 0))
(def pass-b (> peak1 current1))
(def pass-c (< current3 current2))
(def pass-d (> sweeps3 sweeps1))

(println "")
(println (str "a) auto-GC triggered:       " pass-a))
(println (str "b) peak > steady state:     " pass-b))
(println (str "c) sweep freed memory:      " pass-c))
(println (str "d) sweep-count increased:   " pass-d))

(if (and pass-a pass-b pass-c pass-d)
  (println "RESULT: PASS")
  (println "RESULT: FAIL"))
