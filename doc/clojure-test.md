# clojure.test


## Table of Contents

- [add-ns-meta](#add-ns-meta)
- [are](#are)
- [assert-any](#assert-any)
- [assert-predicate](#assert-predicate)
- [compose-fixtures](#compose-fixtures)
- [default-fixture](#default-fixture)
- [deftest](#deftest)
- [deftest-](#deftest-)
- [do-report](#do-report)
- [inc-report-counter](#inc-report-counter)
- [is](#is)
- [join-fixtures](#join-fixtures)
- [ns-sym](#ns-sym)
- [run-all-tests](#run-all-tests)
- [run-test](#run-test)
- [run-test-var](#run-test-var)
- [run-tests](#run-tests)
- [set-test](#set-test)
- [successful?](#successful?)
- [test-all-vars](#test-all-vars)
- [test-ns](#test-ns)
- [test-var](#test-var)
- [test-vars](#test-vars)
- [testing](#testing)
- [testing-contexts-str](#testing-contexts-str)
- [testing-vars-str](#testing-vars-str)
- [try-expr](#try-expr)
- [use-fixtures](#use-fixtures)
- [with-test](#with-test)
- [with-test-out](#with-test-out)

---

## add-ns-meta

[(key coll)]

Adds elements in coll to the current namespace metadata as the value of key.

---

## are

[(argv expr & args)]

Checks multiple assertions with a template expression.
   Example: (are [x y] (= x y)
                2 (+ 1 1)
                4 (* 2 2))

---

## assert-any

[(msg form)]

Returns generic assertion code for any test,
   including macros, method calls, or isolated symbols.

---

## assert-predicate

[(msg form)]

Returns generic assertion code for any functional predicate.
   The 'expected' argument to 'report' will contain the original form,
   the 'actual' argument will contain the form with all its sub-forms evaluated.
   If the predicate returns false, the 'actual' form will be wrapped in (not ...).

---

## compose-fixtures

[(f1 f2)]

Composes two fixture functions, creating a new fixture function
   that combines their behavior.

---

## default-fixture

[(f)]

The default, empty, fixture function. Just calls its argument.

---

## deftest

[(name & body)]

Defines a test function with no arguments.  Test functions may call
   other tests, so tests may be composed.  If you compose tests, you
   should also define a function named test-ns-hook; run-tests will
   call test-ns-hook instead of testing all vars.

   When *load-tests* is false, deftest is ignored.

---

## deftest-

[(name & body)]

Like deftest but creates a private var.

---

## do-report

[(m)]

Add file and line information to a test result and call report.

---

## inc-report-counter

[(name)]

Increments the named counter in *report-counters*, a ref to a map.

---

## is

[(form) (form msg)]

Generic assertion macro. 'form' is any predicate test.
   'msg' is an optional message to attach to the assertion.

   Example: (is (= 4 (+ 2 2)) "Two plus two should be 4")

   Special forms:

   (is (thrown? c body)) checks that an instance of c is thrown from
   body, fails if not; then returns the thing thrown.

   (is (thrown-with-msg? c re body)) checks that an instance of c is
   thrown AND that the message on the exception matches (with
   re-find) the regular expression re.

---

## join-fixtures

[(fixtures)]

Composes a collection of fixtures, in order. Always returns a valid
   fixture function, even if the collection is empty.

---

## ns-sym

[(name)]

Create a namespaced symbol for use in macro-generated code.
   Ensures the symbol resolves to the clojure.test namespace.

---

## run-all-tests

[() (re)]

Runs all tests in all namespaces; prints results.
   Optional argument is a regular expression; only namespaces with
   names matching the regular expression (with re-matches) will be
   tested.

---

## run-test

[(sym)]

Runs the tests for a single test var, identified by symbol.
   Returns the summary map.

---

## run-test-var

[(v)]

Runs the tests for a single Var, with fixtures executed around
   the test, and summary output after.

---

## run-tests

[(& namespaces)]

Runs all tests in the given namespaces; prints results.
   Returns a map summarizing test results.

---

## set-test

[(name & body)]

Sets :test metadata of the named var to a fn with the given body.
   The var must already exist.  Does not modify the value of the var.

   When *load-tests* is false, set-test is ignored.

---

## successful?

[(summary)]

Returns true if the given test summary indicates all tests
   were successful, false otherwise.

---

## test-all-vars

[(ns-obj)]

Calls test-vars on every var interned in the namespace, with fixtures.

---

## test-ns

[(ns)]

If the namespace defines a function named test-ns-hook, calls that.
   Otherwise, calls test-all-vars on the namespace. 'ns' is a
   namespace object or a symbol.

   Internally binds *report-counters* to a ref initialized to
   *initial-report-counters*. Returns the final, dereferenced state of
   *report-counters*.

---

## test-var

[(v)]

If v has a function in its :test metadata, calls that function,
   with *testing-vars* bound to (conj *testing-vars* v).

---

## test-vars

[(vars ns-obj)]

Groups vars by their namespace and runs test-var on them with
   appropriate fixtures applied.

---

## testing

[(string & body)]

Adds a new string to the list of testing contexts.  May be nested,
   but must occur inside a test function (deftest).

---

## testing-contexts-str

[()]

Returns a string representation of the current test context.

---

## testing-vars-str

[(m)]

Returns a string representation of the current test.

---

## try-expr

[(msg form)]

Used by the 'is' macro to catch unexpected exceptions.

---

## use-fixtures

[(fixture-type & args)]

Wrap test runs in a fixture function to perform setup and teardown.
   Using a fixture-type of :each wraps every test individually,
   while :once wraps the whole run in a single function.

---

## with-test

[(definition & body)]

Takes any definition form (that returns a Var) as the first argument.
   Remaining body goes in the :test metadata function for that Var.

   When *load-tests* is false, only evaluates the definition, ignoring
   the tests.

---

## with-test-out

[(& body)]

Runs body with output directed to *test-out*.
