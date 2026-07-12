# clojure.core


## Table of Contents

- [!=](#!=)
- [+](#+)
- [/](#/)
- [<](#<)
- [<=](#<=)
- [=](#=)
- [==](#==)
- [>](#>)
- [>=](#>=)
- [NaN?](#NaN?)
- [abs](#abs)
- [apply](#apply)
- [assoc](#assoc)
- [assoc-in](#assoc-in)
- [atom](#atom)
- [bigdec](#bigdec)
- [bigint](#bigint)
- [bit-and](#bit-and)
- [bit-and-not](#bit-and-not)
- [bit-clear](#bit-clear)
- [bit-flip](#bit-flip)
- [bit-not](#bit-not)
- [bit-or](#bit-or)
- [bit-set](#bit-set)
- [bit-shift-left](#bit-shift-left)
- [bit-shift-right](#bit-shift-right)
- [bit-test](#bit-test)
- [bit-xor](#bit-xor)
- [boolean](#boolean)
- [boolean?](#boolean?)
- [bounded-count](#bounded-count)
- [byte](#byte)
- [cat](#cat)
- [class](#class)
- [coll?](#coll?)
- [comp](#comp)
- [comparator](#comparator)
- [compare](#compare)
- [complement](#complement)
- [completing](#completing)
- [concat](#concat)
- [conj](#conj)
- [cons](#cons)
- [constantly](#constantly)
- [contains?](#contains?)
- [count](#count)
- [cycle](#cycle)
- [dec](#dec)
- [dedupe](#dedupe)
- [defonce](#defonce)
- [deliver](#deliver)
- [denom](#denom)
- [denominator](#denominator)
- [deref](#deref)
- [derive](#derive)
- [difference](#difference)
- [disj](#disj)
- [dissoc](#dissoc)
- [distinct](#distinct)
- [distinct?](#distinct?)
- [doall](#doall)
- [doseq](#doseq)
- [doto](#doto)
- [double](#double)
- [double?](#double?)
- [drop](#drop)
- [drop-last](#drop-last)
- [drop-while](#drop-while)
- [empty](#empty)
- [empty?](#empty?)
- [ensure-reduced](#ensure-reduced)
- [eval](#eval)
- [even?](#even?)
- [every-pred](#every-pred)
- [every?](#every?)
- [ex-cause](#ex-cause)
- [ex-data](#ex-data)
- [ex-info](#ex-info)
- [ex-message](#ex-message)
- [exception?](#exception?)
- [extenders](#extenders)
- [extends?](#extends?)
- [false?](#false?)
- [filter](#filter)
- [filterv](#filterv)
- [find](#find)
- [find-var](#find-var)
- [first](#first)
- [flatten](#flatten)
- [float](#float)
- [float?](#float?)
- [fn?](#fn?)
- [fnil](#fnil)
- [for](#for)
- [frequencies](#frequencies)
- [future](#future)
- [future-call](#future-call)
- [future-done?](#future-done?)
- [future?](#future?)
- [gensym](#gensym)
- [get](#get)
- [get-in](#get-in)
- [group-by](#group-by)
- [hash-map](#hash-map)
- [hash-set](#hash-set)
- [identical?](#identical?)
- [identity](#identity)
- [if-let](#if-let)
- [if-not](#if-not)
- [inc](#inc)
- [infinite?](#infinite?)
- [instance?](#instance?)
- [int](#int)
- [int?](#int?)
- [integer?](#integer?)
- [interleave](#interleave)
- [interpose](#interpose)
- [intersection](#intersection)
- [into](#into)
- [into-array](#into-array)
- [isa?](#isa?)
- [iterate](#iterate)
- [juxt](#juxt)
- [keep](#keep)
- [keep-indexed](#keep-indexed)
- [keepv](#keepv)
- [key](#key)
- [keys](#keys)
- [keyword](#keyword)
- [keyword?](#keyword?)
- [last](#last)
- [list](#list)
- [list?](#list?)
- [load-file](#load-file)
- [long](#long)
- [map](#map)
- [map-indexed](#map-indexed)
- [map?](#map?)
- [mapcat](#mapcat)
- [mapv](#mapv)
- [max](#max)
- [memoize](#memoize)
- [merge](#merge)
- [merge-with](#merge-with)
- [min](#min)
- [mod](#mod)
- [name](#name)
- [namespace](#namespace)
- [nano-time](#nano-time)
- [nat-int?](#nat-int?)
- [neg-int?](#neg-int?)
- [neg?](#neg?)
- [next](#next)
- [nil?](#nil?)
- [not](#not)
- [not-any?](#not-any?)
- [not-empty](#not-empty)
- [not=](#not=)
- [ns-name](#ns-name)
- [nth](#nth)
- [nthnext](#nthnext)
- [num](#num)
- [number?](#number?)
- [numerator](#numerator)
- [odd?](#odd?)
- [parents](#parents)
- [parse-boolean](#parse-boolean)
- [parse-double](#parse-double)
- [parse-long](#parse-long)
- [partial](#partial)
- [partition](#partition)
- [partition-all](#partition-all)
- [partition-by](#partition-by)
- [pcalls](#pcalls)
- [peek](#peek)
- [pmap](#pmap)
- [pop](#pop)
- [pos-int?](#pos-int?)
- [pos?](#pos?)
- [pr-str](#pr-str)
- [print](#print)
- [println](#println)
- [prn](#prn)
- [promise](#promise)
- [promise?](#promise?)
- [pvalues](#pvalues)
- [queue?](#queue?)
- [quot](#quot)
- [rand](#rand)
- [rand-int](#rand-int)
- [rand-nth](#rand-nth)
- [random-sample](#random-sample)
- [range](#range)
- [rational](#rational)
- [rationalize](#rationalize)
- [re-find](#re-find)
- [re-matches](#re-matches)
- [re-pattern](#re-pattern)
- [re-seq](#re-seq)
- [read-line](#read-line)
- [read-string](#read-string)
- [realized?](#realized?)
- [reduce](#reduce)
- [reduced](#reduced)
- [reduced?](#reduced?)
- [reducev](#reducev)
- [reductions](#reductions)
- [regex?](#regex?)
- [rem](#rem)
- [remove](#remove)
- [repeat](#repeat)
- [repeatedly](#repeatedly)
- [replace](#replace)
- [replicate](#replicate)
- [requiring-resolve](#requiring-resolve)
- [reset!](#reset!)
- [rest](#rest)
- [reverse](#reverse)
- [satisfies?](#satisfies?)
- [second](#second)
- [select-keys](#select-keys)
- [seq](#seq)
- [sequential?](#sequential?)
- [set](#set)
- [set?](#set?)
- [short](#short)
- [shuffle](#shuffle)
- [sleep](#sleep)
- [slurp](#slurp)
- [some](#some)
- [some-fn](#some-fn)
- [some?](#some?)
- [sort](#sort)
- [sort-by](#sort-by)
- [spit](#spit)
- [split-at](#split-at)
- [split-with](#split-with)
- [str](#str)
- [string?](#string?)
- [subs](#subs)
- [subset?](#subset?)
- [subvec](#subvec)
- [superset?](#superset?)
- [swap!](#swap!)
- [symbol](#symbol)
- [symbol?](#symbol?)
- [take](#take)
- [take-last](#take-last)
- [take-nth](#take-nth)
- [take-while](#take-while)
- [third](#third)
- [time](#time)
- [trampoline](#trampoline)
- [true?](#true?)
- [union](#union)
- [unreduced](#unreduced)
- [unsigned-bit-shift-right](#unsigned-bit-shift-right)
- [update](#update)
- [update-in](#update-in)
- [use](#use)
- [utf8-valid?](#utf8-valid?)
- [val](#val)
- [vals](#vals)
- [vary-meta](#vary-meta)
- [vec](#vec)
- [vector](#vector)
- [vector?](#vector?)
- [when-first](#when-first)
- [when-let](#when-let)
- [when-not](#when-not)
- [when-some](#when-some)
- [zero?](#zero?)
- [zipmap](#zipmap)

---

## !=

[(& args)]

Returns true if not all args are equal. Requires at least 2 args.

---

## +

[() (a) (a b) (a b & args)]

Returns the sum of nums. (+) returns 0.

---

## /

[(a) (a b) (a b & args)]

Divides nums. (/ x) returns the reciprocal. (/) throws.

---

## <

[(& args)]

Returns true if numerically ascending (strictly less than). Requires at least 2 args.

---

## <=

[(& args)]

Returns true if numerically ascending (less than or equal). Requires at least 2 args.

---

## =

[(& args)]

Returns true if all args are equal (value equality). Requires at least 2 args.

---

## ==

[(& args)]

Numeric equality (type-independent). Returns true if all args are
   numerically equal (e.g. (== 1 1.0) => true). For non-numeric args,
   falls back to value equality.

---

## >

[(& args)]

Returns true if numerically descending (strictly greater than). Requires at least 2 args.

---

## >=

[(& args)]

Returns true if numerically descending (greater than or equal). Requires at least 2 args.

---

## NaN?

[(x)]

Returns true if x is a not-a-number (NaN) value.

---

## abs

[(n)]

Returns the absolute value of a.

---

## apply

[(fn & args)]

Applies fn f to the argument list formed by prepending intervening arguments to args.

---

## assoc

[(& args)]

Associates key(s) with value(s) in a map, returning a new map.

---

## assoc-in

[(m ks v)]

Associates a value in a nested associative structure, where ks is a
   sequence of keys and v is the new value. If any levels do not exist,
   hash-maps will be created.

---

## atom

[(v)]

Creates and returns an Atom with an initial value and no validators or watchers.

---

## bigdec

[(x)]

Coerce to arbitrary-precision decimal.

---

## bigint

[(x)]

Coerce to arbitrary-precision integer. Truncates floats to integer part.

---

## bit-and

[(& args)]

Returns the bitwise AND of the args.

---

## bit-and-not

[(x y)]

Returns the bitwise AND NOT (clear bits in x that are set in y).

---

## bit-clear

[(x n)]

Clears the bit at position n in x (sets it to 0).

---

## bit-flip

[(x n)]

Flips the bit at position n in x (0 becomes 1, 1 becomes 0).

---

## bit-not

[(x)]

Returns the bitwise NOT of the arg.

---

## bit-or

[(& args)]

Returns the bitwise OR of the args.

---

## bit-set

[(x n)]

Sets the bit at position n in x (sets it to 1).

---

## bit-shift-left

[(x n)]

Shifts the bits of x to the left by n positions.

---

## bit-shift-right

[(x n)]

Shifts the bits of x to the right by n positions (arithmetic shift, preserves sign).

---

## bit-test

[(x n)]

Returns true if the bit at position n in x is set, false otherwise.

---

## bit-xor

[(& args)]

Returns the bitwise XOR of the args.

---

## boolean

[(x)]

Coerce to boolean.

---

## boolean?

[(x)]

Returns true if x is a boolean (true or false), false otherwise.

---

## bounded-count

[(n coll)]

Returns the count of coll if it is <= n, else returns n.

---

## byte

[(x)]

Coerce to byte (truncates to 8 bits).

---

## cat

[(& colls)]

Concatenate the contents of each collection into one sequence.

---

## class

[(x)]

Returns the class of x. In ClojureZ, returns the type keyword.

---

## coll?

[(x)]

Returns true if x is a collection (list, vector, map, set, or queue).

---

## comp

[(& fns)]

Returns a function that is the composition of the supplied functions.

---

## comparator

[(f)]

Returns a comparator (a function of two arguments) that imposes an ordering
   based on f. Returns a function of two arguments that returns -1, 0, or 1.

---

## compare

[(x y)]

Compare two values. Returns -1, 0, or 1 indicating less-than, equal-to,
   or greater-than. Supports numbers, strings, and collections.

---

## complement

[(f)]

Takes a fn f and returns a fn that takes the same arguments as f,
   has the same effects, if any, and returns the opposite truth value.

---

## completing

[(f completion)]

Takes a reducing function f (of 2 params) and a completion value,
   and returns a reducing function with the same arity that supplies
   completion for x when f is called with only 1 parameter.

---

## concat

[(& args)]

Returns a lazy sequence consisting of the items in each collection, in order.

---

## conj

[(& args)]

Conj[oin]. Returns a new collection with the items added.
   (conj item) returns a list with item.
   (conj coll item) adds item to coll.

---

## cons

[(x xs)]

Returns a list/seq with x as the first element and xs as the rest.
   Unlike (concat (list x) xs), this creates a proper cons cell that
   preserves lazy-seq semantics.

---

## constantly

[(x)]

Returns a function that takes any number of arguments and returns x.

---

## contains?

[(coll key)]

Returns true if key is present in the collection.

---

## count

[(coll)]

Returns the number of items in a collection. For strings, returns code point count.

---

## cycle

[(coll)]

Returns a lazy (infinite) sequence of the items in coll, repeated indefinitely.

---

## dec

[(n)]

Returns a number one less than num.

---

## dedupe

[(coll)]

Returns a lazy sequence removing consecutive duplicates in coll.

---

## defonce

[(name expr)]

Like def but only defines if the var has no value yet.

---

## deliver

[(p val)]

Delivers the supplied value to the promise. If the promise has already
   been delivered to, this has no effect. Returns the promise.

---

## denom

[(x)]

Returns the denominator of x, which must be an integer, bigint, or ratio.
   Alias for denominator.

---

## denominator

[(x)]

Returns the denominator of x, which must be an integer, bigint, or ratio.
   For integers/bigints, returns 1. For ratios, returns the denominator.

---

## deref

[(v)]

Returns the current value of the atom, future, promise, or var.
   For futures and promises, blocks until the computation completes.
   For atoms, returns the current value.

---

## derive

[(child parent)]

Derives a child type from a parent type in the type hierarchy.
   Both child and parent should be keywords or symbols.
   Used to define custom exception types and (future) multimethod dispatch.

---

## difference

[(s1 s2)]

Return a set that is the first set without elements of the remaining sets

---

## disj

[(& args)]

Returns a new set with the items removed.

---

## dissoc

[(& args)]

Returns a new map without the given keys.

---

## distinct

[(coll)]

Returns a lazy sequence of the distinct elements in coll.
   Preserves order of first occurrence.

---

## distinct?

[(coll)]

Returns true if no two elements in the collection are equal.

---

## doall

[(coll)]

Realizes all elements of a lazy sequence and returns it.

---

## doseq

[(seq-exprs & body)]

Repeatedly executes body for side-effects. Returns nil.

---

## doto

[(x & forms)]

Creates a form that will call each method/macro with the
   accumulator as the first argument.

---

## double

[(x)]

Coerce to double-precision floating point number.

---

## double?

[(x)]

Returns true if x is a double-precision floating point number.

---

## drop

[(n coll)]

Returns a lazy sequence of all but the first n items in coll.

---

## drop-last

[(coll) (n coll)]

Return a lazy sequence of all but the last n (default 1) items in coll.

---

## drop-while

[(pred coll)]

Returns a lazy sequence of the items in coll starting from the first item
   for which (pred item) returns logical false.

---

## empty

[(coll)]

Returns an empty collection of the same category as coll, or nil.

---

## empty?

[(coll)]

Returns true if coll has no items. Different from (not coll) because both
   nil and false return true for not. nil is considered empty.

---

## ensure-reduced

[(v)]

If v is a Reduced wrapper, returns it. Otherwise wraps v in Reduced.

---

## eval

[(form)]

Evaluates a single Clojure form (data structure) in the current environment.

---

## even?

[(n)]

Returns true if n is even, else false.

---

## every-pred

[(& preds)]

Takes a set of predicates and returns a function f that returns true if all of its
  composing predicates return a logical true value against all of its arguments.
  Note that f is short-circuiting in that it will stop execution on the first
  argument that triggers a logical false result against the original predicates.

---

## every?

[(pred coll)]

Returns true if (pred x) is logical true for every x in coll, else false.

---

## ex-cause

[(ex)]

Returns the cause of ex if ex is a Throwable.
   Otherwise returns nil.

---

## ex-data

[(ex)]

Returns exception data (a map) if ex is an IExceptionInfo.
   Otherwise returns nil.

---

## ex-info

[(msg data) (msg data cause)]

Create an instance of ExceptionInfo that carries a map of additional data.
   Optionally takes a cause exception as the third argument.

---

## ex-message

[(ex)]

Returns the message attached to ex if ex is a Throwable.
   Otherwise returns nil.

---

## exception?

[(x)]

Returns true if x is an exception value.

---

## extenders

[(protocol)]

Returns a set of types for which protocol has implementations.

---

## extends?

[(protocol atype)]

Returns true if protocol has an implementation for atype (a keyword like :string).

---

## false?

[(x)]

Returns true if x is the value false, false otherwise.

---

## filter

[(pred coll)]

Returns a lazy sequence of the items in coll for which (pred item) returns logical true.

---

## filterv

[(pred coll)]

Returns a vector of the items in coll for which (pred item) returns logical true.

---

## find

[(m key)]

Returns the map entry for key, or nil if the key is not in the map.
   The map entry is a map with :key and :val keys.

---

## find-var

[(sym)]

Finds and returns the var named by the symbol in the current namespace
   or its parents. Returns nil if not found.

---

## first

[(coll)]

Returns the first item of a collection, or nil if empty.

---

## flatten

[(x)]

Takes any nested combination of sequential things (lists, vectors, etc.)
   and returns the contents as a single, flat sequence.

---

## float

[(x)]

Coerce to floating point number. Returns the value for floats, converts integers.

---

## float?

[(x)]

Returns true if x is a floating point number (float or double).

---

## fn?

[(x)]

Returns true if x is a function.

---

## fnil

[(f & defaults)]

Returns a function that calls f with nil replaced by the supplied defaults.

---

## for

[(seq-exprs body-expr)]

List comprehension. Supports :when and :while modifiers.

---

## frequencies

[(coll)]

Returns a map from distinct items in coll to the number of times
  they appear.

---

## future

[(& body)]

Takes a body of expressions and yields a future object that will
   invoke the body in another thread, and will cache the result and
   return it on all subsequent calls to deref/@.

---

## future-call

[(f)]

Takes a function of no args and yields a future object that will
   invoke the function in another thread, and will cache the result and
   return it on all subsequent calls to deref/@. If the computation has
   not yet finished, calls to deref/@ will block.

---

## future-done?

[(f)]

Returns true if future f is done.

---

## future?

[(x)]

Returns true if x is a future.

---

## gensym

[() (prefix)]

Makes a new symbol with a unique name. If prefix is supplied, the name
   starts with prefix, otherwise it starts with 'G'.

---

## get

[(& args)]

Returns the value mapped to key, not-found (nil) if not present.

---

## get-in

[(m ks)]

Returns the value in a nested associative structure,
   where ks is a sequence of keys. Returns nil if the key is not present.

---

## group-by

[(f coll)]

Returns a map of key -> (list of items) grouped by the result of f.

---

## hash-map

[(& args)]

Returns a map with the given key-value pairs.

---

## hash-set

[(& args)]

Returns a set containing the given args.

---

## identical?

[(x y)]

Returns true if x and y are the same object (by identity/reference),
   not merely equal in value.

---

## identity

[(x)]

Returns its argument.

---

## if-let

[(bindings then else)]

bindings => binding-form test

  If test is true, evaluates then with binding-form bound to the value of
  test, if not, yields else.

---

## if-not

[(test then) (test then not-then)]

If test is logical false, evaluates then, else evaluates not-then (or nil if not-then omitted).

---

## inc

[(n)]

Returns a number one greater than num.

---

## infinite?

[(x)]

Returns true if x is positive or negative infinity.

---

## instance?

[(t x)]

Returns true if x is an instance of the given type.
   In ClojureZ, type should be a keyword like :integer, :string, etc.

---

## int

[(x)]

Coerce to 64-bit integer. Truncates floats, returns the value for integers.

---

## int?

[(x)]

Returns true if x is a 64-bit integer.

---

## integer?

[(x)]

Returns true if x is an integer (64-bit int or BigInt).

---

## interleave

[() (c1) (c1 c2)]

Returns a lazy seq of the first item in each coll, then the second etc.

---

## interpose

[(sep coll)]

Returns a lazy seq of the elements of coll separated by sep.

---

## intersection

[(s1 s2)]

Return a set that is the intersection of the input sets

---

## into

[(to from)]

Returns a new coll consisting of to with all of the items of from conjoined.

---

## into-array

[(coll)]

Returns the collection as a vector.

---

## isa?

[(child parent)]

Returns true if child is parent or derives from parent in the hierarchy.

---

## iterate

[(f x)]

Returns a lazy (infinite) sequence of x, (f x), (f (f x)) etc.

---

## juxt

[(& fns)]

Returns a function that calls each of the supplied functions and returns
   a vector of the results.

---

## keep

[(f coll)]

Returns a lazy sequence of the non-nil results of (f item).

---

## keep-indexed

[(f coll)]

Returns a lazy sequence of the non-nil results of (f i x).

---

## keepv

[(f coll)]

Returns a vector of the non-nil results of (f applied to) the items in coll.

---

## key

[(e)]

Returns the key of the map entry.

---

## keys

[(m)]

Returns a sequence of the keys in the map.

---

## keyword

[(name) (namespace name)]

Converts a string or symbol to a keyword. With two args, creates a namespaced keyword.

---

## keyword?

[(x)]

Returns true if x is a keyword.

---

## last

[(coll)]

Returns the last item in a collection.

---

## list

[(& args)]

Returns a list of the args.

---

## list?

[(x)]

Returns true if x is a list.

---

## load-file

[(filename)]

Loads and evaluates all forms in a file. Returns the value of the last form.

---

## long

[(x)]

Coerces x to a long (i64). Same as int in ClojureZ.

---

## map

[(f coll)]

Returns a lazy sequence consisting of the result of applying f to the
   set of first items of each collection, followed by applying f to the set
   of second items in each sequence, and so on.

---

## map-indexed

[(f coll)]

Returns a lazy sequence of ([i (f i x1)] for each item x1 and index i).

---

## map?

[(x)]

Returns true if x is a map.

---

## mapcat

[(f coll)]

Returns a lazy sequence which is the concatenation of the results of applying f to the
   elements of the collections. f should return a collection.

---

## mapv

[(f coll)]

Returns a vector of (f applied to) the items in coll.

---

## max

[(x) (x y) (x y & more)]

Returns the greatest of the nums.

---

## memoize

[(f)]

Returns a memoized version of a referentially transparent function.
  The memoized version keeps a cache of the mapping of arguments to results.

---

## merge

[(& args)]

Merges multiple maps into one. Later maps override earlier ones for duplicate keys.

---

## merge-with

[(f & maps)]

Returns a map that consists of the rest of the maps merged into the first.
   If the keys overlap, it merges the values according to f.

---

## min

[(x) (x y) (x y & more)]

Returns the least of the nums.

---

## mod

[(num den)]

Returns modulus of numerator and denominator.
   Sign follows the divisor.

---

## name

[(x)]

Returns the name String of a string, symbol, or keyword.
   For symbols and keywords, returns the local name without namespace prefix.

---

## namespace

[(s)]

Returns the namespace string for the symbol, or nil if it has none.

---

## nano-time

[()]

Returns current instant's nanosecond time (monotonic clock).
   Useful for measuring elapsed time.

---

## nat-int?

[(n)]

Return true if x is a non-negative fixed precision integer.

---

## neg-int?

[(n)]

Return true if x is a negative fixed precision integer.

---

## neg?

[(n)]

Returns true if num is less than zero, else false.

---

## next

[(coll)]

Returns the rest of the collection after the first element, or nil if empty.

---

## nil?

[(x)]

Returns true if x is nil.

---

## not

[(x)]

Returns true if x is logical false, true otherwise.

---

## not-any?

[(f coll)]

Returns true if (some f coll) is logical false.

---

## not-empty

[(coll)]

Returns the first item of coll if it is not empty, nil otherwise.

---

## not=

[(& args)]

Returns true if not all args are equal. Alias for !=. Requires at least 2 args.

---

## ns-name

[(ns)]

Returns the name of a namespace as a symbol.

---

## nth

[(coll index) (coll index not-found)]

Returns the item at index. Returns nil if index is out of bounds.

---

## nthnext

[(coll n)]

Returns the nth next of coll. (nthnext coll 1) is equivalent to (next coll).

---

## num

[(x)]

Returns the numerator of x, which must be an integer, bigint, or ratio.
   Alias for numerator.

---

## number?

[(x)]

Returns true if x is a number (integer, float, bigint, ratio, or decimal).

---

## numerator

[(x)]

Returns the numerator of x, which must be an integer, bigint, or ratio.
   For integers/bigints, returns the value itself. For ratios, returns the numerator.

---

## odd?

[(n)]

Returns true if n is odd, else false.

---

## parents

[(child)]

Returns the set of direct parents of child in the hierarchy.

---

## parse-boolean

[(s)]

Parse strings "true" or "false" and return a boolean, or nil if invalid.
   Throws IllegalArgumentException if input is not a string.

---

## parse-double

[(s)]

Parse string with floating point components and return a Double value,
   or nil if parse fails.
   Throws IllegalArgumentException if input is not a string.

---

## parse-long

[(s)]

Parse string of decimal digits with optional leading -/+ and return a
   Long value, or nil if parse fails.
   Throws IllegalArgumentException if input is not a string.

---

## partial

[(f & args)]

Returns a function that is a partial application of f with the supplied args.

---

## partition

[(n coll)]

Returns a lazy sequence of lists of n elements each, at intervals
   of step. Returns nil if there are fewer than n elements remaining.

---

## partition-all

[(n coll)]

Returns a lazy sequence of lists like partition, but may include
   partitions with fewer than n items at the end.

---

## partition-by

[(f coll)]

Applies f to each value in coll, splitting it each time f returns a
   new value. Returns a lazy seq of partitions.

---

## pcalls

[(& fns)]

Executes the no-arg fns in parallel, returning a lazy sequence of
   their values.

---

## peek

[(coll)]

Returns the last item of a collection without removing it.
   For vectors, returns the last element. For lists/queues, returns the first.

---

## pmap

[(f coll) (f coll & colls)]

Like map, except f is applied in parallel. Semi-lazy in that the
   parallel computation stays ahead of the consumption, but doesn't
   realize the entire result unless required.

---

## pop

[(coll)]

Returns a new collection with the last item removed.
   For vectors, removes the last element. For lists, removes the first.

---

## pos-int?

[(n)]

Return true if x is a positive fixed precision integer.

---

## pos?

[(n)]

Returns true if num is greater than zero, else false.

---

## pr-str

[(x)]

Returns the printed representation of x as a string.

---

## print

[(& args)]

Prints the string representation of the args to stdout.

---

## println

[(& args)]

Prints the string representation of the args to stdout, followed by a newline.

---

## prn

[(& args)]

Prints the object(s), with whitespace, using pr-str. Returns nil.

---

## promise

[()]

Returns a promise object that can be delivered to at most once.

---

## promise?

[(x)]

Returns true if x is a promise.

---

## pvalues

[(& exprs)]

Returns a lazy sequence of the values of the exprs, which are
   evaluated in parallel.

---

## queue?

[(x)]

Returns true if x is a queue.

---

## quot

[(num den)]

Integer division. Truncates toward zero.

---

## rand

[() (n)]

Returns a random floating point number between 0 (inclusive) and 1.0 (exclusive).
   With an argument n, returns a random float between 0 and n.

---

## rand-int

[(n)]

Returns a random integer between 0 (inclusive) and n (exclusive).

---

## rand-nth

[(coll)]

Return a random element of the (sequential) collection. O(1) when possible.

---

## random-sample

[(prob coll)]

Returns items from coll with random probability of prob (0.0 - 1.0).

---

## range

[(end) (start end) (start end step)]

Returns a lazy sequence of integers from start (inclusive) to end (exclusive),
   with optional step. (range end) starts from 0. (range start end) uses step 1.

---

## rational

[(x)]

Returns the rational number equivalent of x.
   For integers, returns the integer. For floats, returns a ratio.
   For ratios, returns the ratio. Alias for rationalize.

---

## rationalize

[(x)]

Returns the simplest ratio that is within 0.5 of mag.
   For integers, returns the integer. For floats, returns a ratio.
   For ratios, returns the ratio.

---

## re-find

[(re s)]

Returns the first match, if any, of string to pattern.
   Returns the matched string or nil.

---

## re-matches

[(re s)]

Returns the match, if any, of string to pattern using full string matching.
   Returns the matched string or nil.

---

## re-pattern

[(s)]

Returns a regex pattern from a string. If s is already a regex, returns it.

---

## re-seq

[(re s)]

Returns a vector of successive matches of pattern in string.

---

## read-line

[()]

Reads a line from stdin (or the input stream). Returns nil on EOF.

---

## read-string

[(s)]

Reads one Clojure form from a string. Returns the parsed data structure.

---

## realized?

[(x)]

Returns true if a value has been produced for a promise, future or lazy sequence.

---

## reduce

[(f coll) (f val coll)]

f should be a function of 2 arguments. If val is not supplied, returns the
   result of applying f to the first 2 items in coll, then applying f to that
   result and the 3rd item, etc. If val is supplied, returns the result of
   applying f to val and the first item in coll, then applying f to that
   result and the 2nd item, etc.

---

## reduced

[(v)]

Wrap a value in Reduced to signal early termination of a reduction.

---

## reduced?

[(v)]

Returns true if v is a Reduced wrapper.

---

## reducev

[(f init coll)]

f should be a function of 2 arguments. Returns the result of applying f
   to init and the first item in coll, then applying f to that result and
   the second item in coll, and so on. If coll is empty, returns init.

---

## reductions

[(f coll) (f init coll)]

Returns a lazy sequence of the intermediate values of a reduction.
   With init, starts from init. Without init, starts from first element.

---

## regex?

[(x)]

Returns true if x is a regex pattern.

---

## rem

[(num den)]

Returns remainder of dividing numerator by denominator.
   Sign follows the dividend.

---

## remove

[(pred coll)]

Returns a lazy sequence of the items in coll for which (pred item) returns logical false.

---

## repeat

[(x) (n x)]

Returns a lazy (infinite) sequence of x. Also accepts count: (repeat n x).

---

## repeatedly

[(f) (n f)]

Takes a function of no args, presumably with side effects, and
  returns an infinite (or length n if supplied) lazy sequence of calls
  to it.

---

## replace

[(smap coll)]

Returns a lazy sequence with elements replaced using the given map.

---

## replicate

[(n x)]

Returns a lazy sequence of n copies of x. Same as (repeat n x).

---

## requiring-resolve

[(sym)]

Resolves a qualified symbol. If not found, requires its namespace and retries.

---

## reset!

[(a new-val)]

Reset the atom's value to new-val and return it.

---

## rest

[(coll)]

Returns a possibly-empty sequence of the items after the first.

---

## reverse

[(coll)]

Returns a seq of the items in coll in reverse order.

---

## satisfies?

[(protocol x)]

Returns true if x satisfies protocol (i.e. has an implementation for it).

---

## second

[(xs)]

Same as (first (rest x)).

---

## select-keys

[(map keyseq)]

Returns a map containing only those entries in map whose key is in keys

---

## seq

[(coll)]

Returns a sequence of the collection. Returns nil if the collection is empty.

---

## sequential?

[(x)]

Returns true if x is a sequential collection (list or vector).

---

## set

[(coll)]

Returns a set of the items in coll.

---

## set?

[(x)]

Returns true if x is a set.

---

## short

[(x)]

Coerce to short (truncates to 16 bits).

---

## shuffle

[(coll)]

Return a random permutation of coll. Uses Fisher-Yates shuffle.

---

## sleep

[(ms)]

Causes the current thread to sleep for the given number of milliseconds.

---

## slurp

[(filename)]

Opens and reads the file from the given path, returning its contents as a string.

---

## some

[(pred coll)]

Returns the first logical true value of (pred x) for any x in coll, else nil.

---

## some-fn

[(& preds)]

Takes a set of predicates and returns a function f that returns the first logical true value
  returned by one of its composing predicates against any of its arguments,
  else it returns logical false. Note that f is short-circuiting in that it will
  stop execution on the first argument that triggers a logical true result against
  the original predicates.

---

## some?

[(x)]

Returns true if x is not nil, false otherwise.

---

## sort

[(coll) (comparator coll)]

Returns a sorted sequence of the items in coll. If no comparator is
   supplied, uses compare. comparator must return a negative number if
   x < y, zero if x == y, and a positive number if x > y.
   coll must support count and nth.

---

## sort-by

[(keyfn coll)]

Returns a sorted sequence of the items in coll, sorted by the comparison
   of (keyfn item). coll must support count and nth.

---

## spit

[(filename content & options)]

Writes the string content to a file, creating it if it doesn't exist.
  Optional :append true writes in append mode instead of overwriting.

---

## split-at

[(n coll)]

Returns a vector of [(take n coll) (drop n coll)].

---

## split-with

[(pred coll)]

Returns a vector of [(take-while pred coll) (drop-while pred coll)].

---

## str

[(& args)]

With no args, returns the empty string. With one arg, returns
   (.toString arg). With more args, returns the concatenation of
   the .toString of each.

---

## string?

[(x)]

Returns true if x is a string.

---

## subs

[(s start) (s start end)]

Returns the substring of s beginning at start inclusive, and ending
   at end (defaults to length of string), exclusive.

---

## subset?

[(set1 set2)]

Is set1 a subset of set2?

---

## subvec

[(v start) (v start end)]

Returns a persistent vector of the items in vector from
   start (inclusive) to end (exclusive). If end is not supplied,
   defaults to (count vector).

---

## superset?

[(set1 set2)]

Is set1 a superset of set2?

---

## swap!

[(& args)]

Atomically swaps the value of the atom to be: (apply f current-value & args).

---

## symbol

[(name) (namespace name)]

Creates a symbol from a string. With two args, creates a namespaced symbol.

---

## symbol?

[(x)]

Returns true if x is a symbol.

---

## take

[(n coll)]

Returns a lazy sequence of the first n items in coll.

---

## take-last

[(n coll)]

Returns a seq of the last n items in coll.

---

## take-nth

[(n coll)]

Returns a lazy seq of every nth item in coll.

---

## take-while

[(pred coll)]

Returns a lazy sequence of successive items from coll for which (pred item) returns logical true.

---

## third

[(xs)]

Same as (first (rest (rest x))).

---

## time

[(expr)]

Evaluates expr and prints the time it took. Returns the value of expr.

---

## trampoline

[(f & args)]

Calls f with the supplied args. If f returns a fn, calls that fn,
   repeating until a non-fn result is returned.

---

## true?

[(x)]

Returns true if x is the value true, false otherwise.

---

## union

[(s1 s2)]

Return a set that is the union of the input sets

---

## unreduced

[(v)]

If v is a Reduced wrapper, unwraps and returns the inner value. Otherwise returns v.

---

## unsigned-bit-shift-right

[(x n)]

Shifts the bits of x to the right by n positions (logical shift, fills with zeros).

---

## update

[(m k f) (m k f & args)]

Returns a map with the value at key updated by applying f to the current value.
   With extra args, applies (apply f (get m k) args).

---

## update-in

[(m ks f & args)]

Returns a new map with the values at the given key-path updated.
   fn is called with the current value at key-path and any additional args.

---

## use

[(& args)]

Like require but also refers all public vars into current namespace.

---

## utf8-valid?

[(s)]

Returns true if the string is valid UTF-8.

---

## val

[(e)]

Returns the value of the map entry.

---

## vals

[(m)]

Returns a sequence of the values in the map.

---

## vary-meta

[(obj f & args)]

Returns an object of the same type and value as obj, with
   (apply f (meta obj) args) as its metadata.

---

## vec

[(& args)]

Returns a vector of the args, or converts a collection to a vector.

---

## vector

[(& args)]

Creates a new vector containing the args.

---

## vector?

[(x)]

Returns true if x is a vector.

---

## when-first

[(bindings & body)]

bindings => x xs

  Roughly the same as (when (seq xs) (let [x (first xs)] body)) but xs is evaluated only once.

---

## when-let

[(bindings & body)]

bindings => binding-form test

  When test is true, evaluates body with binding-form bound to the value of test.

---

## when-not

[(test & body)]

Evaluates test. If logical false, evaluates body in an implicit do.

---

## when-some

[(bindings & body)]

bindings => binding-form test

   When test is not nil, evaluates body with binding-form bound to the
   value of test.

---

## zero?

[(n)]

Returns true if num is zero, else false.

---

## zipmap

[(keys vals)]

Returns a map with the keys mapped to the corresponding vals.
