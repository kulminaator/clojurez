;; Math Tests for ClojureZ clojure.math namespace
;; Run with: ./zig-out/bin/clojurez tests/clj/test_math.clj
;; 
;; Avoids atoms/swap! due to pre-existing bytecode bug.

(require '[clojure.math :as m])

;; ULP tolerance helper
(defn ulp= [x y m]
  (let [mu (* (m/ulp x) m)]
    (<= (- x mu) y (+ x mu))))

;; Special values
(def nan-val (m/sqrt -1.0))
(def inf-val (m/exp 1000.0))
(def neg-inf-val (- inf-val))
(def double-min-value (m/next-up 0.0))

;; ============================================================
;; Tests - each prints its own result, no shared state
;; ============================================================

(println "PASS: E" (ulp= m/E 2.718281828459045 1))
(println "PASS: PI" (ulp= m/PI 3.141592653589793 1))

(println "PASS: sin NaN" (NaN? (m/sin nan-val)))
(println "PASS: sin 0" (= (m/sin 0.0) 0.0))
(println "PASS: cos NaN" (NaN? (m/cos nan-val)))
(println "PASS: cos 0" (= (m/cos 0.0) 1.0))
(println "PASS: tan NaN" (NaN? (m/tan nan-val)))
(println "PASS: tan 0" (= (m/tan 0.0) 0.0))
(println "PASS: asin NaN" (NaN? (m/asin nan-val)))
(println "PASS: asin 2" (NaN? (m/asin 2.0)))
(println "PASS: acos NaN" (NaN? (m/acos nan-val)))
(println "PASS: acos 2*0~PI" (ulp= (* 2 (m/acos 0.0)) m/PI 1))
(println "PASS: atan NaN" (NaN? (m/atan nan-val)))
(println "PASS: atan 0" (= (m/atan 0.0) 0.0))
(println "PASS: atan2 NaN" (NaN? (m/atan2 nan-val 1.0)))
(println "PASS: atan2 0,-1~PI" (ulp= (m/atan2 0.0 -1.0) m/PI 2))

(println "PASS: to-radians 180~PI" (ulp= (m/to-radians 180.0) m/PI 1))
(println "PASS: to-degrees PI~180" (ulp= (m/to-degrees m/PI) 180.0 1))

(println "PASS: sinh NaN" (NaN? (m/sinh nan-val)))
(println "PASS: sinh 0" (= (m/sinh 0.0) 0.0))
(println "PASS: cosh NaN" (NaN? (m/cosh nan-val)))
(println "PASS: cosh 0" (= (m/cosh 0.0) 1.0))
(println "PASS: tanh NaN" (NaN? (m/tanh nan-val)))
(println "PASS: tanh Inf" (= (m/tanh inf-val) 1.0))
(println "PASS: tanh 0" (= (m/tanh 0.0) 0.0))

(println "PASS: exp NaN" (NaN? (m/exp nan-val)))
(println "PASS: exp Inf" (infinite? (m/exp inf-val)))
(println "PASS: exp 0~1" (ulp= (m/exp 0.0) 1.0 1))
(println "PASS: exp 1~E" (ulp= (m/exp 1) m/E 1))

(println "PASS: log NaN" (NaN? (m/log nan-val)))
(println "PASS: log -1" (NaN? (m/log -1.0)))
(println "PASS: log E~1" (ulp= (m/log m/E) 1.0 1))

(println "PASS: log10 NaN" (NaN? (m/log10 nan-val)))
(println "PASS: log10 10~1" (ulp= (m/log10 10) 1.0 1))

(println "PASS: sqrt NaN" (NaN? (m/sqrt nan-val)))
(println "PASS: sqrt -1" (NaN? (m/sqrt -1.0)))
(println "PASS: sqrt 4" (= (m/sqrt 4.0) 2.0))

(println "PASS: cbrt NaN" (NaN? (m/cbrt nan-val)))
(println "PASS: cbrt 8" (= (m/cbrt 8.0) 2.0))

(println "PASS: expm1 NaN" (NaN? (m/expm1 nan-val)))
(println "PASS: expm1 0" (= (m/expm1 0.0) 0.0))

(println "PASS: log1p NaN" (NaN? (m/log1p nan-val)))
(println "PASS: log1p -1" (infinite? (m/log1p -1.0)))

(println "PASS: pow 4^0" (= (m/pow 4.0 0.0) 1.0))
(println "PASS: pow 2^3" (= (m/pow 2.0 3.0) 8.0))
(println "PASS: pow -2^2" (= (m/pow -2.0 2.0) 4.0))
(println "PASS: pow -2^3" (= (m/pow -2.0 3.0) -8.0))

(println "PASS: hypot 5,12" (= (m/hypot 5.0 12.0) 13.0))
(println "PASS: hypot NaN" (NaN? (m/hypot nan-val 1.0)))

(println "PASS: ceil NaN" (NaN? (m/ceil nan-val)))
(println "PASS: ceil PI" (= (m/ceil m/PI) 4.0))

(println "PASS: floor NaN" (NaN? (m/floor nan-val)))
(println "PASS: floor PI" (= (m/floor m/PI) 3.0))

(println "PASS: rint NaN" (NaN? (m/rint nan-val)))
(println "PASS: rint 1.2" (= (m/rint 1.2) 1.0))
(println "PASS: rint 1.5 even" (= (m/rint 1.5) 2.0))
(println "PASS: rint 2.5 even" (= (m/rint 2.5) 2.0))

(println "PASS: round NaN" (= (m/round nan-val) 0))
(println "PASS: round 3.5" (= (m/round 3.5) 4))
(println "PASS: round -2.5" (= (m/round -2.5) -2))

(println "PASS: IEEE-rem NaN" (NaN? (m/IEEE-remainder nan-val 1.0)))
(println "PASS: IEEE-rem 5/4" (= (m/IEEE-remainder 5.0 4.0) 1.0))
(println "PASS: IEEE-rem 7/2" (= (m/IEEE-remainder 7.0 2.0) -1.0))

(println "PASS: signum NaN" (NaN? (m/signum nan-val)))
(println "PASS: signum 42" (= (m/signum 42.0) 1.0))
(println "PASS: signum -42" (= (m/signum -42.0) -1.0))

(println "PASS: copy-sign 1,42" (= (m/copy-sign 1.0 42.0) 1.0))
(println "PASS: copy-sign 1,-42" (= (m/copy-sign 1.0 -42.0) -1.0))

(println "PASS: add-exact 1+2" (= (m/add-exact 1 2) 3))
(println "PASS: sub-exact 5-3" (= (m/subtract-exact 5 3) 2))
(println "PASS: mul-exact 6*7" (= (m/multiply-exact 6 7) 42))
(println "PASS: inc-exact 5" (= (m/increment-exact 5) 6))
(println "PASS: dec-exact 5" (= (m/decrement-exact 5) 4))
(println "PASS: neg-exact 5" (= (m/negate-exact 5) -5))

(println "PASS: floor-div -2/5" (= (m/floor-div -2 5) -1))
(println "PASS: floor-div -10/3" (= (m/floor-div -10 3) -4))
(println "PASS: floor-mod -2%5" (= (m/floor-mod -2 5) 3))
(println "PASS: floor-mod -10%3" (= (m/floor-mod -10 3) 2))

(println "PASS: ulp NaN" (NaN? (m/ulp nan-val)))
(println "PASS: ulp Inf" (infinite? (m/ulp inf-val)))
(println "PASS: ulp 0" (ulp= (m/ulp 0.0) double-min-value 1))

(println "PASS: get-exp NaN" (= (m/get-exponent nan-val) 1024))
(println "PASS: get-exp Inf" (= (m/get-exponent inf-val) 1024))
(println "PASS: get-exp 0" (= (m/get-exponent 0.0) -1023))
(println "PASS: get-exp 1" (= (m/get-exponent 1.0) 0))
(println "PASS: get-exp 2" (= (m/get-exponent 2.0) 1))
(println "PASS: get-exp 0.5" (= (m/get-exponent 0.5) -1))
(println "PASS: get-exp 12345" (= (m/get-exponent 12345.678) 13))

(println "PASS: scalb NaN" (NaN? (m/scalb nan-val 1)))
(println "PASS: scalb 2^4" (= (m/scalb 2.0 4) 32.0))
(println "PASS: scalb 1^10" (= (m/scalb 1.0 10) 1024.0))
(println "PASS: scalb 3^-2" (= (m/scalb 3.0 -2) 0.75))

(println "PASS: next-after NaN" (NaN? (m/next-after nan-val 1)))
(println "PASS: next-after 0,0" (= (m/next-after 0.0 0.0) 0.0))

(println "PASS: next-up NaN" (NaN? (m/next-up nan-val)))
(println "PASS: next-up Inf" (infinite? (m/next-up inf-val)))
(println "PASS: next-up 0" (ulp= (m/next-up 0.0) double-min-value 1))

(println "PASS: next-down NaN" (NaN? (m/next-down nan-val)))
(println "PASS: next-down -Inf" (infinite? (m/next-down neg-inf-val)))

(println "PASS: random [0,1) #1" (and (>= (m/random) 0.0) (< (m/random) 1.0)))
(println "PASS: random [0,1) #2" (and (>= (m/random) 0.0) (< (m/random) 1.0)))
(println "PASS: random [0,1) #3" (and (>= (m/random) 0.0) (< (m/random) 1.0)))
