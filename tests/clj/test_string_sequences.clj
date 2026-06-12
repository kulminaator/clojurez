;; String Sequence Tests: first, second, nth, last, rest on strings with UTF-8 support
(load-file "tests/clj/clj_test_helper.clj")

;; ---- first on strings (ASCII) ----
(check "first hello" (= (first "hello") \h) true)
(check "first single" (= (first "x") \x) true)
(check "first empty nil" (nil? (first "")) true)

;; ---- first on strings (UTF-8) ----
(check "first öölaps is ö" (= (first "öölaps") \ö) true)
(check "first ö codepoint" (= (int (first "öölaps")) 246) true)
(check "first emoji" (= (int (first "👨man")) 128104) true)
(check "first a before emoji" (= (first "a👨man") \a) true)

;; ---- second on strings (ASCII) ----
(check "second hello" (= (second "hello") \e) true)
(check "second single nil" (nil? (second "x")) true)
(check "second empty nil" (nil? (second "")) true)

;; ---- second on strings (UTF-8) ----
(check "second öölaps is second ö" (= (second "öölaps") \ö) true)
(check "second a👨man is emoji" (= (int (second "a👨man")) 128104) true)
(check "second emoji👨man is m" (= (second "👨man") \m) true)

;; ---- nth on strings (ASCII) ----
(check "nth hello 0" (= (nth "hello" 0) \h) true)
(check "nth hello 1" (= (nth "hello" 1) \e) true)
(check "nth hello 4" (= (nth "hello" 4) \o) true)
(check "nth hello 5 nil" (nil? (nth "hello" 5)) true)
(check "nth hello -1 nil" (nil? (nth "hello" -1)) true)

;; ---- nth on strings (UTF-8) ----
(check "nth öölaps 0" (= (nth "öölaps" 0) \ö) true)
(check "nth öölaps 1" (= (nth "öölaps" 1) \ö) true)
(check "nth öölaps 2 is l" (= (nth "öölaps" 2) \l) true)
(check "nth öölaps 5 is s" (= (nth "öölaps" 5) \s) true)
(check "nth a👨man 0 is a" (= (nth "a👨man" 0) \a) true)
(check "nth a👨man 1 is emoji" (= (int (nth "a👨man" 1)) 128104) true)
(check "nth a👨man 2 is m" (= (nth "a👨man" 2) \m) true)
(check "nth a👨man out of range nil" (nil? (nth "a👨man" 10)) true)

;; ---- last on strings (ASCII) ----
(check "last hello" (= (last "hello") \o) true)
(check "last single" (= (last "x") \x) true)
(check "last empty nil" (nil? (last "")) true)

;; ---- last on strings (UTF-8) ----
(check "last öölaps is s" (= (last "öölaps") \s) true)
(check "last öölaps int" (= (int (last "öölaps")) 115) true)
(check "last a👨man is n" (= (last "a👨man") \n) true)
(check "last emoji only" (= (int (last "👨")) 128104) true)

;; ---- rest on strings (ASCII) ----
(check "rest hello" (= (rest "hello") '(\e \l \l \o)) true)
(check "rest single empty" (= (rest "x") '()) true)
(check "rest empty empty" (= (rest "") '()) true)

;; ---- rest on strings (UTF-8) ----
(check "rest öölaps" (and (list? (rest "öölaps")) (= (count (rest "öölaps")) 5)) true)
(check "rest öölaps first is second ö" (= (first (rest "öölaps")) \ö) true)
(check "rest a👨man" (and (list? (rest "a👨man")) (= (count (rest "a👨man")) 4)) true)
(check "rest a👨man first is emoji" (= (int (first (rest "a👨man"))) 128104) true)

;; ---- char type checks on sequence results ----
(check "first returns char" (char? (first "hello")) true)
(check "second returns char" (char? (second "hello")) true)
(check "nth returns char" (char? (nth "hello" 0)) true)
(check "last returns char" (char? (last "hello")) true)
(check "rest returns list of chars" (every? char? (rest "hello")) true)
(check "first utf8 returns char" (char? (first "öölaps")) true)
(check "nth utf8 returns char" (char? (nth "öölaps" 0)) true)
(check "last utf8 returns char" (char? (last "öölaps")) true)

;; ---- int coercion of chars from strings ----
(check "int of first h" (= (int (first "hello")) 104) true)
(check "int of first ö" (= (int (first "öölaps")) 246) true)
(check "int of second emoji" (= (int (second "a👨man")) 128104) true)

(print-summary)
