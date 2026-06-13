;; Regex + GC Stress Test — Let's see that we do not leak massive amounts of memory here
;;
;; Allocates significant temporary memory through repeated string and then does regex against it
;; Measuring memory usage before after etc.
;;
;; Only directional checks are used (no hardcoded byte thresholds)
;; so the test is robust across different builds and platforms.

;; let's clean the room before we start even
(zig.core/gc-sweep)


(println "=== GC Stress Test ===")
;; Heavy round: creates and discards large temporary strings.
(defn make-str [depth astr]
  (if (> depth 0)
    (make-str (- depth 1) (str astr depth astr))
    astr))

(defn run-regex[]
  (let [longstr  (make-str 8 "potatoes")]
    ;; do smth with longstr now
    (println (str "## Long str length is " (count longstr)))
    (println (count (clojure.string/split longstr #"toes[0-3]p" 32)))
    ;;this just shows our string. not a biggy.
    ;;(println longstr)
    ))

;; Phase 0: Capture stats before anything
(def s0 (zig.core/gc-stats))
(def peak0 (get s0 :peak-allocated))
(def sweeps0 (get s0 :sweep-count))
(def current0 (get s0 :current-allocated))

(println "=== Regex+GC Stress Test Phase 0 ===")
(println (str "peak-allocated:    " peak0))
(println (str "sweep-count:       " sweeps0))
(println (str "current-allocated: " current0))

;; Test subject
(run-regex)

;; Phase 1: Measure memory before GC forcing
(def s1 (zig.core/gc-stats))
(def peak1 (get s1 :peak-allocated))
(def sweeps1 (get s1 :sweep-count))
(def current1 (get s1 :current-allocated))

(println "=== Regex+GC  Test Phase 1 ===")
(println (str "peak-allocated:    " peak1))
(println (str "sweep-count:       " sweeps1))
(println (str "current-allocated: " current1))

;; let's clean the room
(zig.core/gc-sweep)

;; Phase 2: Capture stats after forced gc
(def s2 (zig.core/gc-stats))
(def peak2 (get s2 :peak-allocated))
(def sweeps2 (get s2 :sweep-count))
(def current2 (get s2 :current-allocated))

(println "=== Regex+GC  Test Phase 2 ===")
(println (str "peak-allocated:    " peak2))
(println (str "sweep-count:       " sweeps2))
(println (str "current-allocated: " current2))

;; Phase 5: Verify — directional checks only.
;; a) Auto-GC triggered: sweeps1 > 0
;; b) Peak is significant: peak1 > current1 (peak exceeded steady state)
;; c) Sweep freed memory: current3 < current2
;; d) Sweep count increased: sweeps3 > sweeps1

(def pass-a (> sweeps2 sweeps0))
(def pass-b (> peak2 current2))
(def pass-c (< current2 current1))

(println "")
(println (str "a) sweep has triggered:     " pass-a))
(println (str "b) peak > steady state:     " pass-b))
(println (str "c) sweep freed memory:      " pass-c))

(if (and pass-a pass-b pass-c)
  (println "RESULT: PASS")
  (println "RESULT: FAIL"))
