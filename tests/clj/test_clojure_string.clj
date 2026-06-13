;; clojure.string namespace tests
;; Define check in clojure.core so it's accessible from all namespaces.
(ns clojure.core)
(def passes (atom 0))
(def failures (atom 0))
(defn check [name result expected]
  (if (= result expected)
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected=" expected " got=" result)))))
(defn print-summary []
  (println (str "SUMMARY: " @passes " passed, " @failures " failed")))
(ns user)

(ns my-test (:require [clojure.string :as str]))

;; ============================================================
;; upper-case
;; ============================================================
(check "upper-case basic" (str/upper-case "hello") "HELLO")
(check "upper-case already upper" (str/upper-case "HELLO") "HELLO")
(check "upper-case mixed" (str/upper-case "hElLo WoRlD") "HELLO WORLD")
(check "upper-case empty" (str/upper-case "") "")
(check "upper-case with numbers" (str/upper-case "abc123") "ABC123")

;; ============================================================
;; lower-case
;; ============================================================
(check "lower-case basic" (str/lower-case "HELLO") "hello")
(check "lower-case already lower" (str/lower-case "hello") "hello")
(check "lower-case mixed" (str/lower-case "hElLo WoRlD") "hello world")
(check "lower-case empty" (str/lower-case "") "")
(check "lower-case with numbers" (str/lower-case "ABC123") "abc123")

;; ============================================================
;; capitalize
;; ============================================================
(check "capitalize basic" (str/capitalize "hello") "Hello")
(check "capitalize mixed" (str/capitalize "hElLo") "Hello")
(check "capitalize empty" (str/capitalize "") "")
(check "capitalize single" (str/capitalize "h") "H")
(check "capitalize all caps" (str/capitalize "HELLO") "Hello")
(check "capitalize foobar" (str/capitalize "foobar") "Foobar")
(check "capitalize POW" (str/capitalize "POW") "Pow")
(check "capitalize FOOBAR" (str/capitalize "FOOBAR") "Foobar")

;; ============================================================
;; trim
;; ============================================================
(check "trim both sides" (str/trim "  hello  ") "hello")
(check "trim left only" (str/trim "  hello") "hello")
(check "trim right only" (str/trim "hello  ") "hello")
(check "trim no spaces" (str/trim "hello") "hello")
(check "trim empty" (str/trim "") "")
(check "trim all spaces" (str/trim "   ") "")
(check "trim tabs" (str/trim "\thello\t") "hello")
(check "trim newlines" (str/trim "\nhello\n") "hello")
(check "trim crlf" (str/trim "\r\nhello\r\n") "hello")

;; ============================================================
;; triml
;; ============================================================
(check "triml basic" (str/triml "  hello  ") "hello  ")
(check "triml no spaces" (str/triml "hello") "hello")
(check "triml empty" (str/triml "") "")
(check "triml all spaces" (str/triml "   ") "")
(check "triml foo space" (str/triml " foo ") "foo ")

;; ============================================================
;; trimr
;; ============================================================
(check "trimr basic" (str/trimr "  hello  ") "  hello")
(check "trimr no spaces" (str/trimr "hello") "hello")
(check "trimr empty" (str/trimr "") "")
(check "trimr all spaces" (str/trimr "   ") "")
(check "trimr space foo" (str/trimr " foo ") " foo")

;; ============================================================
;; trim-newline
;; ============================================================
(check "trim-newline basic" (str/trim-newline "hello\n") "hello")
(check "trim-newline multiple" (str/trim-newline "hello\n\n\n") "hello")
(check "trim-newline cr" (str/trim-newline "hello\r") "hello")
(check "trim-newline crlf" (str/trim-newline "hello\r\n") "hello")
(check "trim-newline no newline" (str/trim-newline "hello") "hello")
(check "trim-newline empty" (str/trim-newline "") "")
(check "trim-newline mixed cr lf" (str/trim-newline "the end\r\n\r\r\n") "the end")
(check "trim-newline all newlines lf" (str/trim-newline "\n\n\n") "")
(check "trim-newline all newlines cr" (str/trim-newline "\r\r\r") "")

;; ============================================================
;; blank?
;; ============================================================
(check "blank? nil" (str/blank? nil) true)
(check "blank? empty" (str/blank? "") true)
(check "blank? spaces" (str/blank? "   ") true)
(check "blank? tabs" (str/blank? "\t\t") true)
(check "blank? mixed whitespace" (str/blank? " \t \n  \r ") true)
(check "blank? text" (str/blank? "hello") false)
(check "blank? text with spaces" (str/blank? " hello ") false)

;; ============================================================
;; starts-with?
;; ============================================================
(check "starts-with? true" (str/starts-with? "hello" "hel") true)
(check "starts-with? false" (str/starts-with? "hello" "world") false)
(check "starts-with? full match" (str/starts-with? "hello" "hello") true)
(check "starts-with? empty" (str/starts-with? "hello" "") true)
(check "starts-with? empty both" (str/starts-with? "" "") true)
(check "starts-with? empty string" (str/starts-with? "" "hello") false)

;; ============================================================
;; ends-with?
;; ============================================================
(check "ends-with? true" (str/ends-with? "hello" "lo") true)
(check "ends-with? false" (str/ends-with? "hello" "world") false)
(check "ends-with? full match" (str/ends-with? "hello" "hello") true)
(check "ends-with? empty" (str/ends-with? "hello" "") true)
(check "ends-with? empty both" (str/ends-with? "" "") true)
(check "ends-with? empty string" (str/ends-with? "" "hello") false)

;; ============================================================
;; includes?
;; ============================================================
(check "includes? true" (str/includes? "hello world" "lo w") true)
(check "includes? false" (str/includes? "hello world" "xyz") false)
(check "includes? full match" (str/includes? "hello" "hello") true)
(check "includes? empty needle" (str/includes? "hello" "") true)
(check "includes? empty both" (str/includes? "" "") true)
(check "includes? empty haystack" (str/includes? "" "hello") false)

;; ============================================================
;; reverse
;; ============================================================
(check "reverse basic" (str/reverse "hello") "olleh")
(check "reverse empty" (str/reverse "") "")
(check "reverse single" (str/reverse "a") "a")
(check "reverse palindrome" (str/reverse "aba") "aba")
(check "reverse with spaces" (str/reverse "hello world") "dlrow olleh")
(check "reverse two chars" (str/reverse "ab") "ba")

;; ============================================================
;; join
;; ============================================================
(check "join with separator" (str/join "," ["a" "b" "c"]) "a,b,c")
(check "join no separator" (str/join ["a" "b" "c"]) "abc")
(check "join empty" (str/join "," []) "")
(check "join single" (str/join "," ["a"]) "a")
(check "join empty no separator" (str/join []) "")
(check "join with numbers" (str/join "," [1 2 3]) "1,2,3")
(check "join single number" (str/join "," [1]) "1")
(check "join with long separator" (str/join " and " [1 2 3]) "1 and 2 and 3")
(check "join nil collection" (str/join nil) "")
(check "join nil collection with separator" (str/join "," nil) "")

;; ============================================================
;; escape
;; ============================================================
(check "escape basic" (str/escape "hello" {"o" "0"}) "hell0")
(check "escape no match" (str/escape "hello" {"x" "y"}) "hello")
(check "escape empty" (str/escape "" {"a" "b"}) "")
(check "escape multiple" (str/escape "hello" {"h" "H" "o" "0"}) "Hell0")
(check "escape html" (str/escape "<foo&bar>" {"&" "&amp;" "<" "&lt;" ">" "&gt;"}) "&lt;foo&amp;bar&gt;")
(check "escape char keys" (str/escape "fo lo lo" {\o \a}) "fa la la")
(check "escape char swap" (str/escape "foobar" {\a \o \o \a}) "faabor")
(check "escape quote" (str/escape " \"foo\" " {"\"" "\\\""}) " \\\"foo\\\" ")

;; ============================================================
;; index-of
;; ============================================================
(check "index-of found" (str/index-of "hello world" "world") 6)
(check "index-of not found" (str/index-of "hello world" "xyz") nil)
(check "index-of at start" (str/index-of "hello" "hel") 0)
(check "index-of empty needle" (str/index-of "hello" "") 0)
(check "index-of with from-index" (str/index-of "hello hello" "hello" 3) 6)
(check "index-of from-index past end" (str/index-of "hello hello" "hello" 10) nil)
(check "index-of from-index negative" (str/index-of "hello hello" "hello" -5) 0)
(check "index-of empty needle from-index" (str/index-of "hello" "" 3) 3)
(check "index-of char found" (str/index-of "tacos" \c) 2)
(check "index-of char not found" (str/index-of "tacos" \z) nil)
(check "index-of char with from-index" (str/index-of "tacos" \o 2) 3)
(check "index-of char from-index negative" (str/index-of "tacos" \o -100) 3)
(check "index-of char from-index past end" (str/index-of "tacos" \z 100) nil)
(check "index-of char from-index negative far" (str/index-of "tacos" \z -10) nil)
(check "index-of multi char" (str/index-of "tacos" "ac") 1)
(check "index-of multi char from-index" (str/index-of "tacos" "o" 2) 3)

;; ============================================================
;; last-index-of
;; ============================================================
(check "last-index-of found" (str/last-index-of "hello hello" "hello") 6)
(check "last-index-of not found" (str/last-index-of "hello world" "xyz") nil)
(check "last-index-of single" (str/last-index-of "hello" "hello") 0)
(check "last-index-of empty needle" (str/last-index-of "hello" "") 5)
(check "last-index-of from-index 3" (str/last-index-of "hello hello" "hello" 3) 0)
(check "last-index-of from-index 10" (str/last-index-of "hello hello" "hello" 10) 6)
(check "last-index-of from-index negative" (str/last-index-of "hello hello" "hello" -5) nil)
(check "last-index-of char found" (str/last-index-of "banana" \n) 4)
(check "last-index-of char not found" (str/last-index-of "banana" \z) nil)
(check "last-index-of char from-index" (str/last-index-of "banana" \n 5) 4)
(check "last-index-of char from-index far" (str/last-index-of "banana" \n 500) 4)
(check "last-index-of char from-index small" (str/last-index-of "banana" \z 1) nil)
(check "last-index-of char from-index far not found" (str/last-index-of "banana" \z 100) nil)
(check "last-index-of char from-index negative" (str/last-index-of "banana" \z -10) nil)
(check "last-index-of multi char" (str/last-index-of "banana" "an") 3)

;; ============================================================
;; split - basic
;; ============================================================
(check "split basic" (str/split "a-b-c" #"-") ["a" "b" "c"])
(check "split no match" (str/split "hello" #"-") ["hello"])
(check "split empty string" (str/split "" #"-") [])
(check "split consecutive" (str/split "a--b" #"-") ["a" "b"])
(check "split trailing" (str/split "a,b,c," #",") ["a" "b" "c"])
(check "split only delimiter" (str/split "," #",") [])
(check "split only delimiter unlimited" (str/split "," #"," -1) ["" ""])
(check "split consecutive unlimited" (str/split "a,,b" #",") ["a" "" "b"])
(check "split consecutive unlimited limit" (str/split "a,,b" #"," -1) ["a" "" "b"])
(check "split regex" (str/split "a--b" #"-+") ["a" "b"])

;; ============================================================
;; split - with limit
;; ============================================================
(check "split limit 2" (str/split "a-b-c" #"-" 2) ["a" "b-c"])
(check "split limit 3" (str/split "a-b-c" #"-" 3) ["a" "b" "c"])
(check "split limit 4" (str/split "a-b-c" #"-" 4) ["a" "b" "c"])
(check "split limit 1" (str/split "a-b-c" #"-" 1) ["a-b-c"])
(check "split limit large" (str/split "a-b-c" #"-" 10) ["a" "b" "c"])
(check "split limit 2 trailing" (str/split "a-b-c-" #"-" 2) ["a" "b-c-"])
(check "split limit 2 multi" (str/split "a-b-c-d" #"-" 2) ["a" "b-c-d"])
(check "split limit 3 multi" (str/split "a-b-c-d" #"-" 3) ["a" "b" "c-d"])
(check "split limit -1" (str/split "a,b,c," #"," -1) ["a" "b" "c" ""])

;; ============================================================
;; split-lines
;; ============================================================
(check "split-lines basic" (str/split-lines "one\ntwo\r\nthree") ["one" "two" "three"])
(check "split-lines trailing newline" (str/split-lines "one\ntwo\n") ["one" "two"])
(check "split-lines no newline" (str/split-lines "hello") ["hello"])
(check "split-lines empty" (str/split-lines "") [])
(check "split-lines only newlines" (str/split-lines "\n\n") [])
(check "split-lines crlf" (str/split-lines "a\r\nb") ["a" "b"])
(check "split-lines cr" (str/split-lines "a\rb") ["a" "b"])

;; ============================================================
;; replace - string
;; ============================================================
(check "replace string basic" (str/replace "foobarfoo" "foo" "bar") "barbarbar")
(check "replace string no match" (str/replace "foobarfoo" "baz" "bar") "foobarfoo")
(check "replace string dollar" (str/replace "food" "o" "$") "f$$d")
(check "replace string backslash" (str/replace "food" "o" "\\") "f\\\\d")
(check "replace string spaces" (str/replace "a b c" " " "-") "a-b-c")
(check "replace string no match 2" (str/replace "hello" "xyz" "abc") "hello")
(check "replace string empty" (str/replace "" "a" "b") "")

;; ============================================================
;; replace - regex
;; ============================================================
(check "replace regex basic" (str/replace "foobarfoo" #"foo" "bar") "barbarbar")
(check "replace regex no match" (str/replace "foobarfoo" #"baz" "bar") "foobarfoo")
(check "replace regex function" (str/replace "foobarfoo" #"foo" str/upper-case) "FOObarFOO")
(check "replace regex constantly" (str/replace "foobarfoo" #"foo" (constantly "X")) "XbarX")
(check "replace regex groups" (str/replace "foobarfoo" #"f(o+)" (fn [[m g1]] (str/upper-case g1))) "OObarOO")
(check "replace regex groups piglatin" (str/replace "Almost Pig Latin" #"\b(\w)(\w+)\b" "$2$1ay") "lmostAay igPay atinLay")
(check "replace regex constantly backslash" (str/replace "bazslashbangslash" #"slash" (constantly "\\")) "baz\\bang\\")

;; ============================================================
;; replace - char
;; ============================================================
(check "replace char basic" (str/replace "foobar" \o \a) "faabar")
(check "replace char no match" (str/replace "foobar" \z \a) "foobar")
(check "replace char multiple" (str/replace "foobarfoo" \o \x) "fxxbarfxx")

;; ============================================================
;; replace-first - string
;; ============================================================
(check "replace-first string basic" (str/replace-first "foobarfoo" "foo" "bar") "barbarfoo")
(check "replace-first string no match" (str/replace-first "foobarfoo" "baz" "bar") "foobarfoo")
(check "replace-first string dollar" (str/replace-first "food" "o" "$") "f$od")
(check "replace-first string backslash" (str/replace-first "food" "o" "\\") "f\\od")
(check "replace-first string no match 2" (str/replace-first "hello" "xyz" "abc") "hello")
(check "replace-first string empty" (str/replace-first "" "a" "b") "")

;; ============================================================
;; replace-first - regex
;; ============================================================
(check "replace-first regex basic" (str/replace-first "foobarfoo" #"foo" "bar") "barbarfoo")
(check "replace-first regex no match" (str/replace-first "foobarfoo" #"baz" "bar") "foobarfoo")
(check "replace-first regex function" (str/replace-first "foobarfoo" #"foo" str/upper-case) "FOObarfoo")
(check "replace-first regex constantly" (str/replace-first "foobarfoo" #"foo" (constantly "X")) "Xbarfoo")
(check "replace-first regex groups" (str/replace-first "foobarfoo" #"f(o+)" (fn [[m g1]] (str/upper-case g1))) "OObarfoo")
(check "replace-first regex constantly backslash" (str/replace-first "bazslashbangslash" #"slash" (constantly "\\")) "baz\\bangslash")

;; ============================================================
;; replace-first - char
;; ============================================================
(check "replace-first char basic" (str/replace-first "foobar" \o \a) "faobar")
(check "replace-first char no match" (str/replace-first "foobar" \z \a) "foobar")
(check "replace-first char dot" (str/replace-first "zoology" \o \.) "z.ology")

;; ============================================================
;; re-quote-replacement
;; ============================================================
(check "re-quote-replacement dollar" (str/re-quote-replacement "$1") "\\$1")
(check "re-quote-replacement backslash" (str/re-quote-replacement "\\") "\\\\")
(check "re-quote-replacement backslash dollar" (str/re-quote-replacement "\\ $") "\\\\ \\$")
(check "re-quote-replacement plain" (str/re-quote-replacement "hello") "hello")

;; ============================================================
;; Summary
;; ============================================================
(print-summary)
