;; Character Type Tests: char literals, char?, char coercion
(load-file "tests/clj/clj_test_helper.clj")

;; ---- Char Literal Tests ----
(check "char literal A" (char? \A) true)
(check "char literal a" (char? \a) true)
(check "char literal !" (char? \!) true)
(check "char literal ." (char? \.) true)
(check "char literal #" (char? \#) true)
(check "char literal 0" (char? \0) true)
(check "char literal 9" (char? \9) true)

;; ---- Named Escape Tests ----
(check "char newline" (char? \newline) true)
(check "char tab" (char? \tab) true)
(check "char return" (char? \return) true)
(check "char space" (char? \space) true)
(check "char formfeed" (char? \formfeed) true)

;; ---- Unicode Escape Tests ----
(check "char unicode A" (char? \u0041) true)
(check "char unicode equals A" (= \u0041 \A) true)

;; ---- Octal Escape Tests ----
(check "char octal 0" (char? \o0) true)
(check "char octal 47" (char? \o47) true)

;; ---- char? with non-chars ----
(check "char? string false" (char? "hello") false)
(check "char? int false" (char? 65) false)
(check "char? nil false" (char? nil) false)
(check "char? bool false" (char? true) false)
(check "char? list false" (char? '(1 2)) false)

;; ---- char coercion from int ----
(check "char from int 65" (= (char 65) \A) true)
(check "char from int 97" (= (char 97) \a) true)
(check "char from int 10" (= (char 10) \newline) true)
(check "char from int 32" (= (char 32) \space) true)
(check "char from int 0" (= (char 0) (char 0)) true)

;; ---- char coercion from char (identity) ----
(check "char from char" (= (char \A) \A) true)
(check "char from char newline" (= (char \newline) \newline) true)

;; ---- char coercion from float ----
(check "char from float" (= (char 65.0) \A) true)
(check "char from float truncated" (= (char 97.9) \a) true)

;; ---- Char equality ----
(check "char equal same" (= \A \A) true)
(check "char equal different" (= \A \B) false)
(check "char equal int coercion" (= (char 65) \A) true)

;; ---- str with chars ----
(check "str single char" (str \A) "A")
(check "str two chars" (str \A \B) "AB")
(check "str char and string" (str \H "i") "Hi")
(check "str newline char" (str \newline) "\n")
(check "str space char" (str \space) " ")

;; ---- Char in collections ----
(check "char in list" (list? (list \A \B \C)) true)
(check "char in vector" (vector? [\A \B \C]) true)
(check "first char from list" (= (first '(\A \B)) \A) true)

;; ---- char is truthy ----
(check "char truthy" (if \A true false) true)

(print-summary)
