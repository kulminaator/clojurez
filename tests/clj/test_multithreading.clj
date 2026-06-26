;; Multithreading tests: future, promise, realized?, deref
(load-file "tests/clj/clj_test_helper.clj")

;; ===== sleep tests =====
(check "sleep accepts zero" (do (zig.core/sleep 0) :ok) :ok)
(check "sleep accepts positive ms" (do (zig.core/sleep 1) :ok) :ok)
(check "sleep wrapper works" (do (sleep 1) :ok) :ok)

;; ===== future basic tests =====
(check "future returns future value" (future? (future 42)) true)
(check "future simple integer" (= (deref (future 42)) 42) true)
(check "future nil" (= (deref (future nil)) nil) true)
(check "future true" (= (deref (future true)) true) true)
(check "future false" (= (deref (future false)) false) true)

;; ===== future with computation =====
(check "future arithmetic" (= (deref (future (+ 1 2 3))) 6) true)
(check "future multiplication" (= (deref (future (* 3 4))) 12) true)

;; ===== future with closures =====
(check "future captures let binding"
  (let [x 10 y 20]
    (= (deref (future (+ x y))) 30))
  true)
(check "future captures function arg"
  (= (deref ((fn [n] (future (* n n))) 7)) 49)
  true)
(check "future captures nested binding"
  (let [a 1 b 2]
    (let [c 3]
      (= (deref (future (+ a b c))) 6)))
  true)

;; ===== future with sleep =====
(check "future with sleep completes"
  (= (deref (future (do (zig.core/sleep 5) 99))) 99)
  true)
(check "future sleep + closure"
  (= (deref ((fn [v] (future (do (zig.core/sleep 5) v))) 42)) 42)
  true)

;; ===== two futures =====
(check "two futures independent"
  (let [f1 (future 1) f2 (future 2)]
    (and (= (deref f1) 1) (= (deref f2) 2)))
  true)
(check "sum of two futures"
  (let [f1 (future 10) f2 (future 20)]
    (= (+ (deref f1) (deref f2)) 30))
  true)

;; ===== nested futures =====
(check "nested future" (= (deref (future (deref (future 42)))) 42) true)
(check "nested future with computation"
  (= (deref (future (+ 1 (deref (future 2))))) 3)
  true)

;; ===== future-call =====
(check "future-call with fn"
  (= (deref (future-call (fn [] 123))) 123)
  true)
(check "future-call is future?" (future? (future-call (fn [] nil))) true)

;; ===== promise basic tests =====
(check "promise returns promise value" (promise? (promise)) true)
(check "promise deliver and deref"
  (let [p (promise)]
    (deliver p 42)
    (= (deref p) 42))
  true)
(check "promise deliver nil"
  (let [p (promise)]
    (deliver p nil)
    (nil? (deref p)))
  true)

;; ===== promise deliver semantics =====
(check "promise first deliver wins"
  (let [p (promise)]
    (deliver p 1)
    (deliver p 2)
    (deliver p 3)
    (= (deref p) 1))
  true)
(check "deliver returns promise"
  (let [p (promise)]
    (promise? (deliver p 1)))
  true)

;; ===== promise realized? =====
(check "realized? after deliver"
  (let [p (promise)]
    (deliver p 1)
    (realized? p))
  true)

;; ===== future + promise integration =====
(check "future delivers promise"
  (let [p (promise)]
    (future (deliver p 99))
    (= (deref p) 99))
  true)
(check "future delivers promise with sleep"
  (let [p (promise)]
    (future (do (zig.core/sleep 5) (deliver p 77)))
    (= (deref p) 77))
  true)

;; ===== GC stress with futures =====
(check "future survives gc-sweep"
  (let [f (future (do (zig.core/sleep 5) 42))]
    (zig.core/gc-sweep)
    (= (deref f) 42))
  true)
(check "future with closure survives gc-sweep"
  (let [x 100]
    (let [f (future (do (zig.core/sleep 5) (* x 2)))]
      (zig.core/gc-sweep)
      (= (deref f) 200)))
  true)
(check "promise survives gc-sweep"
  (let [p (promise)]
    (zig.core/gc-sweep)
    (deliver p 55)
    (= (deref p) 55))
  true)

;; ==== Make sure we don't lose variables as we pass them on ====
(check "Double future passing works"
  (let [arg-x 3
        f1 (future arg-x)
        f2 (future (deref f1))]
    (zig.core/gc-sweep)
    (= (deref f2) 3))
  true)

(print-summary)
