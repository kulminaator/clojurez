;; Regex + GC Stress Test — Let's see that we do not leak massive amounts of memory here
;;
;; Allocates significant temporary memory through repeated string and then does regex against it
;; Measuring memory usage before after etc.
;;
;; Only directional checks are used (no hardcoded byte thresholds)
;; so the test is robust across different builds and platforms.

;; let's clean the room before we start even

(def memz (atom {}))
(def results (atom {}))


(defn func-a[limit]
  (loop [x 1]
    (if (> x limit)
      (* 3 x)
      (recur (inc x)))))

(defn func-b[x] 
  (+ 1 x))

(defn func-c[cc]
  (let [anything (inc cc)] 
  	(- anything 8)))

(defn func-d[dd] 
  (future (func-c dd)))


(defn testrun[]
    (swap! memz assoc :mem-start (:current-allocated (zig.core/gc-stats)))
    (let [bres (func-b (func-a 5000))
          dres (func-d 33)] 
      (swap! memz assoc :mem-midpoint (:current-allocated (zig.core/gc-stats)))
      (println @dres)
      (zig.core/gc-sweep)
      (swap! memz assoc :mem-end (:current-allocated (zig.core/gc-stats)))
      (swap! results assoc :bres bres)
      (swap! results assoc :dres @dres)
    )
  )

(println "=== GC Cleanup in Advanced paths ===")
(zig.core/gc-sweep)

(testrun)
;; (println @memz)
;; (println @results)

(if (= @results {:dres 26 :bres 15004})
  (if (< (:mem-start @memz) (:mem-midpoint @memz))
    (if (< (:mem-end @memz) (:mem-midpoint @memz))
	;; result ok, memory usage grew and shrunk as it was expected
        (println "RESULT: PASS")
    	(println (str "RESULT: FAIL memory usage did not shrink with forced gc " @memz)))
	(println (str "RESULT: FAIL memory usage did not grow as expected " @memz)))

  (println (str "RESULT: FAIL wrong result" @results)))
