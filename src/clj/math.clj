(ns clojure.math)

;; ============================================================
;; Constants
;; ============================================================

(def E (zig.core/E))
(def PI (zig.core/PI))

;; ============================================================
;; Trigonometric Functions
;; ============================================================

(defn sin
  "Returns the trigonometric sine of an angle.
   The angle is in radians."
  [a]
  (zig.core/sin (double a)))

(defn cos
  "Returns the trigonometric cosine of an angle.
   The angle is in radians."
  [a]
  (zig.core/cos (double a)))

(defn tan
  "Returns the trigonometric tangent of an angle.
   The angle is in radians."
  [a]
  (zig.core/tan (double a)))

(defn asin
  "Returns the arc sine of a value, in the range -pi/2 to pi/2.
   The result is in radians."
  [a]
  (zig.core/asin (double a)))

(defn acos
  "Returns the arc cosine of a value, in the range 0 to pi.
   The result is in radians."
  [a]
  (zig.core/acos (double a)))

(defn atan
  "Returns the arc tangent of a value, in the range -pi/2 to pi/2.
   The result is in radians."
  [a]
  (zig.core/atan (double a)))

(defn atan2
  "Converts rectangular coordinates (x, y) to polar (r, theta).
   Returns the angle theta in the range -pi to pi.
   The result is in radians."
  [y x]
  (zig.core/atan2 (double y) (double x)))

;; ============================================================
;; Angle Conversion
;; ============================================================

(defn to-radians
  "Converts degrees to radians."
  [deg]
  (zig.core/to-radians (double deg)))

(defn to-degrees
  "Converts radians to degrees."
  [r]
  (zig.core/to-degrees (double r)))

;; ============================================================
;; Hyperbolic Functions
;; ============================================================

(defn sinh
  "Returns the hyperbolic sine of an angle."
  [x]
  (zig.core/sinh (double x)))

(defn cosh
  "Returns the hyperbolic cosine of an angle."
  [x]
  (zig.core/cosh (double x)))

(defn tanh
  "Returns the hyperbolic tangent of an angle."
  [x]
  (zig.core/tanh (double x)))

;; ============================================================
;; Exponential / Logarithmic Functions
;; ============================================================

(defn exp
  "Returns e raised to the power of a."
  [a]
  (zig.core/exp (double a)))

(defn log
  "Returns the natural logarithm of a."
  [a]
  (zig.core/log (double a)))

(defn log10
  "Returns the logarithm base 10 of a."
  [a]
  (zig.core/log10 (double a)))

(defn sqrt
  "Returns the positive square root of a."
  [a]
  (zig.core/sqrt (double a)))

(defn cbrt
  "Returns the cube root of a."
  [a]
  (zig.core/cbrt (double a)))

(defn expm1
  "Returns e^x - 1, more accurate than (- (exp x) 1) for small x."
  [x]
  (zig.core/expm1 (double x)))

(defn log1p
  "Returns ln(1+x), more accurate than (log (+ 1 x)) for small x."
  [x]
  (zig.core/log1p (double x)))

(defn pow
  "Returns a raised to the power of b."
  [a b]
  (zig.core/pow (double a) (double b)))

(defn hypot
  "Returns sqrt(x^2 + y^2) without intermediate overflow or underflow."
  [x y]
  (zig.core/hypot (double x) (double y)))

;; ============================================================
;; Rounding Functions
;; ============================================================

(defn ceil
  "Returns the smallest integer greater than or equal to a, as a double."
  [a]
  (zig.core/ceil (double a)))

(defn floor
  "Returns the largest integer less than or equal to a, as a double."
  [a]
  (zig.core/floor (double a)))

(defn rint
  "Returns the closest integer to a as a double, with ties rounded to even."
  [a]
  (zig.core/rint (double a)))

(defn round
  "Returns the closest long (integer) to a."
  [a]
  (zig.core/round (double a)))

;; ============================================================
;; IEEE Remainder + Sign Functions
;; ============================================================

(defn IEEE-remainder
  "Returns the IEEE 754 remainder of dividend divided by divisor.
   The result is dividend - (divisor * n) where n is the integer
   closest to the exact value of the quotient. If two integers are
   equally close, n is the even one."
  [dividend divisor]
  (zig.core/IEEE-remainder (double dividend) (double divisor)))

(defn signum
  "Returns -1.0, 0.0, or 1.0 as the signum of d.
   Returns -0.0 if d is -0.0. Returns NaN if d is NaN."
  [d]
  (zig.core/signum (double d)))

(defn copy-sign
  "Returns the first argument with the sign of the second argument."
  [magnitude sign]
  (zig.core/copy-sign (double magnitude) (double sign)))

;; ============================================================
;; Exact Integer Arithmetic
;; ============================================================

(defn add-exact
  "Returns the sum of x and y. Throws ArithmeticException on overflow."
  [x y]
  (zig.core/add-exact (int x) (int y)))

(defn subtract-exact
  "Returns the difference of x and y. Throws ArithmeticException on overflow."
  [x y]
  (zig.core/subtract-exact (int x) (int y)))

(defn multiply-exact
  "Returns the product of x and y. Throws ArithmeticException on overflow."
  [x y]
  (zig.core/multiply-exact (int x) (int y)))

(defn increment-exact
  "Returns a + 1. Throws ArithmeticException on overflow."
  [a]
  (zig.core/increment-exact (int a)))

(defn decrement-exact
  "Returns a - 1. Throws ArithmeticException on overflow."
  [a]
  (zig.core/decrement-exact (int a)))

(defn negate-exact
  "Returns -a. Throws ArithmeticException on overflow."
  [a]
  (zig.core/negate-exact (int a)))

;; ============================================================
;; Floor Division / Modulus
;; ============================================================

(defn floor-div
  "Integer division rounding to negative infinity."
  [x y]
  (zig.core/floor-div (int x) (int y)))

(defn floor-mod
  "Integer modulus with sign matching divisor."
  [x y]
  (zig.core/floor-mod (int x) (int y)))

;; ============================================================
;; Floating-Point Bit Operations
;; ============================================================

(defn ulp
  "Returns the size of an ulp (unit in last place) for d.
   If d is NaN => NaN
   If d is ±Inf => +Inf
   If d is zero => Double/MIN_VALUE (4.9E-324)"
  [d]
  (zig.core/ulp (double d)))

(defn get-exponent
  "Returns the unbiased exponent of d.
   If d is NaN, ±Inf => 1024 (Double/MAX_EXPONENT + 1)
   If d is zero or subnormal => -1023 (Double/MIN_EXPONENT - 1)"
  [d]
  (zig.core/get-exponent (double d)))

(defn scalb
  "Returns d * 2^scaleFactor, scaling by a factor of 2.
   If d is NaN => NaN
   If d is ±Inf => ±Inf
   If d is zero => zero with same sign"
  [d scaleFactor]
  (zig.core/scalb (double d) (int scaleFactor)))

(defn next-after
  "Returns the adjacent floating point number to start in the direction of
   the second argument. If the arguments are equal, the second is returned.
   If either arg is NaN => NaN"
  [start direction]
  (zig.core/next-after (double start) (double direction)))

(defn next-up
  "Returns the adjacent double of d in the direction of +Inf.
   If d is NaN => NaN
   If d is +Inf => +Inf
   If d is zero => Double/MIN_VALUE"
  [d]
  (zig.core/next-up (double d)))

(defn next-down
  "Returns the adjacent double of d in the direction of -Inf.
   If d is NaN => NaN
   If d is -Inf => -Inf
   If d is zero => -Double/MIN_VALUE"
  [d]
  (zig.core/next-down (double d)))

;; ============================================================
;; Random
;; ============================================================

(defn random
  "Returns a positive double between 0.0 and 1.0, chosen pseudorandomly."
  []
  (zig.core/random))
