;; zig.regexp: regex engine tests
(load-file "tests/clj/clj_test_helper.clj")
(ns user (:require [zig.regexp :as re]))

;; ============================================================
;; re-pattern
;; ============================================================
(check-true "re-pattern returns map" (map? (re/re-pattern "abc")))
(check "re-pattern stores pattern string" (:pattern (re/re-pattern "abc")) "abc")

;; ============================================================
;; re-matches (full string match)
;; ============================================================
(check "re-matches literal" (re/re-matches "abc" "abc") "abc")
(check "re-matches no match" (re/re-matches "abc" "abcd") nil)
(check "re-matches star" (re/re-matches "a*" "aaa") "aaa")
(check "re-matches star empty" (re/re-matches "a*" "") "")
(check "re-matches dot" (re/re-matches "a.b" "aab") "aab")
(check "re-matches dot no match" (re/re-matches "a.b" "ab") nil)
(check "re-matches alt" (re/re-matches "a|b" "b") "b")
(check "re-matches plus" (re/re-matches "a+" "aaa") "aaa")
(check "re-matches plus empty" (re/re-matches "a+" "") nil)
(check "re-matches quest" (re/re-matches "a?" "a") "a")
(check "re-matches group" (re/re-matches "(abc)+" "abcabc") "abcabc")
(check "re-matches concat" (re/re-matches "ab*c" "abbbc") "abbbc")
(check "re-matches group alt" (re/re-matches "(a|b)+" "abab") "abab")

;; ============================================================
;; re-find (find first match)
;; ============================================================
(check "re-find literal" (re/re-find "abc" "xabcx") "abc")
(check "re-find no match" (re/re-find "xyz" "abc") nil)
(check "re-find char-class literal" (re/re-find "[abc]" "xb") "b")
(check "re-find char-range lower" (re/re-find "[a-z]" "hello") "h")
(check "re-find char-range no match" (re/re-find "[a-z]" "HELLO") nil)
(check "re-find negated class" (re/re-find "[^abc]" "xyz") "x")
(check "re-find dot" (re/re-find "a.b" "axb") "axb")
(check "re-find alt" (re/re-find "abc|xyz" "xyz") "xyz")
(check "re-find digits" (re/re-find "[0-9]" "abc123") "1")
(check "re-find group alt" (re/re-find "(a|b)*" "abab") "abab")

;; ============================================================
;; re-seq (sequence of all matches)
;; ============================================================
(check "re-seq digits" (re/re-seq "[0-9]" "a1b2c3") ["1" "2" "3"])
(check "re-seq vowels" (re/re-seq "[aeiou]" "hello") ["e" "o"])
(check "re-seq no match" (re/re-seq "[0-9]" "abc") [])
(check "re-seq dot" (re/re-seq "." "abc") ["a" "b" "c"])

;; ============================================================
;; re-split
;; ============================================================
(check "re-split comma" (re/re-split "," "a,b,c") ["a" "b" "c"])
(check "re-split multi" (re/re-split "[,;]" "a,b;c") ["a" "b" "c"])
(check "re-split no match" (re/re-split "," "abc") ["abc"])
(check "re-split leading" (re/re-split "," ",a,b") ["" "a" "b"])
(check "re-split trailing" (re/re-split "," "a,b,") ["a" "b" ""])

;; ============================================================
;; re-replace (first match only)
;; ============================================================
(check "re-replace literal" (re/re-replace "e" "hello" "x") "hxllo")
(check "re-replace class" (re/re-replace "[aeiou]" "hello" "x") "hxllo")
(check "re-replace no match" (re/re-replace "z" "hello" "x") "hello")
(check "re-replace dot" (re/re-replace "a.b" "axbyc" "Z") "Zyc")
(check "re-replace at start" (re/re-replace "h" "hello" "H") "Hello")

;; ============================================================
;; re-replace-all
;; ============================================================
(check "re-replace-all literal" (re/re-replace-all "l" "hello" "x") "hexxo")
(check "re-replace-all class" (re/re-replace-all "[aeiou]" "hello" "x") "hxllx")
(check "re-replace-all no match" (re/re-replace-all "z" "hello" "x") "hello")
(check "re-replace-all digits" (re/re-replace-all "[0-9]" "a1b2c3" "#") "a#b#c#")
(check "re-replace-all dot" (re/re-replace-all "." "abc" "x") "xxx")

;; ============================================================
;; Character class ranges
;; ============================================================
(check "re-find range a-z" (re/re-find "[a-z]" "ZxZ") "x")
(check "re-find range A-Z" (re/re-find "[A-Z]" "xZx") "Z")
(check "re-find range 0-9" (re/re-find "[0-9]" "abc9def") "9")
(check "re-matches range full" (re/re-matches "[a-z]+" "hello") "hello")
(check "re-find mixed class" (re/re-find "[a-zA-Z0-9]" "!@#3") "3")
(check "re-find negated range" (re/re-find "[^0-9]" "abc123") "a")

;; ============================================================
;; Complex patterns
;; ============================================================
(check "re-matches complex concat" (re/re-matches "ab+c" "abbc") "abbc")
(check "re-matches complex alt" (re/re-matches "abc|def" "def") "def")
(check "re-seq words" (re/re-seq "[a-z]+" "hello world") ["hello" "world"])

;; ============================================================
;; Anchors: ^ (beginning) and $ (end)
;; ============================================================

;; re-matches with anchors
(check "re-matches ^a a" (re/re-matches "^a" "a") "a")
(check "re-matches ^a ab" (re/re-matches "^a" "ab") nil)
(check "re-matches ^ab ab" (re/re-matches "^ab" "ab") "ab")
(check "re-matches ^ab abc" (re/re-matches "^ab" "abc") nil)
(check "re-matches a$ a" (re/re-matches "a$" "a") "a")
(check "re-matches a$ ba" (re/re-matches "a$" "ba") nil)
(check "re-matches ab$ ab" (re/re-matches "ab$" "ab") "ab")
(check "re-matches ab$ abc" (re/re-matches "ab$" "abc") nil)
(check "re-matches ^ab$ ab" (re/re-matches "^ab$" "ab") "ab")
(check "re-matches ^ab$ abc" (re/re-matches "^ab$" "abc") nil)
(check "re-matches ^$ empty" (re/re-matches "^$" "") "")
(check "re-matches ^$ a" (re/re-matches "^$" "a") nil)

;; re-find with anchors
(check "re-find ^hello hw" (re/re-find "^hello" "hello world") "hello")
(check "re-find ^world hw" (re/re-find "^world" "hello world") nil)
(check "re-find world$ hw" (re/re-find "world$" "hello world") "world")
(check "re-find hello$ hw" (re/re-find "hello$" "hello world") nil)
(check "re-find ^$ empty" (re/re-find "^$" "") "")
(check "re-find ^$ a" (re/re-find "^$" "a") nil)
(check "re-find ^a$ a" (re/re-find "^a$" "a") "a")
(check "re-find ^a$ ab" (re/re-find "^a$" "ab") nil)
(check "re-find $ ab" (re/re-find "$" "ab") "")
(check "re-find ^ ab" (re/re-find "^" "ab") "")
(check "re-find a$ ab" (re/re-find "a$" "ab") nil)
(check "re-find a$ ba" (re/re-find "a$" "ba") "a")
(check "re-find b$ ab" (re/re-find "b$" "ab") "b")

;; re-seq with anchors
(check "re-seq ^a aab" (re/re-seq "^a" "aab") ["a"])
(check "re-seq a$ aab" (re/re-seq "a$" "aab") [])
(check "re-seq b$ aab" (re/re-seq "b$" "aab") ["b"])
(check "re-seq ^ aab" (re/re-seq "^" "aab") [""])
(check "re-seq $ aab" (re/re-seq "$" "aab") [""])
(check "re-seq ^$ empty" (re/re-seq "^$" "") [""])
(check "re-seq ^$ aab" (re/re-seq "^$" "aab") [])

(print-summary)
