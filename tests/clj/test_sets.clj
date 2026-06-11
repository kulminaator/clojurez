;; Sets: literals, set, set?, conj, disj, count, equality
(load-file "tests/clj/clj_test_helper.clj")

(check "set literal" #{1 2 3} '#{1 2 3})
(check "set empty" #{} '#{})
(check "set from list" (set (list 1 2 2 3)) '#{1 2 3})
(check "set?" (set? #{1 2}) true)
(check "set? not set" (set? (list 1 2)) false)
(check "conj set" (conj #{1 2} 3) '#{1 2 3})
(check "conj set dup" (conj #{1 2} 1) '#{1 2})
(check "disj set" (disj #{1 2 3} 2) '#{1 3})
(check "set as fn found" (#{1 2 3} 2) 2)
(check "set as fn not found" (#{1 2 3} 4) nil)
(check "count set" (count #{1 2 3}) 3)
(check "set equality" (= #{1 2} #{2 1}) true)

(print-summary)
