;; UTF-8 String Tests: estonian, emoji, japanese, unicode escapes,
;; utf8-valid?, equality, type checks, print, nth, complex expressions,
;; lists/vectors/maps with UTF-8
(load-file "tests/clj/clj_test_helper.clj")

;; Estonian strings
(check "utf8 estonian string" "jõeääreööbiku ülkskõiksus" "jõeääreööbiku ülkskõiksus")
(check "utf8 estonian count" (count "jõeääreööbiku ülkskõiksus") 25)
(check "utf8 estonian nth 0" (nth "jõeääreööbiku ülkskõiksus" 0) \j)
(check "utf8 estonian nth 1" (nth "jõeääreööbiku ülkskõiksus" 1) \õ)
(check "utf8 estonian nth 2" (nth "jõeääreööbiku ülkskõiksus" 2) \e)
(check "utf8 estonian str concat" (str "jõeää" "reöö" "biku") "jõeääreööbiku")

;; Emoji
(check "utf8 smiley string" "😀😃😄😁" "😀😃😄😁")
(check "utf8 smiley count" (count "😀😃😄😁") 4)
(check "utf8 smiley nth 0" (nth "😀😃😄😁" 0) \😀)
(check "utf8 smiley nth 2" (nth "😀😃😄😁" 2) \😄)
(check "utf8 mixed text emoji" (str "Hello " "😀" " World") "Hello 😀 World")
(check "utf8 emoji count mixed" (count "Hi😀there") 8)

;; Japanese
(check "utf8 japanese string" "古池や蛙飛び込む水の音" "古池や蛙飛び込む水の音")
(check "utf8 japanese count" (count "古池や蛙飛び込む水の音") 11)
(check "utf8 japanese nth 0" (nth "古池や蛙飛び込む水の音" 0) \古)
(check "utf8 japanese nth 10" (nth "古池や蛙飛び込む水の音" 10) \音)

;; Unicode escape sequences
(check "unicode escape basic" "\u0048\u0065\u006C\u006C\u006F" "Hello")
(check "unicode escape estonian" "\u00F5\u00E4\u00F6" "õäö")
(check "unicode escape smiley" "\u{1F600}" "😀")
(check "unicode escape japanese" "\u53E4\u6C60" "古池")

;; utf8-valid?
(check "utf8-valid valid string" (utf8-valid? "hello") true)
(check "utf8-valid estonian" (utf8-valid? "jõeääreööbiku") true)
(check "utf8-valid emoji" (utf8-valid? "😀") true)
(check "utf8-valid japanese" (utf8-valid? "古池や") true)

;; String equality with UTF-8
(check "utf8 equality same" (= "jõä" "jõä") true)
(check "utf8 equality different" (= "jõä" "jõö") false)
(check "utf8 equality emoji" (= "😀" "😀") true)
(check "utf8 equality emoji different" (= "😀" "😃") false)
(check "utf8 equality japanese" (= "古池" "古池") true)

;; String type check with UTF-8
(check "utf8 string? estonian" (string? "jõä") true)
(check "utf8 string? emoji" (string? "😀") true)
(check "utf8 string? japanese" (string? "古池") true)

;; Print with UTF-8
(check "utf8 print estonian" (do (print "jõä") nil) nil)
(check "utf8 print emoji" (do (print "😀") nil) nil)
(check "utf8 print japanese" (do (print "古池") nil) nil)

;; nth out of bounds for UTF-8 strings
(check "utf8 nth out of bounds" (nth "jõä" 10) nil)

;; Complex mixed UTF-8 expression
(check "utf8 complex expression" (let [greeting "tere mõnda😀"] (str greeting " maailm!")) "tere mõnda😀 maailm!")

;; UTF-8 in lists and vectors
(check "utf8 list estonian" (list "jõä" "reöö" "biku") '("jõä" "reöö" "biku"))
(check "utf8 vector emoji" ["😀" "😃" "😄"] '["😀" "😃" "😄"])

;; UTF-8 in map keys/values
(check "utf8 map estonian" {:jõä 1 :reöö 2} '{:jõä 1 :reöö 2})
(check "utf8 map emoji value" {:greeting "😀"} '{:greeting "😀"})

;; Unicode escape \u{XXXXX}
(check "unicode escape curly brace" "\u{1F600}\u{1F603}" "😀😃")
(check "unicode escape mixed formats" "\u0048\u{1F600}\u006F" "H😀o")

;; UTF-8 in function parameters
(check "utf8 fn estonian" ((fn [s] (count s)) "jõä") 3)
(check "utf8 fn emoji" ((fn [s] (nth s 1)) "😀😃😄") \😃)

;; UTF-8 keyword
(check "utf8 keyword estonian" :jõä ':jõä)
(check "utf8 keyword emoji" :😀 ':😀)

;; UTF-8 symbol (quoted to avoid lookup)
(check "utf8 symbol estonian" 'jõä 'jõä)

;; Empty UTF-8 string
(check "utf8 empty string count" (count "") 0)
(check "utf8 empty string nth" (nth "" 0) nil)

(print-summary)
