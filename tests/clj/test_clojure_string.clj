;; clojure.string namespace tests
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

;; --- upper-case ---
(check "upper-case basic" (str/upper-case "hello") "HELLO")
(check "upper-case already upper" (str/upper-case "HELLO") "HELLO")
(check "upper-case mixed" (str/upper-case "hElLo WoRlD") "HELLO WORLD")
(check "upper-case empty" (str/upper-case "") "")
(check "upper-case with numbers" (str/upper-case "abc123") "ABC123")

;; --- lower-case ---
(check "lower-case basic" (str/lower-case "HELLO") "hello")
(check "lower-case already lower" (str/lower-case "hello") "hello")
(check "lower-case mixed" (str/lower-case "hElLo WoRlD") "hello world")
(check "lower-case empty" (str/lower-case "") "")
(check "lower-case with numbers" (str/lower-case "ABC123") "abc123")

;; --- capitalize ---
(check "capitalize basic" (str/capitalize "hello") "Hello")
(check "capitalize mixed" (str/capitalize "hElLo") "Hello")
(check "capitalize empty" (str/capitalize "") "")
(check "capitalize single" (str/capitalize "h") "H")
(check "capitalize all caps" (str/capitalize "HELLO") "Hello")

;; --- trim ---
(check "trim both sides" (str/trim "  hello  ") "hello")
(check "trim left only" (str/trim "  hello") "hello")
(check "trim right only" (str/trim "hello  ") "hello")
(check "trim no spaces" (str/trim "hello") "hello")
(check "trim empty" (str/trim "") "")
(check "trim all spaces" (str/trim "   ") "")
(check "trim tabs" (str/trim "\thello\t") "hello")
(check "trim newlines" (str/trim "\nhello\n") "hello")

;; --- triml ---
(check "triml basic" (str/triml "  hello  ") "hello  ")
(check "triml no spaces" (str/triml "hello") "hello")
(check "triml empty" (str/triml "") "")
(check "triml all spaces" (str/triml "   ") "")

;; --- trimr ---
(check "trimr basic" (str/trimr "  hello  ") "  hello")
(check "trimr no spaces" (str/trimr "hello") "hello")
(check "trimr empty" (str/trimr "") "")
(check "trimr all spaces" (str/trimr "   ") "")

;; --- trim-newline ---
(check "trim-newline basic" (str/trim-newline "hello\n") "hello")
(check "trim-newline multiple" (str/trim-newline "hello\n\n\n") "hello")
(check "trim-newline cr" (str/trim-newline "hello\r") "hello")
(check "trim-newline crlf" (str/trim-newline "hello\r\n") "hello")
(check "trim-newline no newline" (str/trim-newline "hello") "hello")
(check "trim-newline empty" (str/trim-newline "") "")

;; --- blank? ---
(check "blank? nil" (str/blank? nil) true)
(check "blank? empty" (str/blank? "") true)
(check "blank? spaces" (str/blank? "   ") true)
(check "blank? tabs" (str/blank? "\t\t") true)
(check "blank? text" (str/blank? "hello") false)
(check "blank? text with spaces" (str/blank? " hello ") false)

;; --- starts-with? ---
(check "starts-with? true" (str/starts-with? "hello" "hel") true)
(check "starts-with? false" (str/starts-with? "hello" "world") false)
(check "starts-with? full match" (str/starts-with? "hello" "hello") true)
(check "starts-with? empty" (str/starts-with? "hello" "") true)

;; --- ends-with? ---
(check "ends-with? true" (str/ends-with? "hello" "lo") true)
(check "ends-with? false" (str/ends-with? "hello" "world") false)
(check "ends-with? full match" (str/ends-with? "hello" "hello") true)
(check "ends-with? empty" (str/ends-with? "hello" "") true)

;; --- includes? ---
(check "includes? true" (str/includes? "hello world" "lo w") true)
(check "includes? false" (str/includes? "hello world" "xyz") false)
(check "includes? full match" (str/includes? "hello" "hello") true)
(check "includes? empty" (str/includes? "hello" "") true)

;; --- reverse ---
(check "reverse basic" (str/reverse "hello") "olleh")
(check "reverse empty" (str/reverse "") "")
(check "reverse single" (str/reverse "a") "a")
(check "reverse palindrome" (str/reverse "aba") "aba")

;; --- join ---
(check "join with separator" (str/join "," ["a" "b" "c"]) "a,b,c")
(check "join no separator" (str/join ["a" "b" "c"]) "abc")
(check "join empty" (str/join "," []) "")
(check "join single" (str/join "," ["a"]) "a")

;; --- escape ---
(check "escape basic" (str/escape "hello" {"o" "0"}) "hell0")
(check "escape no match" (str/escape "hello" {"x" "y"}) "hello")
(check "escape empty" (str/escape "" {"a" "b"}) "")
(check "escape multiple" (str/escape "hello" {"h" "H" "o" "0"}) "Hell0")

;; --- index-of ---
(check "index-of found" (str/index-of "hello world" "world") 6)
(check "index-of not found" (str/index-of "hello world" "xyz") nil)
(check "index-of at start" (str/index-of "hello" "hel") 0)
(check "index-of empty needle" (str/index-of "hello" "") 0)
(check "index-of with from-index" (str/index-of "hello hello" "hello" 3) 6)

;; --- last-index-of ---
(check "last-index-of found" (str/last-index-of "hello hello" "hello") 6)
(check "last-index-of not found" (str/last-index-of "hello world" "xyz") nil)
(check "last-index-of single" (str/last-index-of "hello" "hello") 0)
(check "last-index-of empty needle" (str/last-index-of "hello" "") 5)

(print-summary)
