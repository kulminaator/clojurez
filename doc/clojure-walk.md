# clojure.walk


## Table of Contents

- [keywordize-keys](#keywordize-keys)
- [postwalk](#postwalk)
- [postwalk-replace](#postwalk-replace)
- [prewalk](#prewalk)
- [prewalk-replace](#prewalk-replace)
- [stringify-keys](#stringify-keys)
- [walk](#walk)

---

## keywordize-keys

[(m)]

Recursively transforms all map keys from strings to keywords.

---

## postwalk

[(f form)]

Performs a depth-first, post-order traversal of form. Calls f on
   each sub-form, uses f's return value in place of the original.
   Recognizes all Clojure data structures.

---

## postwalk-replace

[(smap form)]

Recursively transforms form by replacing keys in smap with their
   values. Like clojure/replace but works on any data structure.
   Does replacement at the leaves of the tree first.

---

## prewalk

[(f form)]

Like postwalk, but does pre-order traversal.

---

## prewalk-replace

[(smap form)]

Recursively transforms form by replacing keys in smap with their
   values. Like clojure/replace but works on any data structure.
   Does replacement at the root of the tree first.

---

## stringify-keys

[(m)]

Recursively transforms all map keys from keywords to strings.

---

## walk

[(inner outer form)]

Traverses form, an arbitrary data structure. inner and outer are
   functions. Applies inner to each element of form, building up a
   data structure of the same type, then applies outer to the result.
   Recognizes all Clojure data structures.
