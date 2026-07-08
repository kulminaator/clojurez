;; Math Tests for ClojureZ clojure.math namespace
;; Run with: ./zig-out/bin/clojurez tests/clj/test_math.clj

(load-file "tests/clj/clj_test_helper.clj")

(require '[clojure.math :as m])

;; ============================================================
;; Constants and Helpers
;; ============================================================

;; Special float values (ClojureZ doesn't have ##NaN / ##Inf literals)
(def nan-val (m/sqrt -1.0))
(def inf-val (m/exp 1000.0))
(def neg-inf-val (- inf-val))

;; JVM constants
(def long-min-value -9223372036854775808)
(def long-max-value 9223372036854775807)
;; Double/MIN_VALUE = 2^-1074 (smallest positive subnormal)
(def double-min-value (m/next-up 0.0))
;; Double/MAX_VALUE = (2-2^-52)*2^1023 = next-after(exp(709.7), -Inf)
(def double-max-value (m/next-after (m/exp 709.78) neg-inf-val))
(def double-max-exponent 1023)
(def double-min-exponent -1022)

;; ULP tolerance helper: tests that y = x +/- m*ulp(x)
(defn ulp=
  "Tests that y is within m ulps of x."
  [x y m]
  (let [mu (* (m/ulp x) m)]
    (<= (- x mu) y (+ x mu))))

;; ============================================================
;; Constants
;; ============================================================

(check "E is approximately 2.718281828459045" (ulp= m/E 2.718281828459045 1) true)
(check "PI is approximately 3.141592653589793" (ulp= m/PI 3.141592653589793 1) true)

;; ============================================================
;; Trigonometric Functions
;; ============================================================

(check "sin: NaN input returns NaN" (NaN? (m/sin nan-val)) true)
(check "sin: +Inf input returns NaN" (NaN? (m/sin inf-val)) true)
(check "sin: -Inf input returns NaN" (NaN? (m/sin neg-inf-val)) true)
(check "sin: sin(0) is 0" (= (m/sin 0.0) 0.0) true)
(check "sin: sin(-0) is -0" (= (m/sin -0.0) -0.0) true)
(check "sin: sin(PI) ~ -sin(-PI)" (ulp= (m/sin m/PI) (- (m/sin (- m/PI))) 1) true)

(check "cos: NaN input returns NaN" (NaN? (m/cos nan-val)) true)
(check "cos: +Inf input returns NaN" (NaN? (m/cos inf-val)) true)
(check "cos: -Inf input returns NaN" (NaN? (m/cos neg-inf-val)) true)
(check "cos: cos(0) is 1" (= 1.0 (m/cos 0.0) (m/cos -0.0)) true)
(check "cos: cos(PI) ~ cos(-PI)" (ulp= (m/cos m/PI) (m/cos (- m/PI)) 1) true)

(check "tan: NaN input returns NaN" (NaN? (m/tan nan-val)) true)
(check "tan: +Inf input returns NaN" (NaN? (m/tan inf-val)) true)
(check "tan: -Inf input returns NaN" (NaN? (m/tan neg-inf-val)) true)
(check "tan: tan(0) is 0" (= (m/tan 0.0) 0.0) true)
(check "tan: tan(PI) ~ -tan(-PI)" (ulp= (- (m/tan m/PI)) (m/tan (- m/PI)) 1) true)

(check "asin: NaN input returns NaN" (NaN? (m/asin nan-val)) true)
(check "asin: asin(2) is NaN" (NaN? (m/asin 2.0)) true)
(check "asin: asin(-2) is NaN" (NaN? (m/asin -2.0)) true)
(check "asin: asin(0) is 0" (zero? (m/asin 0.0)) true)

(check "acos: NaN input returns NaN" (NaN? (m/acos nan-val)) true)
(check "acos: acos(-2) is NaN" (NaN? (m/acos -2.0)) true)
(check "acos: acos(2) is NaN" (NaN? (m/acos 2.0)) true)
(check "acos: 2*acos(0) ~ PI" (ulp= (* 2 (m/acos 0.0)) m/PI 1) true)

(check "atan: NaN input returns NaN" (NaN? (m/atan nan-val)) true)
(check "atan: atan(0) is 0" (= (m/atan 0.0) 0.0) true)
(check "atan: atan(1) ~ 0.7854" (ulp= (m/atan 1) 0.7853981633974483 1) true)

;; atan2 tests
(check "atan2: NaN y returns NaN" (NaN? (m/atan2 nan-val 1.0)) true)
(check "atan2: NaN x returns NaN" (NaN? (m/atan2 1.0 nan-val)) true)
(check "atan2: atan2(0, 1) is 0" (= (m/atan2 0.0 1.0) 0.0) true)
(check "atan2: atan2(-0, 1) is -0" (= (m/atan2 -0.0 1.0) -0.0) true)
(check "atan2: atan2(0, -1) ~ PI" (ulp= (m/atan2 0.0 -1.0) m/PI 2) true)
(check "atan2: atan2(-0, -1) ~ -PI" (ulp= (m/atan2 -0.0 -1.0) (- m/PI) 2) true)
(check "atan2: 2*atan2(1, 0) ~ PI" (ulp= (* 2.0 (m/atan2 1.0 0.0)) m/PI 2) true)
(check "atan2: -2*atan2(-1, 0) ~ PI" (ulp= (* -2.0 (m/atan2 -1.0 0.0)) m/PI 2) true)
(check "atan2: 4*atan2(Inf, Inf) ~ PI" (ulp= (* 4.0 (m/atan2 inf-val inf-val)) m/PI 2) true)
(check "atan2: 4*atan2(Inf, -Inf)/3 ~ PI" (ulp= (/ (* 4.0 (m/atan2 inf-val neg-inf-val)) 3.0) m/PI 2) true)
(check "atan2: -4*atan2(-Inf, Inf) ~ PI" (ulp= (* -4.0 (m/atan2 neg-inf-val inf-val)) m/PI 2) true)
(check "atan2: -4*atan2(-Inf, -Inf)/3 ~ PI" (ulp= (/ (* -4.0 (m/atan2 neg-inf-val neg-inf-val)) 3.0) m/PI 2) true)

;; ============================================================
;; Angle Conversion
;; ============================================================

(check "to-radians: 180 deg ~ PI" (ulp= (m/to-radians 180.0) m/PI 1) true)
(check "to-degrees: PI rad ~ 180 deg" (ulp= (m/to-degrees m/PI) 180.0 1) true)

;; Roundtrip test: degrees -> radians -> degrees
(def roundtrip-ok (atom true))
(doseq [d (range 0.0 360.0 5.0)]
  (when-not (ulp= (m/round d) (m/round (-> d m/to-radians m/to-degrees)) 1)
    (reset! roundtrip-ok false)))
(check "to-radians/to-degrees roundtrip" @roundtrip-ok true)

;; ============================================================
;; Hyperbolic Functions
;; ============================================================

(check "sinh: NaN input returns NaN" (NaN? (m/sinh nan-val)) true)
(check "sinh: sinh(+Inf) is +Inf" (infinite? (m/sinh inf-val)) true)
(check "sinh: sinh(-Inf) is -Inf" (infinite? (m/sinh neg-inf-val)) true)
(check "sinh: sinh(0) is 0" (= 0.0 (m/sinh 0.0)) true)

(check "cosh: NaN input returns NaN" (NaN? (m/cosh nan-val)) true)
(check "cosh: cosh(+Inf) is +Inf" (infinite? (m/cosh inf-val)) true)
(check "cosh: cosh(-Inf) is +Inf" (infinite? (m/cosh neg-inf-val)) true)
(check "cosh: cosh(0) is 1" (= 1.0 (m/cosh 0.0)) true)

(check "tanh: NaN input returns NaN" (NaN? (m/tanh nan-val)) true)
(check "tanh: tanh(+Inf) is 1" (= 1.0 (m/tanh inf-val)) true)
(check "tanh: tanh(-Inf) is -1" (= -1.0 (m/tanh neg-inf-val)) true)
(check "tanh: tanh(0) is 0" (= 0.0 (m/tanh 0.0)) true)

;; ============================================================
;; Exponential / Logarithmic Functions
;; ============================================================

(check "exp: NaN input returns NaN" (NaN? (m/exp nan-val)) true)
(check "exp: exp(+Inf) is +Inf" (infinite? (m/exp inf-val)) true)
(check "exp: exp(-Inf) is +0" (zero? (m/exp neg-inf-val)) true)
(check "exp: exp(0) ~ 1" (ulp= (m/exp 0.0) 1.0 1) true)
(check "exp: exp(1) ~ E" (ulp= (m/exp 1) m/E 1) true)

(check "log: NaN input returns NaN" (NaN? (m/log nan-val)) true)
(check "log: log(-1) is NaN" (NaN? (m/log -1.0)) true)
(check "log: log(+Inf) is +Inf" (infinite? (m/log inf-val)) true)
(check "log: log(E) ~ 1" (ulp= (m/log m/E) 1.0 1) true)

(check "log10: NaN input returns NaN" (NaN? (m/log10 nan-val)) true)
(check "log10: log10(-1) is NaN" (NaN? (m/log10 -1.0)) true)
(check "log10: log10(+Inf) is +Inf" (infinite? (m/log10 inf-val)) true)
(check "log10: log10(10) ~ 1" (ulp= (m/log10 10) 1.0 1) true)

(check "sqrt: NaN input returns NaN" (NaN? (m/sqrt nan-val)) true)
(check "sqrt: sqrt(-1) is NaN" (NaN? (m/sqrt -1.0)) true)
(check "sqrt: sqrt(+Inf) is +Inf" (infinite? (m/sqrt inf-val)) true)
(check "sqrt: sqrt(0) is 0" (zero? (m/sqrt 0)) true)
(check "sqrt: sqrt(4) is 2" (= (m/sqrt 4.0) 2.0) true)

(check "cbrt: NaN input returns NaN" (NaN? (m/cbrt nan-val)) true)
(check "cbrt: cbrt(-Inf) is -Inf" (infinite? (m/cbrt neg-inf-val)) true)
(check "cbrt: cbrt(+Inf) is +Inf" (infinite? (m/cbrt inf-val)) true)
(check "cbrt: cbrt(0) is 0" (zero? (m/cbrt 0)) true)
(check "cbrt: cbrt(8) is 2" (= 2.0 (m/cbrt 8.0)) true)

(check "expm1: NaN input returns NaN" (NaN? (m/expm1 nan-val)) true)
(check "expm1: expm1(+Inf) is +Inf" (infinite? (m/expm1 inf-val)) true)
(check "expm1: expm1(-Inf) is -1" (= -1.0 (m/expm1 neg-inf-val)) true)
(check "expm1: expm1(0) is 0" (= 0.0 (m/expm1 0.0)) true)

(check "log1p: NaN input returns NaN" (NaN? (m/log1p nan-val)) true)
(check "log1p: log1p(+Inf) is +Inf" (infinite? (m/log1p inf-val)) true)
(check "log1p: log1p(-1) is -Inf" (infinite? (m/log1p -1.0)) true)
(check "log1p: log1p(0) is 0" (zero? (m/log1p 0.0)) true)

;; pow tests
(check "pow: pow(4, 0) is 1" (= 1.0 (m/pow 4.0 0.0)) true)
(check "pow: pow(4, -0) is 1" (= 1.0 (m/pow 4.0 -0.0)) true)
(check "pow: pow(4.2, 1) is 4.2" (= 4.2 (m/pow 4.2 1.0)) true)
(check "pow: pow(4.2, NaN) is NaN" (NaN? (m/pow 4.2 nan-val)) true)
(check "pow: pow(NaN, 2) is NaN" (NaN? (m/pow nan-val 2.0)) true)
(check "pow: pow(2, +Inf) is +Inf" (infinite? (m/pow 2.0 inf-val)) true)
(check "pow: pow(0.5, -Inf) is +Inf" (infinite? (m/pow 0.5 neg-inf-val)) true)
(check "pow: pow(2, -Inf) is 0" (= 0.0 (m/pow 2.0 neg-inf-val)) true)
(check "pow: pow(0.5, +Inf) is 0" (= 0.0 (m/pow 0.5 inf-val)) true)
(check "pow: pow(1, +Inf) is 1.0 (differs from JVM NaN)" (= 1.0 (m/pow 1.0 inf-val)) true)
(check "pow: pow(2, 3) is 8" (= 8.0 (m/pow 2.0 3.0)) true)
(check "pow: pow(-2, 2) is 4" (= 4.0 (m/pow -2.0 2.0)) true)
(check "pow: pow(-2, 3) is -8" (= -8.0 (m/pow -2.0 3.0)) true)

;; hypot tests
(check "hypot: hypot(1, +Inf) is +Inf" (infinite? (m/hypot 1.0 inf-val)) true)
(check "hypot: hypot(+Inf, 1) is +Inf" (infinite? (m/hypot inf-val 1.0)) true)
(check "hypot: hypot(NaN, 1) is NaN" (NaN? (m/hypot nan-val 1.0)) true)
(check "hypot: hypot(1, NaN) is NaN" (NaN? (m/hypot 1.0 nan-val)) true)
(check "hypot: hypot(5, 12) is 13" (= 13.0 (m/hypot 5.0 12.0)) true)

;; ============================================================
;; Rounding Functions
;; ============================================================

(check "ceil: NaN input returns NaN" (NaN? (m/ceil nan-val)) true)
(check "ceil: ceil(+Inf) is +Inf" (infinite? (m/ceil inf-val)) true)
(check "ceil: ceil(-Inf) is -Inf" (infinite? (m/ceil neg-inf-val)) true)
(check "ceil: ceil(PI) is 4" (= 4.0 (m/ceil m/PI)) true)

(check "floor: NaN input returns NaN" (NaN? (m/floor nan-val)) true)
(check "floor: floor(+Inf) is +Inf" (infinite? (m/floor inf-val)) true)
(check "floor: floor(-Inf) is -Inf" (infinite? (m/floor neg-inf-val)) true)
(check "floor: floor(PI) is 3" (= 3.0 (m/floor m/PI)) true)

(check "rint: NaN input returns NaN" (NaN? (m/rint nan-val)) true)
(check "rint: rint(+Inf) is +Inf" (infinite? (m/rint inf-val)) true)
(check "rint: rint(-Inf) is -Inf" (infinite? (m/rint neg-inf-val)) true)
(check "rint: rint(1.2) is 1" (= 1.0 (m/rint 1.2)) true)
(check "rint: rint(1.5) is 2 (ties to even)" (= 2.0 (m/rint 1.5)) true)
(check "rint: rint(2.5) is 2 (ties to even)" (= 2.0 (m/rint 2.5)) true)
(check "rint: rint(-0.01) is -0" (= (m/rint -0.01) -0.0) true)

(check "round: round(NaN) is 0" (= 0 (m/round nan-val)) true)
(check "round: round(3.5) is 4" (= 4 (m/round 3.5)) true)
(check "round: round(2.5) is 3" (= 3 (m/round 2.5)) true)
(check "round: round(-2.5) is -2" (= -2 (m/round -2.5)) true)

;; ============================================================
;; IEEE Remainder + Sign Functions
;; ============================================================

(check "IEEE-remainder: NaN dividend returns NaN" (NaN? (m/IEEE-remainder nan-val 1.0)) true)
(check "IEEE-remainder: NaN divisor returns NaN" (NaN? (m/IEEE-remainder 1.0 nan-val)) true)
(check "IEEE-remainder: +Inf dividend returns NaN" (NaN? (m/IEEE-remainder inf-val 2.0)) true)
(check "IEEE-remainder: -Inf dividend returns NaN" (NaN? (m/IEEE-remainder neg-inf-val 2.0)) true)
(check "IEEE-remainder: zero divisor returns NaN" (NaN? (m/IEEE-remainder 2 0.0)) true)
(check "IEEE-remainder: 5.0/4.0 is 1.0" (= 1.0 (m/IEEE-remainder 5.0 4.0)) true)
(check "IEEE-remainder: 7.0/2.0 is -1.0" (= -1.0 (m/IEEE-remainder 7.0 2.0)) true)

(check "signum: NaN input returns NaN" (NaN? (m/signum nan-val)) true)
(check "signum: signum(0) is 0" (zero? (m/signum 0.0)) true)
(check "signum: signum(-0) is 0" (zero? (m/signum -0.0)) true)
(check "signum: signum(42) is 1" (= 1.0 (m/signum 42.0)) true)
(check "signum: signum(-42) is -1" (= -1.0 (m/signum -42.0)) true)

(check "copy-sign: copy-sign(1, 42) is 1" (= 1.0 (m/copy-sign 1.0 42.0)) true)
(check "copy-sign: copy-sign(1, -42) is -1" (= -1.0 (m/copy-sign 1.0 -42.0)) true)
(check "copy-sign: copy-sign(1, -Inf) is -1" (= -1.0 (m/copy-sign 1.0 neg-inf-val)) true)

;; ============================================================
;; Exact Integer Arithmetic
;; ============================================================

(check "add-exact: 1+2 is 3" (= 3 (m/add-exact 1 2)) true)
(check "add-exact: 0+0 is 0" (= 0 (m/add-exact 0 0)) true)
(check "subtract-exact: 5-3 is 2" (= 2 (m/subtract-exact 5 3)) true)
(check "multiply-exact: 6*7 is 42" (= 42 (m/multiply-exact 6 7)) true)
(check "increment-exact: inc(5) is 6" (= 6 (m/increment-exact 5)) true)
(check "decrement-exact: dec(5) is 4" (= 4 (m/decrement-exact 5)) true)
(check "negate-exact: negate(5) is -5" (= -5 (m/negate-exact 5)) true)
(check "negate-exact: negate(MAX) is MIN+1" (= (inc long-min-value) (m/negate-exact long-max-value)) true)

;; ============================================================
;; Floor Division / Modulus
;; ============================================================

(check "floor-div: -2/5 is -1" (= -1 (m/floor-div -2 5)) true)
(check "floor-div: 10/3 is 3" (= 3 (m/floor-div 10 3)) true)
(check "floor-div: -10/3 is -4" (= -4 (m/floor-div -10 3)) true)
(check "floor-div: 10/-3 is -4" (= -4 (m/floor-div 10 -3)) true)
(check "floor-div: -10/-3 is 3" (= 3 (m/floor-div -10 -3)) true)

(check "floor-mod: -2 mod 5 is 3" (= 3 (m/floor-mod -2 5)) true)
(check "floor-mod: 10 mod 3 is 1" (= 1 (m/floor-mod 10 3)) true)
(check "floor-mod: -10 mod 3 is 2" (= 2 (m/floor-mod -10 3)) true)
(check "floor-mod: 10 mod -3 is -2" (= -2 (m/floor-mod 10 -3)) true)
(check "floor-mod: -10 mod -3 is -1" (= -1 (m/floor-mod -10 -3)) true)

;; Identity: x = floor-div(x,y)*y + floor-mod(x,y)
(def identity-ok (atom true))
(doseq [x [-10 -5 -1 0 1 5 10]
        y [-5 -3 -1 1 3 5]]
  (when-not (= x (+ (* (m/floor-div x y) y) (m/floor-mod x y)))
    (reset! identity-ok false)))
(check "floor-div/floor-mod identity" @identity-ok true)

;; ============================================================
;; Floating-Point Bit Operations
;; ============================================================

;; ulp tests
(check "ulp: NaN input returns NaN" (NaN? (m/ulp nan-val)) true)
(check "ulp: +Inf input returns +Inf" (infinite? (m/ulp inf-val)) true)
(check "ulp: -Inf input returns +Inf" (infinite? (m/ulp neg-inf-val)) true)
(check "ulp: ulp(0) is Double/MIN_VALUE" (ulp= (m/ulp 0.0) double-min-value 1) true)
(check "ulp: ulp(1) ~ 2^-52" (ulp= (m/ulp 1.0) (m/scalb 1.0 -52) 1) true)

;; get-exponent tests
(check "get-exponent: NaN returns 1024" (= 1024 (m/get-exponent nan-val)) true)
(check "get-exponent: +Inf returns 1024" (= 1024 (m/get-exponent inf-val)) true)
(check "get-exponent: -Inf returns 1024" (= 1024 (m/get-exponent neg-inf-val)) true)
(check "get-exponent: 0 returns -1023" (= -1023 (m/get-exponent 0.0)) true)
(check "get-exponent: 1.0 returns 0" (= 0 (m/get-exponent 1.0)) true)
(check "get-exponent: 12345.678 returns 13" (= 13 (m/get-exponent 12345.678)) true)
(check "get-exponent: 2.0 returns 1" (= 1 (m/get-exponent 2.0)) true)
(check "get-exponent: 0.5 returns -1" (= -1 (m/get-exponent 0.5)) true)

;; scalb tests
(check "scalb: NaN input returns NaN" (NaN? (m/scalb nan-val 1)) true)
(check "scalb: +Inf input returns +Inf" (infinite? (m/scalb inf-val 1)) true)
(check "scalb: -Inf input returns -Inf" (infinite? (m/scalb neg-inf-val 1)) true)
(check "scalb: scalb(2, 4) is 32" (= 32.0 (m/scalb 2.0 4)) true)
(check "scalb: scalb(1, 10) is 1024" (= 1024.0 (m/scalb 1.0 10)) true)
(check "scalb: scalb(3, -2) is 0.75" (= 0.75 (m/scalb 3.0 -2)) true)
(check "scalb: scalb(0, 2) is 0" (= 0.0 (m/scalb 0.0 2)) true)
(check "scalb: scalb(-0, 2) is -0" (= (m/scalb -0.0 2) -0.0) true)

;; next-after tests
(check "next-after: NaN start returns NaN" (NaN? (m/next-after nan-val 1)) true)
(check "next-after: NaN direction returns NaN" (NaN? (m/next-after 1 nan-val)) true)
(check "next-after: next-after(0, 0) is 0" (= 0.0 (m/next-after 0.0 0.0)) true)
(check "next-after: next-after(0, -0) is -0" (= (m/next-after 0.0 -0.0) -0.0) true)
(check "next-after: next-after(-0, -0) is -0" (= (m/next-after -0.0 -0.0) -0.0) true)
(check "next-after: next-after(+Inf, 1) is Double/MAX_VALUE" (ulp= (m/next-after inf-val 1.0) double-max-value 1) true)

;; next-up tests
(check "next-up: NaN input returns NaN" (NaN? (m/next-up nan-val)) true)
(check "next-up: +Inf input returns +Inf" (infinite? (m/next-up inf-val)) true)
(check "next-up: next-up(0) is Double/MIN_VALUE" (ulp= (m/next-up 0.0) double-min-value 1) true)

;; next-down tests
(check "next-down: NaN input returns NaN" (NaN? (m/next-down nan-val)) true)
(check "next-down: -Inf input returns -Inf" (infinite? (m/next-down neg-inf-val)) true)
(check "next-down: next-down(0) is -Double/MIN_VALUE" (ulp= (m/next-down 0.0) (- double-min-value) 1) true)

;; ============================================================
;; Random
;; ============================================================

(check "random: returns value in [0, 1)" (and (>= (m/random) 0.0) (< (m/random) 1.0)) true)
(check "random: returns value in [0, 1)" (and (>= (m/random) 0.0) (< (m/random) 1.0)) true)
(check "random: returns value in [0, 1)" (and (>= (m/random) 0.0) (< (m/random) 1.0)) true)

;; ============================================================
;; Summary
;; ============================================================

(print-summary)
