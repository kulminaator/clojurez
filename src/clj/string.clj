;; Clojure String utilities
;;
;; Usage:
;;   (ns my.namespace
;;     (:require [clojure.string :as str]))

(ns clojure.string)

;; ---- Case conversion ----

(defn upper-case
  "Converts string to all upper-case."
  [s]
  (zig.core/upper-case s))

(defn lower-case
  "Converts string to all lower-case."
  [s]
  (zig.core/lower-case s))

(defn capitalize
  "Converts first character of the string to upper-case, all other
  characters to lower-case."
  [s]
  (zig.core/capitalize s))

;; ---- Whitespace trimming ----

(defn trim
  "Removes whitespace from both ends of string."
  [s]
  (zig.core/trim s))

(defn triml
  "Removes whitespace from the left side of string."
  [s]
  (zig.core/triml s))

(defn trimr
  "Removes whitespace from the right side of string."
  [s]
  (zig.core/trimr s))

(defn trim-newline
  "Removes all trailing newline or return characters from string."
  [s]
  (zig.core/trim-newline s))

;; ---- Predicates ----

(defn blank?
  "True if s is nil, empty, or contains only whitespace."
  [s]
  (if (nil? s) true (zig.core/blank? s)))

(defn starts-with?
  "True if s starts with substr."
  [s substr]
  (zig.core/starts-with? s substr))

(defn ends-with?
  "True if s ends with substr."
  [s substr]
  (zig.core/ends-with? s substr))

(defn includes?
  "True if s includes substr."
  [s substr]
  (zig.core/includes? s substr))

;; ---- String manipulation ----

(defn reverse
  "Returns s with its characters reversed."
  [s]
  (apply str (vec (map (fn [i] (subs s i (inc i)))
                       (range (dec (count s)) -1 -1)))))

(defn join
  "Returns a string of all elements in coll, separated by an optional separator."
  ([coll]
     (if (nil? coll) "" (apply str (vec coll))))
  ([separator coll]
     (if (nil? coll) "" (apply str (vec (interpose separator coll))))))

(defn escape
  "Return a new string, using cmap to escape each character ch from s."
  [s cmap]
  (apply str (vec (map (fn [ch]
                     (let [str-lookup (get cmap ch)
                           char-lookup (if str-lookup str-lookup (get cmap (char ch)))]
                        (or char-lookup ch)))
                   (map (fn [i] (subs s i (inc i))) (range (count s)))))))

;; ---- Index operations ----

(defn index-of
  "Return index of value (string or char) in s, optionally searching
  forward from from-index. Return nil if value not found."
  ([s value]
     (zig.core/index-of s value))
  ([s value from-index]
     (zig.core/index-of s value from-index)))

(defn last-index-of
  "Return last index of value (string or char) in s, optionally
  searching backward from from-index. Return nil if value not found."
  ([s value]
     (zig.core/last-index-of s value))
  ([s value from-index]
     (zig.core/last-index-of s value from-index)))

;; ---- Regular expression functions ----

(defn- strip-trailing-empty
  "Remove trailing empty strings from a vector."
  [v]
  (loop [i (dec (count v))]
    (if (and (>= i 0) (= (nth v i) ""))
      (recur (dec i))
      (vec (take (inc i) v)))))

(defn split
  "Splits string on a regular expression. Optional argument limit is
  the maximum number of parts. Returns vector of the parts.
  Trailing empty strings are not returned - pass limit of -1 to return all."
  ([s re]
     (split s re nil))
  ([s re limit]
     (let [s-str (str s)
           all-matches (zig.core/re-find-all re s-str)
           keep-all (neg? limit)
           has-limit (and limit (not (neg? limit)))]
       (if (empty? all-matches)
         [s-str]
         (let [result (loop [matches all-matches
                             parts []
                             last-end 0]
                        (if (empty? matches)
                          (conj parts (subs s-str last-end))
                          (let [me (first matches)
                                start (nth me 1)
                                end (nth me 2)
                                before (subs s-str last-end start)
                                pc (count (conj parts before))]
                            (if (and has-limit (>= pc limit))
                              (conj parts (subs s-str last-end))
                              (recur (rest matches) (conj parts before) end)))))]
           (cond
             keep-all (vec result)
             has-limit (vec (take limit result))
             :else (strip-trailing-empty (vec result))))))))

(defn split-lines
  "Splits s on newline or carriage return+newline. Trailing empty lines are not returned."
  [s]
  (split s #"\r?\n"))

(defn re-quote-replacement
  "Escape special characters in the replacement string."
  [replacement]
  (let [s (str replacement)]
    (loop [i 0
           result ""]
      (if (>= i (count s))
        result
        (let [ch (subs s i (inc i))]
          (recur (inc i)
                 (str result
                      (if (or (= ch "\\") (= ch "$"))
                        (str "\\" ch)
                        ch))))))))

(defn- replace-all-str
  "Replace all occurrences of match-string with replacement in s."
  [s match replacement]
  (loop [result ""
         remaining s]
    (let [idx (index-of remaining match)]
      (if idx
        (recur (str result (subs remaining 0 idx) replacement)
               (subs remaining (+ idx (count match))))
        (str result remaining)))))

(defn- replace-all-char
  "Replace all occurrences of match-char with replacement in s."
  [s match replacement]
  (replace-all-str s (str match) (str replacement)))

(defn- replace-by
  "Replace all regex matches using a function for replacement."
  [s re f]
  (let [s-str (str s)
        all-matches (zig.core/re-find-all re s-str)]
    (if (empty? all-matches)
      s-str
      (loop [matches all-matches
             result ""
             last-end 0]
        (if (empty? matches)
          (str result (subs s-str last-end))
          (let [me (first matches)
                mt (nth me 0)
                start (nth me 1)
                end (nth me 2)
                before (subs s-str last-end start)
                rs (str (f mt))]
            (recur (rest matches)
                   (str result before rs)
                   end)))))))

(defn replace
  "Replaces all instance of match with replacement in s.
  match/replacement can be: string/string, char/char, pattern/(string or function)."
  [s match replacement]
  (cond
    (char? match) (replace-all-char s match replacement)
    (string? match) (replace-all-str s match (str replacement))
    :else
    (if (fn? replacement)
      (replace-by s match replacement)
      (replace-by s match (constantly (str replacement))))))

(defn- replace-first-str
  "Replace first occurrence of match-string with replacement in s."
  [s match replacement]
  (let [idx (index-of s match)]
    (if (nil? idx)
      s
      (str (subs s 0 idx) replacement (subs s (+ idx (count match)))))))

(defn- replace-first-char
  "Replace first occurrence of match-char with replacement in s."
  [s match replacement]
  (replace-first-str s (str match) (str replacement)))

(defn- replace-first-by
  "Replace first regex match using a function for replacement."
  [s re f]
  (let [s-str (str s)
        mi (zig.core/re-find-with-index re s-str)]
    (if (nil? mi)
      s-str
      (let [mt (nth mi 0)
            start (nth mi 1)
            end (nth mi 2)
            before (subs s-str 0 start)
            after (subs s-str end)
            rs (str (f mt))]
        (str before rs after)))))

(defn replace-first
  "Replaces the first instance of match with replacement in s.
  match/replacement can be: char/char, string/string, pattern/(string or function)."
  [s match replacement]
  (cond
    (char? match) (replace-first-char s match replacement)
    (string? match) (replace-first-str s match (str replacement))
    (fn? replacement) (replace-first-by s match replacement)
    :else
    (let [s-str (str s)
          mi (zig.core/re-find-with-index match s-str)]
      (if (nil? mi)
        s-str
        (let [start (nth mi 1)
              end (nth mi 2)
              before (subs s-str 0 start)
              after (subs s-str end)]
          (str before (str replacement) after))))))
