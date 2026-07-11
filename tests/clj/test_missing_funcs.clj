;; Tests for newly implemented functions: partial (arity 1), cpu-stats,
;; pmap, pcalls, pvalues, parse-boolean, parse-long, parse-double, vector

(load-file "tests/clj/clj_test_helper.clj")

;; ---- partial (arity 1) ----

(check "partial with just function"
  ((partial identity) 42)
  42)

(check "partial with just function multi-arg"
  ((partial +) 1 2 3)
  6)

(check "partial with function and one arg"
  ((partial + 10) 5)
  15)

(check "partial with function and multiple args"
  ((partial * 2 3) 4)
  24)

;; ---- cpu-stats ----

(check "cpu-stats returns map"
  (map? (zig.core/cpu-stats))
  true)

(check "cpu-stats core-count is positive integer"
  (let [s (zig.core/cpu-stats)]
    (and (integer? (:core-count s)) (pos? (:core-count s))))
  true)

(check "cpu-stats page-size is power of 2"
  (let [ps (:page-size (zig.core/cpu-stats))]
    (or (= ps 4096) (= ps 16384) (= ps 65536)))
  true)

(check "cpu-stats arch is string"
  (string? (:arch (zig.core/cpu-stats)))
  true)

(check "cpu-stats os is string"
  (string? (:os (zig.core/cpu-stats)))
  true)

(check "cpu-stats endian is little or big"
  (let [e (:endian (zig.core/cpu-stats))]
    (or (= e "little") (= e "big")))
  true)

;; ---- pmap ----

(check "pmap basic"
  (vec (pmap inc [1 2 3 4 5]))
  [2 3 4 5 6])

(check "pmap empty"
  (vec (pmap inc []))
  [])

(check "pmap preserves order"
  (vec (pmap (fn [x] (* x x)) [1 2 3 4 5]))
  [1 4 9 16 25])

(check "pmap multi-arity"
  (vec (pmap + [1 2 3] [10 20 30]))
  [11 22 33])

(check "pmap multi-arity three colls"
  (vec (pmap + [1 2] [10 20] [100 200]))
  [111 222])

;; ---- pcalls ----

(check "pcalls basic"
  (vec (pcalls (fn [] 1) (fn [] 2) (fn [] 3)))
  [1 2 3])

(check "pcalls empty"
  (vec (pcalls))
  [])

;; ---- pvalues ----

(check "pvalues basic"
  (vec (pvalues 1 2 3))
  [1 2 3])

(check "pvalues with expressions"
  (vec (pvalues (+ 1 2) (* 3 4) (- 10 5)))
  [3 12 5])

(check "pvalues single"
  (vec (pvalues 42))
  [42])

;; ---- parse-boolean ----

(check "parse-boolean true"
  (parse-boolean "true")
  true)

(check "parse-boolean false"
  (parse-boolean "false")
  false)

(check "parse-boolean invalid returns nil"
  (parse-boolean "maybe")
  nil)

(check "parse-boolean empty string returns nil"
  (parse-boolean "")
  nil)

(check "parse-boolean nil input throws"
  (try (parse-boolean nil) (catch Exception e :threw))
  :threw)

(check "parse-boolean integer input throws"
  (try (parse-boolean 42) (catch Exception e :threw))
  :threw)

;; ---- parse-long ----

(check "parse-long basic"
  (parse-long "42")
  42)

(check "parse-long negative"
  (parse-long "-123")
  -123)

(check "parse-long positive sign"
  (parse-long "+456")
  456)

(check "parse-long zero"
  (parse-long "0")
  0)

(check "parse-long invalid returns nil"
  (parse-long "abc")
  nil)

(check "parse-long overflow returns nil"
  (parse-long "99999999999999999999999")
  nil)

(check "parse-long max long"
  (parse-long "9223372036854775807")
  9223372036854775807)

(check "parse-long min long"
  (parse-long "-9223372036854775808")
  -9223372036854775808)

(check "parse-long nil input throws"
  (try (parse-long nil) (catch Exception e :threw))
  :threw)

;; ---- parse-double ----

(check "parse-double basic"
  (parse-double "3.14")
  3.14)

(check "parse-double integer input"
  (parse-double "42")
  42.0)

(check "parse-double negative"
  (parse-double "-1.5")
  -1.5)

(check "parse-double invalid returns nil"
  (parse-double "abc")
  nil)

(check "parse-double nil input throws"
  (try (parse-double nil) (catch Exception e :threw))
  :threw)

;; ---- vector ----

(check "vector empty"
  (vector)
  [])

(check "vector one arg"
  (vector 1)
  [1])

(check "vector multiple args"
  (vector 1 2 3)
  [1 2 3])

(check "vector with mixed types"
  (vector 1 "two" :three)
  [1 "two" :three])
