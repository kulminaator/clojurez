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
- [difference](#difference)
- [disj](#disj)
- [dissoc](#dissoc)
- [distinct](#distinct)
- [distinct?](#distinct?)
- [doall](#doall)
- [doseq](#doseq)
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
- [extenders](#extenders)
- [extends?](#extends?)
- [false?](#false?)
- [filter](#filter)
- [filterv](#filterv)
- [find](#find)
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
- [int](#int)
- [int?](#int?)
- [integer?](#integer?)
- [interleave](#interleave)
- [interpose](#interpose)
- [intersection](#intersection)
- [into](#into)
- [into-array](#into-array)
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
- [map](#map)
- [map-indexed](#map-indexed)
- [map?](#map?)
- [mapcat](#mapcat)
- [mapv](#mapv)
- [max](#max)
- [memoize](#memoize)
- [merge](#merge)
- [min](#min)
- [mod](#mod)
- [name](#name)
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
- [partial](#partial)
- [partition](#partition)
- [partition-all](#partition-all)
- [partition-by](#partition-by)
- [peek](#peek)
- [pop](#pop)
- [pos-int?](#pos-int?)
- [pos?](#pos?)
- [pr-str](#pr-str)
- [print](#print)
- [println](#println)
- [promise](#promise)
- [promise?](#promise?)
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
- [use](#use)
- [utf8-valid?](#utf8-valid?)
- [val](#val)
- [vals](#vals)
- [vec](#vec)
- [vector?](#vector?)
- [when-first](#when-first)
- [when-let](#when-let)
- [when-not](#when-not)
- [when-some](#when-some)
- [zero?](#zero?)
- [zipmap](#zipmap)

---

## !=

Returns true if not all args are equal. Requires at least 2 args.

---

## +

Returns the sum of nums. (+) returns 0.

---

## /

Divides nums. (/ x) returns the reciprocal. (/) throws.

---

## <

Returns true if numerically ascending (strictly less than). Requires at least 2 args.

---

## <=

Returns true if numerically ascending (less than or equal). Requires at least 2 args.

---

## =

Returns true if all args are equal (value equality). Requires at least 2 args.

---

## ==

Numeric equality (type-independent). Returns true if all args are
   numerically equal (e.g. (== 1 1.0) => true). For non-numeric args,
   falls back to value equality.

---

## >

Returns true if numerically descending (strictly greater than). Requires at least 2 args.

---

## >=

Returns true if numerically descending (greater than or equal). Requires at least 2 args.

---

## NaN?

Returns true if x is a not-a-number (NaN) value.

---

## abs

Returns the absolute value of a.

---

## apply

Applies fn f to the argument list formed by prepending intervening arguments to args.

---

## assoc

Associates key(s) with value(s) in a map, returning a new map.

---

## assoc-in

Associates a value in a nested associative structure, where ks is a
   sequence of keys and v is the new value. If any levels do not exist,
   hash-maps will be created.

---

## atom

Creates and returns an Atom with an initial value and no validators or watchers.

---

## bigdec

Coerce to arbitrary-precision decimal.

---

## bigint

Coerce to arbitrary-precision integer. Truncates floats to integer part.

---

## bit-and

Returns the bitwise AND of the args.

---

## bit-and-not

Returns the bitwise AND NOT (clear bits in x that are set in y).

---

## bit-clear

Clears the bit at position n in x (sets it to 0).

---

## bit-flip

Flips the bit at position n in x (0 becomes 1, 1 becomes 0).

---

## bit-not

Returns the bitwise NOT of the arg.

---

## bit-or

Returns the bitwise OR of the args.

---

## bit-set

Sets the bit at position n in x (sets it to 1).

---

## bit-shift-left

Shifts the bits of x to the left by n positions.

---

## bit-shift-right

Shifts the bits of x to the right by n positions (arithmetic shift, preserves sign).

---

## bit-test

Returns true if the bit at position n in x is set, false otherwise.

---

## bit-xor

Returns the bitwise XOR of the args.

---

## boolean

Coerce to boolean.

---

## boolean?

Returns true if x is a boolean (true or false), false otherwise.

---

## bounded-count

Returns the count of coll if it is <= n, else returns n.

---

## byte

Coerce to byte (truncates to 8 bits).

---

## cat

Concatenate the contents of each collection into one sequence.

---

## coll?

Returns true if x is a collection (list, vector, map, set, or queue).

---

## comp

Returns a function that is the composition of the supplied functions.

---

## comparator

Returns a comparator (a function of two arguments) that imposes an ordering
   based on f. Returns a function of two arguments that returns -1, 0, or 1.

---

## compare

Compare two values. Returns -1, 0, or 1 indicating less-than, equal-to,
   or greater-than. Supports numbers, strings, and collections.

---

## complement

Takes a fn f and returns a fn that takes the same arguments as f,
   has the same effects, if any, and returns the opposite truth value.

---

## completing

Takes a reducing function f (of 2 params) and a completion value,
   and returns a reducing function with the same arity that supplies
   completion for x when f is called with only 1 parameter.

---

## concat

Returns a lazy sequence consisting of the items in each collection, in order.

---

## conj

Conj[oin]. Returns a new collection with the items added.
   (conj item) returns a list with item.
   (conj coll item) adds item to coll.

---

## cons

Returns a list/seq with x as the first element and xs as the rest.
   Unlike (concat (list x) xs), this creates a proper cons cell that
   preserves lazy-seq semantics.

---

## constantly

Returns a function that takes any number of arguments and returns x.

---

## contains?

Returns true if key is present in the collection.

---

## count

Returns the number of items in a collection. For strings, returns code point count.

---

## cycle

Returns a lazy (infinite) sequence of the items in coll, repeated indefinitely.

---

## dec

Returns a number one less than num.

---

## dedupe

Returns a lazy sequence removing consecutive duplicates in coll.

---

## defonce

Like def but only defines if the var has no value yet.

---

## deliver

Delivers the supplied value to the promise. If the promise has already
   been delivered to, this has no effect. Returns the promise.

---

## denom

Returns the denominator of x, which must be an integer, bigint, or ratio.
   Alias for denominator.

---

## denominator

Returns the denominator of x, which must be an integer, bigint, or ratio.
   For integers/bigints, returns 1. For ratios, returns the denominator.

---

## deref

Returns the current value of the atom, future, promise, or var.
   For futures and promises, blocks until the computation completes.
   For atoms, returns the current value.

---

## difference

Return a set that is the first set without elements of the remaining sets

---

## disj

Returns a new set with the items removed.

---

## dissoc

Returns a new map without the given keys.

---

## distinct

Returns a lazy sequence of the distinct elements in coll.
   Preserves order of first occurrence.

---

## distinct?

Returns true if no two elements in the collection are equal.

---

## doall

Realizes all elements of a lazy sequence and returns it.

---

## doseq

Repeatedly executes body for side-effects. Returns nil.

---

## double

Coerce to double-precision floating point number.

---

## double?

Returns true if x is a double-precision floating point number.

---

## drop

Returns a lazy sequence of all but the first n items in coll.

---

## drop-last

Return a lazy sequence of all but the last n (default 1) items in coll.

---

## drop-while

Returns a lazy sequence of the items in coll starting from the first item
   for which (pred item) returns logical false.

---

## empty

Returns an empty collection of the same category as coll, or nil.

---

## empty?

Returns true if coll has no items. Different from (not coll) because both
   nil and false return true for not. nil is considered empty.

---

## ensure-reduced

If v is a Reduced wrapper, returns it. Otherwise wraps v in Reduced.

---

## eval

Evaluates a single Clojure form (data structure) in the current environment.

---

## even?

Returns true if n is even, else false.

---

## every-pred

Takes a set of predicates and returns a function f that returns true if all of its
  composing predicates return a logical true value against all of its arguments.
  Note that f is short-circuiting in that it will stop execution on the first
  argument that triggers a logical false result against the original predicates.

---

## every?

Returns true if (pred x) is logical true for every x in coll, else false.

---

## extenders

Returns a set of types for which protocol has implementations.

---

## extends?

Returns true if protocol has an implementation for atype (a keyword like :string).

---

## false?

Returns true if x is the value false, false otherwise.

---

## filter

Returns a lazy sequence of the items in coll for which (pred item) returns logical true.

---

## filterv

Returns a vector of the items in coll for which (pred item) returns logical true.

---

## find

Returns the map entry for key, or nil if the key is not in the map.
   The map entry is a map with :key and :val keys.

---

## first

Returns the first item of a collection, or nil if empty.

---

## flatten

Takes any nested combination of sequential things (lists, vectors, etc.)
   and returns the contents as a single, flat sequence.

---

## float

Coerce to floating point number. Returns the value for floats, converts integers.

---

## float?

Returns true if x is a floating point number (float or double).

---

## fn?

Returns true if x is a function.

---

## fnil

Returns a function that calls f with nil replaced by the supplied defaults.

---

## for

List comprehension. Supports :when and :while modifiers.

---

## frequencies

Returns a map from distinct items in coll to the number of times
  they appear.

---

## future

Takes a body of expressions and yields a future object that will
   invoke the body in another thread, and will cache the result and
   return it on all subsequent calls to deref/@.

---

## future-call

Takes a function of no args and yields a future object that will
   invoke the function in another thread, and will cache the result and
   return it on all subsequent calls to deref/@. If the computation has
   not yet finished, calls to deref/@ will block.

---

## future-done?

Returns true if future f is done.

---

## future?

Returns true if x is a future.

---

## gensym

Makes a new symbol with a unique name. If prefix is supplied, the name
   starts with prefix, otherwise it starts with 'G'.

---

## get

Returns the value mapped to key, not-found (nil) if not present.

---

## get-in

Returns the value in a nested associative structure,
   where ks is a sequence of keys. Returns nil if the key is not present.

---

## group-by

Returns a map of key -> (list of items) grouped by the result of f.

---

## hash-map

Returns a map with the given key-value pairs.

---

## hash-set

Returns a set containing the given args.

---

## identical?

Returns true if x and y are the same object (by identity/reference),
   not merely equal in value.

---

## identity

Returns its argument.

---

## if-let

bindings => binding-form test

  If test is true, evaluates then with binding-form bound to the value of
  test, if not, yields else.

---

## if-not

If test is logical false, evaluates then, else evaluates not-then (or nil if not-then omitted).

---

## inc

Returns a number one greater than num.

---

## infinite?

Returns true if x is positive or negative infinity.

---

## int

Coerce to 64-bit integer. Truncates floats, returns the value for integers.

---

## int?

Returns true if x is a 64-bit integer.

---

## integer?

Returns true if x is an integer (64-bit int or BigInt).

---

## interleave

Returns a lazy seq of the first item in each coll, then the second etc.

---

## interpose

Returns a lazy seq of the elements of coll separated by sep.

---

## intersection

Return a set that is the intersection of the input sets

---

## into

Returns a new coll consisting of to with all of the items of from conjoined.

---

## into-array

Returns the collection as a vector.

---

## iterate

Returns a lazy (infinite) sequence of x, (f x), (f (f x)) etc.

---

## juxt

Returns a function that calls each of the supplied functions and returns
   a vector of the results.

---

## keep

Returns a lazy sequence of the non-nil results of (f item).

---

## keep-indexed

Returns a lazy sequence of the non-nil results of (f i x).

---

## keepv

Returns a vector of the non-nil results of (f applied to) the items in coll.

---

## key

Returns the key of the map entry.

---

## keys

Returns a sequence of the keys in the map.

---

## keyword

Converts a string or symbol to a keyword. With two args, creates a namespaced keyword.

---

## keyword?

Returns true if x is a keyword.

---

## last

Returns the last item in a collection.

---

## list

Returns a list of the args.

---

## list?

Returns true if x is a list.

---

## load-file

Loads and evaluates all forms in a file. Returns the value of the last form.

---

## map

Returns a lazy sequence consisting of the result of applying f to the
   set of first items of each collection, followed by applying f to the set
   of second items in each sequence, and so on.

---

## map-indexed

Returns a lazy sequence of ([i (f i x1)] for each item x1 and index i).

---

## map?

Returns true if x is a map.

---

## mapcat

Returns a lazy sequence which is the concatenation of the results of applying f to the
   elements of the collections. f should return a collection.

---

## mapv

Returns a vector of (f applied to) the items in coll.

---

## max

Returns the greatest of the nums.

---

## memoize

Returns a memoized version of a referentially transparent function.
  The memoized version keeps a cache of the mapping of arguments to results.

---

## merge

Merges multiple maps into one. Later maps override earlier ones for duplicate keys.

---

## min

Returns the least of the nums.

---

## mod

Returns modulus of numerator and denominator.
   Sign follows the divisor.

---

## name

Returns the name String of a string or symbol.
   For symbols, returns the local name without namespace prefix.

---

## nano-time

Returns current instant's nanosecond time (monotonic clock).
   Useful for measuring elapsed time.

---

## nat-int?

Return true if x is a non-negative fixed precision integer.

---

## neg-int?

Return true if x is a negative fixed precision integer.

---

## neg?

Returns true if num is less than zero, else false.

---

## next

Returns the rest of the collection after the first element, or nil if empty.

---

## nil?

Returns true if x is nil.

---

## not

Returns true if x is logical false, true otherwise.

---

## not-any?

Returns true if (some f coll) is logical false.

---

## not-empty

Returns the first item of coll if it is not empty, nil otherwise.

---

## not=

Returns true if not all args are equal. Alias for !=. Requires at least 2 args.

---

## ns-name

Returns the name of a namespace as a symbol.

---

## nth

Returns the item at index. Returns nil if index is out of bounds.

---

## nthnext

Returns the nth next of coll. (nthnext coll 1) is equivalent to (next coll).

---

## num

Returns the numerator of x, which must be an integer, bigint, or ratio.
   Alias for numerator.

---

## number?

Returns true if x is a number (integer, float, bigint, ratio, or decimal).

---

## numerator

Returns the numerator of x, which must be an integer, bigint, or ratio.
   For integers/bigints, returns the value itself. For ratios, returns the numerator.

---

## odd?

Returns true if n is odd, else false.

---

## partial

Returns a function that is a partial application of f with the supplied args.

---

## partition

Returns a lazy sequence of lists of n elements each, at intervals
   of step. Returns nil if there are fewer than n elements remaining.

---

## partition-all

Returns a lazy sequence of lists like partition, but may include
   partitions with fewer than n items at the end.

---

## partition-by

Applies f to each value in coll, splitting it each time f returns a
   new value. Returns a lazy seq of partitions.

---

## peek

Returns the last item of a collection without removing it.
   For vectors, returns the last element. For lists/queues, returns the first.

---

## pop

Returns a new collection with the last item removed.
   For vectors, removes the last element. For lists, removes the first.

---

## pos-int?

Return true if x is a positive fixed precision integer.

---

## pos?

Returns true if num is greater than zero, else false.

---

## pr-str

Returns the printed representation of x as a string.

---

## print

Prints the string representation of the args to stdout.

---

## println

Prints the string representation of the args to stdout, followed by a newline.

---

## promise

Returns a promise object that can be delivered to at most once.

---

## promise?

Returns true if x is a promise.

---

## queue?

Returns true if x is a queue.

---

## quot

Integer division. Truncates toward zero.

---

## rand

Returns a random floating point number between 0 (inclusive) and 1.0 (exclusive).
   With an argument n, returns a random float between 0 and n.

---

## rand-int

Returns a random integer between 0 (inclusive) and n (exclusive).

---

## rand-nth

Return a random element of the (sequential) collection. O(1) when possible.

---

## random-sample

Returns items from coll with random probability of prob (0.0 - 1.0).

---

## range

Returns a lazy sequence of integers from start (inclusive) to end (exclusive),
   with optional step. (range end) starts from 0. (range start end) uses step 1.

---

## rational

Returns the rational number equivalent of x.
   For integers, returns the integer. For floats, returns a ratio.
   For ratios, returns the ratio. Alias for rationalize.

---

## rationalize

Returns the simplest ratio that is within 0.5 of mag.
   For integers, returns the integer. For floats, returns a ratio.
   For ratios, returns the ratio.

---

## re-find

Returns the first match, if any, of string to pattern.
   Returns the matched string or nil.

---

## re-matches

Returns the match, if any, of string to pattern using full string matching.
   Returns the matched string or nil.

---

## re-pattern

Returns a regex pattern from a string. If s is already a regex, returns it.

---

## re-seq

Returns a vector of successive matches of pattern in string.

---

## read-line

Reads a line from stdin (or the input stream). Returns nil on EOF.

---

## read-string

Reads one Clojure form from a string. Returns the parsed data structure.

---

## realized?

Returns true if a value has been produced for a promise, future or lazy sequence.

---

## reduce

f should be a function of 2 arguments. If val is not supplied, returns the
   result of applying f to the first 2 items in coll, then applying f to that
   result and the 3rd item, etc. If val is supplied, returns the result of
   applying f to val and the first item in coll, then applying f to that
   result and the 2nd item, etc.

---

## reduced

Wrap a value in Reduced to signal early termination of a reduction.

---

## reduced?

Returns true if v is a Reduced wrapper.

---

## reducev

f should be a function of 2 arguments. Returns the result of applying f
   to init and the first item in coll, then applying f to that result and
   the second item in coll, and so on. If coll is empty, returns init.

---

## reductions

Returns a lazy sequence of the intermediate values of a reduction.
   With init, starts from init. Without init, starts from first element.

---

## regex?

Returns true if x is a regex pattern.

---

## rem

Returns remainder of dividing numerator by denominator.
   Sign follows the dividend.

---

## remove

Returns a lazy sequence of the items in coll for which (pred item) returns logical false.

---

## repeat

Returns a lazy (infinite) sequence of x. Also accepts count: (repeat n x).

---

## repeatedly

Takes a function of no args, presumably with side effects, and
  returns an infinite (or length n if supplied) lazy sequence of calls
  to it.

---

## replace

Returns a lazy sequence with elements replaced using the given map.

---

## replicate

Returns a lazy sequence of n copies of x. Same as (repeat n x).

---

## requiring-resolve

Resolves a qualified symbol. If not found, requires its namespace and retries.

---

## reset!

Reset the atom's value to new-val and return it.

---

## rest

Returns a possibly-empty sequence of the items after the first.

---

## reverse

Returns a seq of the items in coll in reverse order.

---

## satisfies?

Returns true if x satisfies protocol (i.e. has an implementation for it).

---

## second

Same as (first (rest x)).

---

## select-keys

Returns a map containing only those entries in map whose key is in keys

---

## seq

Returns a sequence of the collection. Returns nil if the collection is empty.

---

## sequential?

Returns true if x is a sequential collection (list or vector).

---

## set

Returns a set of the items in coll.

---

## set?

Returns true if x is a set.

---

## short

Coerce to short (truncates to 16 bits).

---

## shuffle

Return a random permutation of coll. Uses Fisher-Yates shuffle.

---

## sleep

Causes the current thread to sleep for the given number of milliseconds.

---

## slurp

Opens and reads the file from the given path, returning its contents as a string.

---

## some

Returns the first logical true value of (pred x) for any x in coll, else nil.

---

## some-fn

Takes a set of predicates and returns a function f that returns the first logical true value
  returned by one of its composing predicates against any of its arguments,
  else it returns logical false. Note that f is short-circuiting in that it will
  stop execution on the first argument that triggers a logical true result against
  the original predicates.

---

## some?

Returns true if x is not nil, false otherwise.

---

## sort

Returns a sorted sequence of the items in coll, sorted by compare.
   coll must support count and nth.

---

## sort-by

Returns a sorted sequence of the items in coll, sorted by the comparison
   of (keyfn item). coll must support count and nth.

---

## spit

Writes the string content to a file, creating it if it doesn't exist.
  Optional :append true writes in append mode instead of overwriting.

---

## split-at

Returns a vector of [(take n coll) (drop n coll)].

---

## split-with

Returns a vector of [(take-while pred coll) (drop-while pred coll)].

---

## str

With no args, returns the empty string. With one arg, returns
   (.toString arg). With more args, returns the concatenation of
   the .toString of each.

---

## string?

Returns true if x is a string.

---

## subs

Returns the substring of s beginning at start inclusive, and ending
   at end (defaults to length of string), exclusive.

---

## subset?

Is set1 a subset of set2?

---

## subvec

Returns a persistent vector of the items in vector from
   start (inclusive) to end (exclusive). If end is not supplied,
   defaults to (count vector).

---

## superset?

Is set1 a superset of set2?

---

## swap!

Atomically swaps the value of the atom to be: (apply f current-value & args).

---

## symbol?

Returns true if x is a symbol.

---

## take

Returns a lazy sequence of the first n items in coll.

---

## take-last

Returns a seq of the last n items in coll.

---

## take-nth

Returns a lazy seq of every nth item in coll.

---

## take-while

Returns a lazy sequence of successive items from coll for which (pred item) returns logical true.

---

## third

Same as (first (rest (rest x))).

---

## time

Evaluates expr and prints the time it took. Returns the value of expr.

---

## trampoline

Calls f with the supplied args. If f returns a fn, calls that fn,
   repeating until a non-fn result is returned.

---

## true?

Returns true if x is the value true, false otherwise.

---

## union

Return a set that is the union of the input sets

---

## unreduced

If v is a Reduced wrapper, unwraps and returns the inner value. Otherwise returns v.

---

## unsigned-bit-shift-right

Shifts the bits of x to the right by n positions (logical shift, fills with zeros).

---

## update

Returns a map with the value at key updated by applying f to the current value.
   With extra args, applies (apply f (get m k) args).

---

## use

Like require but also refers all public vars into current namespace.

---

## utf8-valid?

Returns true if the string is valid UTF-8.

---

## val

Returns the value of the map entry.

---

## vals

Returns a sequence of the values in the map.

---

## vec

Returns a vector of the args, or converts a collection to a vector.

---

## vector?

Returns true if x is a vector.

---

## when-first

bindings => x xs

  Roughly the same as (when (seq xs) (let [x (first xs)] body)) but xs is evaluated only once.

---

## when-let

bindings => binding-form test

  When test is true, evaluates body with binding-form bound to the value of test.

---

## when-not

Evaluates test. If logical false, evaluates body in an implicit do.

---

## when-some

bindings => binding-form test

   When test is not nil, evaluates body with binding-form bound to the
   value of test.

---

## zero?

Returns true if num is zero, else false.

---

## zipmap

Returns a map with the keys mapped to the corresponding vals.
