;; Protocol tests: type, defprotocol, extend, extend-type, extend-protocol,
;;                 satisfies?, extends?, extenders
(load-file "tests/clj/clj_test_helper.clj")

;; --- type function ---
(check "type string" (type "hello") :string)
(check "type integer" (type 42) :integer)
(check "type nil" (type nil) :nil)
(check "type bool" (type true) :bool)
(check "type map" (type {:a 1}) :map)
(check "type vector" (type [1 2]) :vector)
(check "type list" (type (list 1)) :list)

;; --- defprotocol + extend ---
(defprotocol Proto1 (foo [this]))
(extend :string Proto1 {:foo (fn [this] (str "foo-" this))})
(check "extend: foo on string" (foo "hello") "foo-hello")

;; --- extend with multiple types ---
(defprotocol ProtoMulti (greet [this]))
(extend :string ProtoMulti {:greet (fn [s] (str "hello " s))})
(extend :integer ProtoMulti {:greet (fn [n] (* n 10))})
(extend :nil ProtoMulti {:greet (fn [_] "hello nil")})
(check "multi-type: greet string" (greet "world") "hello world")
(check "multi-type: greet integer" (greet 5) 50)
(check "multi-type: greet nil" (greet nil) "hello nil")

;; --- extend-type ---
(defprotocol Proto2 (bar [this]))
(extend-type :string Proto2 (bar [this] (str "bar-" this)))
(check "extend-type: bar on string" (bar "test") "bar-test")

;; --- extend-type with multiple methods ---
(defprotocol Proto3 (alpha [this]) (beta [this x]))
(extend-type :string Proto3
  (alpha [this] (str "alpha-" this))
  (beta [this x] (str this "-" x)))
(check "extend-type multi-method: alpha" (alpha "hello") "alpha-hello")
(check "extend-type multi-method: beta" (beta "hello" 42) "hello-42")

;; --- extend-protocol ---
(defprotocol Q (qux [this]))
(extend-protocol Q
  :string (qux [this] (str "qux-" this))
  :integer (qux [this] (* this 3))
  :nil (qux [_] "qux-nil"))
(check "extend-protocol: qux string" (qux "hi") "qux-hi")
(check "extend-protocol: qux integer" (qux 10) 30)
(check "extend-protocol: qux nil" (qux nil) "qux-nil")

;; --- satisfies? ---
(defprotocol SatP (sat-method [this]))
(extend :string SatP {:sat-method (fn [s] s)})
(check "satisfies? true" (satisfies? SatP "hello") true)
(check "satisfies? false" (satisfies? SatP 42) false)
(check "satisfies? nil type" (satisfies? SatP nil) false)

;; --- extends? ---
(check "extends? true" (extends? SatP :string) true)
(check "extends? false" (extends? SatP :integer) false)

;; --- extenders ---
(defprotocol ExtP (ext-method [this]))
(extend :string ExtP {:ext-method (fn [s] s)})
(extend :integer ExtP {:ext-method (fn [n] n)})
(let [ext (extenders ExtP)]
  (check "extenders contains string" (contains? ext :string) true)
  (check "extenders contains integer" (contains? ext :integer) true)
  (check "extenders count" (count ext) 2))

;; --- Protocol with docstring ---
(defprotocol DocP
  "A protocol with documentation"
  (doc-method [this]))
(extend :string DocP {:doc-method (fn [s] s)})
(check "protocol with docstring" (doc-method "test") "test")

;; --- Multiple protocols on same type ---
(defprotocol MP1 (mp1-method [this]))
(defprotocol MP2 (mp2-method [this]))
(extend :string MP1 {:mp1-method (fn [s] (str "mp1-" s))})
(extend :string MP2 {:mp2-method (fn [s] (str "mp2-" s))})
(check "multi-protocol: mp1" (mp1-method "x") "mp1-x")
(check "multi-protocol: mp2" (mp2-method "x") "mp2-x")

;; --- Extending same protocol twice (GC bug regression test) ---
(defprotocol ReExtP (rext [this]))
(extend :string ReExtP {:rext (fn [s] (str "first-" s))})
(extend :integer ReExtP {:rext (fn [n] (* n 2))})
(check "re-extend: string still works" (rext "a") "first-a")
(check "re-extend: integer works" (rext 7) 14)

(print-summary)
