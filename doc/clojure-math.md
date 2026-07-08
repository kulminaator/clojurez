# clojure.math


## Table of Contents

- [IEEE-remainder](#IEEE-remainder)
- [acos](#acos)
- [add-exact](#add-exact)
- [asin](#asin)
- [atan](#atan)
- [atan2](#atan2)
- [cbrt](#cbrt)
- [ceil](#ceil)
- [copy-sign](#copy-sign)
- [cos](#cos)
- [cosh](#cosh)
- [decrement-exact](#decrement-exact)
- [exp](#exp)
- [expm1](#expm1)
- [floor](#floor)
- [floor-div](#floor-div)
- [floor-mod](#floor-mod)
- [get-exponent](#get-exponent)
- [hypot](#hypot)
- [increment-exact](#increment-exact)
- [log](#log)
- [log10](#log10)
- [log1p](#log1p)
- [multiply-exact](#multiply-exact)
- [negate-exact](#negate-exact)
- [next-after](#next-after)
- [next-down](#next-down)
- [next-up](#next-up)
- [pow](#pow)
- [random](#random)
- [rint](#rint)
- [round](#round)
- [scalb](#scalb)
- [signum](#signum)
- [sin](#sin)
- [sinh](#sinh)
- [sqrt](#sqrt)
- [subtract-exact](#subtract-exact)
- [tan](#tan)
- [tanh](#tanh)
- [to-degrees](#to-degrees)
- [to-radians](#to-radians)
- [ulp](#ulp)

---

## IEEE-remainder

[(dividend divisor)]

Returns the IEEE 754 remainder of dividend divided by divisor.
   The result is dividend - (divisor * n) where n is the integer
   closest to the exact value of the quotient. If two integers are
   equally close, n is the even one.

---

## acos

[(a)]

Returns the arc cosine of a value, in the range 0 to pi.
   The result is in radians.

---

## add-exact

[(x y)]

Returns the sum of x and y. Throws ArithmeticException on overflow.

---

## asin

[(a)]

Returns the arc sine of a value, in the range -pi/2 to pi/2.
   The result is in radians.

---

## atan

[(a)]

Returns the arc tangent of a value, in the range -pi/2 to pi/2.
   The result is in radians.

---

## atan2

[(y x)]

Converts rectangular coordinates (x, y) to polar (r, theta).
   Returns the angle theta in the range -pi to pi.
   The result is in radians.

---

## cbrt

[(a)]

Returns the cube root of a.

---

## ceil

[(a)]

Returns the smallest integer greater than or equal to a, as a double.

---

## copy-sign

[(magnitude sign)]

Returns the first argument with the sign of the second argument.

---

## cos

[(a)]

Returns the trigonometric cosine of an angle.
   The angle is in radians.

---

## cosh

[(x)]

Returns the hyperbolic cosine of an angle.

---

## decrement-exact

[(a)]

Returns a - 1. Throws ArithmeticException on overflow.

---

## exp

[(a)]

Returns e raised to the power of a.

---

## expm1

[(x)]

Returns e^x - 1, more accurate than (- (exp x) 1) for small x.

---

## floor

[(a)]

Returns the largest integer less than or equal to a, as a double.

---

## floor-div

[(x y)]

Integer division rounding to negative infinity.

---

## floor-mod

[(x y)]

Integer modulus with sign matching divisor.

---

## get-exponent

[(d)]

Returns the unbiased exponent of d.
   If d is NaN, ±Inf => 1024 (Double/MAX_EXPONENT + 1)
   If d is zero or subnormal => -1023 (Double/MIN_EXPONENT - 1)

---

## hypot

[(x y)]

Returns sqrt(x^2 + y^2) without intermediate overflow or underflow.

---

## increment-exact

[(a)]

Returns a + 1. Throws ArithmeticException on overflow.

---

## log

[(a)]

Returns the natural logarithm of a.

---

## log10

[(a)]

Returns the logarithm base 10 of a.

---

## log1p

[(x)]

Returns ln(1+x), more accurate than (log (+ 1 x)) for small x.

---

## multiply-exact

[(x y)]

Returns the product of x and y. Throws ArithmeticException on overflow.

---

## negate-exact

[(a)]

Returns -a. Throws ArithmeticException on overflow.

---

## next-after

[(start direction)]

Returns the adjacent floating point number to start in the direction of
   the second argument. If the arguments are equal, the second is returned.
   If either arg is NaN => NaN

---

## next-down

[(d)]

Returns the adjacent double of d in the direction of -Inf.
   If d is NaN => NaN
   If d is -Inf => -Inf
   If d is zero => -Double/MIN_VALUE

---

## next-up

[(d)]

Returns the adjacent double of d in the direction of +Inf.
   If d is NaN => NaN
   If d is +Inf => +Inf
   If d is zero => Double/MIN_VALUE

---

## pow

[(a b)]

Returns a raised to the power of b.

---

## random

[()]

Returns a positive double between 0.0 and 1.0, chosen pseudorandomly.

---

## rint

[(a)]

Returns the closest integer to a as a double, with ties rounded to even.

---

## round

[(a)]

Returns the closest long (integer) to a.

---

## scalb

[(d scaleFactor)]

Returns d * 2^scaleFactor, scaling by a factor of 2.
   If d is NaN => NaN
   If d is ±Inf => ±Inf
   If d is zero => zero with same sign

---

## signum

[(d)]

Returns -1.0, 0.0, or 1.0 as the signum of d.
   Returns -0.0 if d is -0.0. Returns NaN if d is NaN.

---

## sin

[(a)]

Returns the trigonometric sine of an angle.
   The angle is in radians.

---

## sinh

[(x)]

Returns the hyperbolic sine of an angle.

---

## sqrt

[(a)]

Returns the positive square root of a.

---

## subtract-exact

[(x y)]

Returns the difference of x and y. Throws ArithmeticException on overflow.

---

## tan

[(a)]

Returns the trigonometric tangent of an angle.
   The angle is in radians.

---

## tanh

[(x)]

Returns the hyperbolic tangent of an angle.

---

## to-degrees

[(r)]

Converts radians to degrees.

---

## to-radians

[(deg)]

Converts degrees to radians.

---

## ulp

[(d)]

Returns the size of an ulp (unit in last place) for d.
   If d is NaN => NaN
   If d is ±Inf => +Inf
   If d is zero => Double/MIN_VALUE (4.9E-324)
