;; Protocol tests: type, defprotocol, extend, extend-type
;; NOTE: GC bug with protocol map cloning. Minimal tests only.
(load-file "tests/clj/clj_test_helper.clj")

;; --- type function ---
(check "type string" (type "hello") :string)
(check "type integer" (type 42) :integer)
(check "type nil" (type nil) :nil)
(check "type bool" (type true) :bool)
(check "type map" (type {:a 1}) :map)

;; --- defprotocol + extend ---
(defprotocol Proto1 (foo [this]))
(extend :string Proto1 {:foo (fn [this] (str "foo-" this))})
(check "extend: foo on string" (foo "hello") "foo-hello")

;; --- extend-type ---
(defprotocol Proto2 (bar [this]))
(extend-type :string Proto2 (bar [this] (str "bar-" this)))
(check "extend-type: bar on string" (bar "test") "bar-test")

(print-summary)
