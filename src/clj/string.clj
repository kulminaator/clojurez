;; Clojure String utilities
;; Non-regex functions from clojure.string namespace.
;;
;; Usage:
;;   (ns my.namespace
;;     (:require [clojure.string :as str]))
;;
;;   (str/upper-case "hello")  => "HELLO"
;;   (str/join "," ["a" "b"])  => "a,b"

(ns clojure.string)

;; ---- Case conversion ----
;; Delegated to Zig built-ins for performance.

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
;; Delegated to Zig built-ins for performance.

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
  "Removes all trailing newline \\n or return \\r characters from
  string. Similar to Perl's chomp."
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
  "Returns a string of all elements in coll, as returned by (seq coll),
   separated by an optional separator."
  ([coll]
     (apply str (vec coll)))
  ([separator coll]
     (apply str (vec (interpose separator coll)))))

(defn escape
  "Return a new string, using cmap to escape each character ch
   from s as follows:

   If (cmap ch) is nil, append ch to the new string.
   If (cmap ch) is non-nil, append (str (cmap ch)) instead."
  [s cmap]
  (apply str (vec (map (fn [ch]
                     (or (get cmap ch) ch))
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
