#!/bin/bash
# Condition forms: false, true, nil, not, not=, =, identical?, nil?, some?,
# zero?, pos?, neg?, even?, odd?, boolean, and, or, if, when, when-not,
# if-not, cond, case, cond->, cond->>, if-let, when-let, some, every?, not-any?
source tests/helpers.sh

echo "=== Condition Forms Tests ==="

# false, true, nil (already tested in basic types)

# not
run_test "not true" '(not true)' "false"
run_test "not false" '(not false)' "true"
run_test "not nil" '(not nil)' "true"
run_test "not 1" '(not 1)' "false"

# not=
run_test "not= same" '(not= 1 1)' "false"
run_test "not= diff" '(not= 1 2)' "true"
run_test "not= multi same" '(not= 1 1 1)' "false"
run_test "not= multi diff" '(not= 1 2 3)' "true"

# =
run_test "= same" '(= 1 1)' "true"
run_test "= diff" '(= 1 2)' "false"
run_test "= multi" '(= 1 1 1)' "true"

# identical?
run_test "identical? same int" '(identical? 1 1)' "true"
run_test "identical? diff int" '(identical? 1 2)' "false"
run_test "identical? same atom" '(do (def id-a (atom 5)) (identical? id-a id-a))' "true"
run_test "identical? diff atom" '(do (def id-b (atom 5)) (def id-c (atom 5)) (identical? id-b id-c))' "false"
run_test "identical? same string" '(identical? "hello" "hello")' "true"
run_test "identical? diff string" '(identical? "hello" "world")' "false"

# nil?
run_test "nil? nil" '(nil? nil)' "true"
run_test "nil? int" '(nil? 1)' "false"

# some?
run_test "some? int" '(some? 1)' "true"
run_test "some? nil" '(some? nil)' "false"
run_test "some? true" '(some? true)' "true"
run_test "some? false" '(some? false)' "true"
run_test "some? empty string" '(some? "")' "true"

# zero?
run_test "zero? 0" '(zero? 0)' "true"
run_test "zero? 1" '(zero? 1)' "false"
run_test "zero? -1" '(zero? (- 0 1))' "false"

# pos?
run_test "pos? 1" '(pos? 1)' "true"
run_test "pos? 0" '(pos? 0)' "false"
run_test "pos? -1" '(pos? (- 0 1))' "false"

# neg?
run_test "neg? -1" '(neg? (- 0 1))' "true"
run_test "neg? 0" '(neg? 0)' "false"
run_test "neg? 1" '(neg? 1)' "false"

# even?
run_test "even? 2" '(even? 2)' "true"
run_test "even? 3" '(even? 3)' "false"
run_test "even? 0" '(even? 0)' "true"

# odd?
run_test "odd? 3" '(odd? 3)' "true"
run_test "odd? 2" '(odd? 2)' "false"
run_test "odd? 1" '(odd? 1)' "true"

# boolean
run_test "boolean true" '(boolean true)' "true"
run_test "boolean false" '(boolean false)' "false"
run_test "boolean nil" '(boolean nil)' "false"
run_test "boolean 1" '(boolean 1)' "true"
run_test "boolean 0" '(boolean 0)' "true"

# and
run_test "and true true" '(and true true)' "true"
run_test "and true false" '(and true false)' "false"
run_test "and false true" '(and false true)' "false"
run_test "and no args" '(and)' "true"

# or
run_test "or true false" '(or true false)' "true"
run_test "or false true" '(or false true)' "true"
run_test "or false false" '(or false false)' "false"
run_test "or no args" '(or)' ""

# if
run_test "if true" '(if true :yes :no)' ":yes"
run_test "if false" '(if false :yes :no)' ":no"
run_test "if no else" '(if true :yes)' ":yes"

# when
run_test "when true" '(when true :yes)' ":yes"
run_test "when false" '(when false :yes)' ""

# when-not
run_test "when-not false" '(when-not false :yes)' ":yes"
run_test "when-not true" '(when-not true :yes)' ""

# if-not
run_test "if-not false" '(if-not false :yes :no)' ":yes"
run_test "if-not true" '(if-not true :yes :no)' ":no"

# cond
run_test "cond first" '(cond (= 1 1) :yes :else :no)' ":yes"
run_test "cond else" '(cond (= 1 2) :yes :else :no)' ":no"
run_test "cond no match" '(cond (= 1 2) :a (= 3 4) :b)' ""

# case
run_test "case match 1" '(case 1 1 "one" 2 "two" :else "default")' "\"one\""
run_test "case match 2" '(case 2 1 "one" 2 "two" :else "default")' "\"two\""
run_test "case default" '(case 3 1 "one" 2 "two" :else "default")' "\"default\""
run_test "case no match no default" '(case 3 1 "one" 2 "two")' ""
run_test "case string" '(case "a" "a" :yes "b" :no :else :default)' ":yes"
run_test "case keyword" '(case :x :x :yes :y :no :else :default)' ":yes"

# cond->
run_test "cond-> true step" '(cond-> 1 true inc)' "2"
run_test "cond-> false step" '(cond-> 1 false inc)' "1"
run_test "cond-> multi true" '(cond-> 1 true inc true inc)' "3"
run_test "cond-> multi mixed" '(cond-> 1 true inc false dec)' "2"
run_test "cond-> list form" '(cond-> [1] true (conj 2))' "[1 2]"

# cond->>
run_test "cond->> true step" '(cond->> 1 true inc)' "2"
run_test "cond->> false step" '(cond->> 1 false inc)' "1"
run_test "cond->> multi true" '(cond->> 1 true inc true inc)' "3"
run_test "cond->> multi mixed" '(cond->> 1 true inc false dec)' "2"
run_test "cond->> list form" '(cond->> (list 1) true (cons 2))' "(2 1)"

# if-let
run_test "if-let truthy" '(if-let [x 1] x :nope)' "1"
run_test "if-let nil" '(if-let [x nil] x :nope)' ":nope"

# when-let
run_test "when-let truthy" '(when-let [x 1] x)' "1"
run_test "when-let nil" '(when-let [x nil] x)' ""

# some
run_test "some found" '(some #(> % 2) (list 1 2 3 4))' "true"
run_test "some not found" '(some #(> % 10) (list 1 2 3 4))' ""

# every?
run_test "every? all" '(every? #(> % 0) (list 1 2 3))' "true"
run_test "every? not all" '(every? #(> % 1) (list 1 2 3))' "false"
run_test "every? empty" '(every? #(> % 0) (list))' "true"

# not-any?
run_test "not-any? none" '(not-any? #(> % 10) (list 1 2 3))' "true"
run_test "not-any? some" '(not-any? #(> % 1) (list 1 2 3))' "false"
run_test "not-any? empty" '(not-any? #(> % 0) (list))' "true"
