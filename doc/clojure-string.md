# clojure.string


## Table of Contents

- [blank?](#blank?)
- [capitalize](#capitalize)
- [ends-with?](#ends-with?)
- [escape](#escape)
- [includes?](#includes?)
- [index-of](#index-of)
- [join](#join)
- [last-index-of](#last-index-of)
- [lower-case](#lower-case)
- [re-quote-replacement](#re-quote-replacement)
- [replace](#replace)
- [replace-all-char](#replace-all-char)
- [replace-all-str](#replace-all-str)
- [replace-by](#replace-by)
- [replace-first](#replace-first)
- [replace-first-by](#replace-first-by)
- [replace-first-char](#replace-first-char)
- [replace-first-str](#replace-first-str)
- [reverse](#reverse)
- [split](#split)
- [split-lines](#split-lines)
- [starts-with?](#starts-with?)
- [strip-trailing-empty](#strip-trailing-empty)
- [trim](#trim)
- [trim-newline](#trim-newline)
- [triml](#triml)
- [trimr](#trimr)
- [upper-case](#upper-case)

---

## blank?

[(s)]

True if s is nil, empty, or contains only whitespace.

---

## capitalize

[(s)]

Converts first character of the string to upper-case, all other
  characters to lower-case.

---

## ends-with?

[(s substr)]

True if s ends with substr.

---

## escape

[(s cmap)]

Return a new string, using cmap to escape each character ch from s.

---

## includes?

[(s substr)]

True if s includes substr.

---

## index-of

[(s value) (s value from-index)]

Return index of value (string or char) in s, optionally searching
  forward from from-index. Return nil if value not found.

---

## join

[(coll) (separator coll)]

Returns a string of all elements in coll, separated by an optional separator.

---

## last-index-of

[(s value) (s value from-index)]

Return last index of value (string or char) in s, optionally
  searching backward from from-index. Return nil if value not found.

---

## lower-case

[(s)]

Converts string to all lower-case.

---

## re-quote-replacement

[(replacement)]

Escape special characters in the replacement string.

---

## replace

[(s match replacement)]

Replaces all instance of match with replacement in s.
  match/replacement can be: string/string, char/char, pattern/(string or function).

---

## replace-all-char

[(s match replacement)]

Replace all occurrences of match-char with replacement in s.

---

## replace-all-str

[(s match replacement)]

Replace all occurrences of match-string with replacement in s.

---

## replace-by

[(s re f)]

Replace all regex matches using a function for replacement.

---

## replace-first

[(s match replacement)]

Replaces the first instance of match with replacement in s.
  match/replacement can be: char/char, string/string, pattern/(string or function).

---

## replace-first-by

[(s re f)]

Replace first regex match using a function for replacement.

---

## replace-first-char

[(s match replacement)]

Replace first occurrence of match-char with replacement in s.

---

## replace-first-str

[(s match replacement)]

Replace first occurrence of match-string with replacement in s.

---

## reverse

[(s)]

Returns s with its characters reversed.

---

## split

[(s re) (s re limit)]

Splits string on a regular expression. Optional argument limit is
  the maximum number of parts. Returns vector of the parts.
  Trailing empty strings are not returned - pass limit of -1 to return all.

---

## split-lines

[(s)]

Splits s on newline or carriage return+newline. Trailing empty lines are not returned.

---

## starts-with?

[(s substr)]

True if s starts with substr.

---

## strip-trailing-empty

[(v)]

Remove trailing empty strings from a vector.

---

## trim

[(s)]

Removes whitespace from both ends of string.

---

## trim-newline

[(s)]

Removes all trailing newline or return characters from string.

---

## triml

[(s)]

Removes whitespace from the left side of string.

---

## trimr

[(s)]

Removes whitespace from the right side of string.

---

## upper-case

[(s)]

Converts string to all upper-case.
