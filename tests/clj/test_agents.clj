;; Agent Tests: Comprehensive test suite for Clojure agents
;; All async tests use await-for with short timeouts (max 2000ms) to prevent hangs.
(load-file "tests/clj/clj_test_helper.clj")

;; ============================================================
;; 1. CREATION TESTS
;; ============================================================

(check "agent creates agent with integer" (agent? (agent 42)) true)
(check "agent creates agent with zero" (agent? (agent 0)) true)
(check "agent creates agent with nil" (agent? (agent nil)) true)
(check "agent creates agent with string" (agent? (agent "hello")) true)
(check "agent creates agent with list" (agent? (agent (list 1 2 3))) true)
(check "agent creates agent with map" (agent? (agent {:a 1})) true)
(check "agent creates agent with vector" (agent? (agent [1 2 3])) true)
(check "agent creates agent with set" (agent? (agent #{1 2})) true)
(check "agent creates agent with float" (agent? (agent 3.14)) true)
(check "agent creates agent with boolean" (agent? (agent true)) true)
(check "agent creates agent with negative" (agent? (agent -99)) true)

;; Creation with options
(check "agent with :error-mode :continue" (agent? (agent 0 :error-mode :continue)) true)
(check "agent with :error-mode :fail" (agent? (agent 0 :error-mode :fail)) true)
(check "agent with :validator" (agent? (agent 1 :validator pos?)) true)
(check "agent with :error-handler" (agent? (agent 0 :error-handler (fn [e a] nil))) true)
(check "agent with multiple options" (agent? (agent 0 :error-mode :continue :validator pos?)) true)

;; ============================================================
;; 2. DEREF TESTS
;; ============================================================

;; @ reader macro
(check "deref @ returns integer" (= @(agent 42) 42) true)
(check "deref @ returns nil" (nil? @(agent nil)) true)
(check "deref @ returns string" (= @(agent "hello") "hello") true)
(check "deref @ returns zero" (= @(agent 0) 0) true)
(check "deref @ returns false" (= @(agent false) false) true)
(check "deref @ returns true" (= @(agent true) true) true)
(check "deref @ returns list" (= @(agent (list 1 2)) (list 1 2)) true)
(check "deref @ returns map" (= @(agent {:x 1}) {:x 1}) true)
(check "deref @ returns vector" (= @(agent [1 2 3]) [1 2 3]) true)
(check "deref @ returns float" (= @(agent 3.14) 3.14) true)

;; deref function
(check "deref fn returns integer" (= (deref (agent 99)) 99) true)
(check "deref fn returns nil" (nil? (deref (agent nil))) true)
(check "deref fn returns string" (= (deref (agent "world")) "world") true)

;; agent? predicate
(check "agent? on agent returns true" (agent? (agent 0)) true)
(check "agent? on integer returns false" (agent? 42) false)
(check "agent? on nil returns false" (agent? nil) false)
(check "agent? on string returns false" (agent? "hello") false)
(check "agent? on atom returns false" (agent? (atom 1)) false)
(check "agent? on list returns false" (agent? (list 1 2 3)) false)
(check "agent? on map returns false" (agent? {:a 1}) false)
(check "agent? on vector returns false" (agent? [1 2]) false)
(check "agent? on set returns false" (agent? #{1}) false)
(check "agent? on fn returns false" (agent? inc) false)

;; ============================================================
;; 3. SEND TESTS
;; ============================================================

;; Basic send
(check "send increments" (let [a (agent 0)] (send a inc) (await-for 2000 a) (= @a 1)) true)
(check "send decrements" (let [a (agent 10)] (send a dec) (await-for 2000 a) (= @a 9)) true)
(check "send doubles" (let [a (agent 5)] (send a #(* % 2)) (await-for 2000 a) (= @a 10)) true)

;; Send with args
(check "send with args add" (let [a (agent 0)] (send a + 10 20) (await-for 2000 a) (= @a 30)) true)
(check "send with args multiply" (let [a (agent 1)] (send a * 3 4) (await-for 2000 a) (= @a 12)) true)
(check "send with args subtract" (let [a (agent 100)] (send a - 30) (await-for 2000 a) (= @a 70)) true)

;; Chained sends (FIFO ordering)
(check "send chains 3 in order" (let [a (agent 0)] (send a inc) (send a inc) (send a inc) (await-for 2000 a) (= @a 3)) true)
(check "send chains 10 in order" (let [a (agent 0)] (loop [i 0] (if (< i 10) (do (send a inc) (recur (inc i))))) (await-for 2000 a) (= @a 10)) true)
(check "send chains with args" (let [a (agent 1)] (send a + 1) (send a + 2) (send a + 3) (await-for 2000 a) (= @a 7)) true)

;; Concurrent sends on multiple agents
(check "concurrent sends on two agents" (let [a1 (agent 0) a2 (agent 0)] (send a1 inc) (send a2 + 10) (await-for 2000 a1 a2) (and (= @a1 1) (= @a2 10))) true)
(check "concurrent sends on three agents" (let [a1 (agent 0) a2 (agent 0) a3 (agent 0)] (send a1 inc) (send a2 inc) (send a3 inc) (await-for 2000 a1 a2 a3) (and (= @a1 1) (= @a2 1) (= @a3 1))) true)

;; Send returns agent
(check "send returns agent" (let [a (agent 0)] (agent? (send a inc))) true)

;; ============================================================
;; 4. SEND-OFF TESTS
;; ============================================================

;; Basic send-off
(check "send-off increments" (let [a (agent 0)] (send-off a inc) (await-for 2000 a) (= @a 1)) true)
(check "send-off with args" (let [a (agent 0)] (send-off a + 5 10) (await-for 2000 a) (= @a 15)) true)
(check "send-off returns agent" (let [a (agent 0)] (agent? (send-off a inc))) true)

;; Send-off with sleep (blocking I/O pattern)
(check "send-off with sleep" (let [a (agent 0)] (send-off a (fn [v] (sleep 100) (inc v))) (await-for 2000 a) (= @a 1)) true)

;; Mixed send and send-off
(check "send and send-off can mix" (let [a (agent 0)] (send a inc) (send-off a inc) (await-for 2000 a) (= @a 2)) true)
(check "multiple send-off chains" (let [a (agent 0)] (send-off a inc) (send-off a inc) (send-off a inc) (await-for 2000 a) (= @a 3)) true)

;; ============================================================
;; 5. AWAIT TESTS
;; ============================================================

;; Single agent
(check "await single agent" (let [a (agent 0)] (send a inc) (await a) (= @a 1)) true)

;; Multiple agents
(check "await multiple agents" (let [a1 (agent 0) a2 (agent 0)] (send a1 inc) (send a2 inc) (await a1 a2) (and (= @a1 1) (= @a2 1))) true)
(check "await three agents" (let [a1 (agent 0) a2 (agent 0) a3 (agent 0)] (send a1 inc) (send a2 + 10) (send a3 * 2) (await a1 a2 a3) (and (= @a1 1) (= @a2 10) (= @a3 0))) true)

;; Already-completed agents
(check "await already-completed agent" (let [a (agent 0)] (send a inc) (await-for 2000 a) (await a) (= @a 1)) true)
(check "await no pending actions" (let [a (agent 99)] (await a) (= @a 99)) true)

;; ============================================================
;; 6. AWAIT-FOR TESTS
;; ============================================================

;; Completes in time
(check "await-for completes in time" (let [a (agent 0)] (send a inc) (await-for 2000 a)) true)
(check "await-for multiple agents in time" (let [a1 (agent 0) a2 (agent 0)] (send a1 inc) (send a2 inc) (await-for 2000 a1 a2)) true)
(check "await-for returns true" (let [a (agent 0)] (send a inc) (= (await-for 2000 a) true)) true)

;; Times out
(check "await-for times out" (let [a (agent 0)] (send a (fn [v] (sleep 10000) v)) (not (await-for 1 a))) true)
(check "await-for timeout returns false" (let [a (agent 0)] (send a (fn [v] (sleep 10000) v)) (= (await-for 1 a) false)) true)

;; Already completed (no pending)
(check "await-for no pending returns true" (let [a (agent 0)] (= (await-for 100 a) true)) true)

;; ============================================================
;; 7. ERROR HANDLING TESTS
;; ============================================================

;; Default error-mode is :fail
(check "default error-mode is :fail" (= (error-mode (agent 0)) :fail) true)

;; :fail mode - agent stops processing
(check "fail mode stops on error" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (= @a 0)) true)
(check "fail mode has error" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (not (nil? (agent-error a)))) true)
(check "fail mode has errors list" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (not (empty? (agent-errors a)))) true)

;; :continue mode - agent keeps processing
(check "continue mode keeps processing" (let [a (agent 0 :error-mode :continue)] (send a (fn [_] (/ 1 0))) (send a inc) (await-for 2000 a) (= @a 1)) true)
(check "continue mode has error recorded" (let [a (agent 0 :error-mode :continue)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (not (nil? (agent-error a)))) true)

;; Error handler
(check "error-mode :continue with handler" (let [a (agent 0 :error-mode :continue :error-handler (fn [e a] nil))] (= (error-mode a) :continue)) true)
(check "error-handler is nil by default" (let [a (agent 0)] (nil? (error-handler a))) true)
(check "error-handler set on creation" (let [a (agent 0 :error-handler (fn [e a] a))] (not (nil? (error-handler a)))) true)

;; set-error-mode! and set-error-handler!
(check "set-error-mode! to :continue" (let [a (agent 0)] (set-error-mode! a :continue) (= (error-mode a) :continue)) true)
(check "set-error-mode! to :fail" (let [a (agent 0 :error-mode :continue)] (set-error-mode! a :fail) (= (error-mode a) :fail)) true)
(check "set-error-handler! sets handler" (let [a (agent 0)] (set-error-handler! a (fn [e a] nil)) (not (nil? (error-handler a)))) true)
(check "set-error-handler! nil removes" (let [a (agent 0)] (set-error-handler! a (fn [e a] nil)) (set-error-handler! a nil) (nil? (error-handler a))) true)

;; clear-agent-errors
(check "clear-agent-errors resets agent" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (clear-agent-errors a) (nil? (agent-error a))) true)
(check "clear-agent-errors clears errors list" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (clear-agent-errors a) (empty? (agent-errors a))) true)
(check "clear-agent-errors allows processing" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (clear-agent-errors a) (send a inc) (await-for 2000 a) (= @a 1)) true)

;; ============================================================
;; 8. RESTART TESTS
;; ============================================================

;; Basic restart
(check "restart-agent resets value" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (restart-agent a 10) (= @a 10)) true)
(check "restart-agent clears error" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (restart-agent a 0) (nil? (agent-error a))) true)
(check "restart-agent allows new sends" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (await-for 2000 a) (restart-agent a 0) (send a inc) (await-for 2000 a) (= @a 1)) true)

;; Restart with clear-actions
(check "restart-agent with clear-actions" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (send a inc) (await-for 2000 a) (restart-agent a 10 :clear-actions true) (= @a 10)) true)

;; Restart without clear-actions (keeps pending actions)
(check "restart-agent without clear-actions processes pending" (let [a (agent 0)] (send a (fn [_] (/ 1 0))) (send a inc) (await-for 2000 a) (restart-agent a 0) (await-for 2000 a) (= @a 1)) true)

;; Restart on non-failed agent
(check "restart-agent on clean agent" (let [a (agent 0)] (restart-agent a 99) (= @a 99)) true)

;; ============================================================
;; 9. VALIDATOR TESTS
;; ============================================================

;; Set and get validator
(check "set-validator! and get-validator" (let [a (agent 1)] (set-validator! a pos?) (not (nil? (get-validator a)))) true)

;; Validator rejection
(check "validator rejects invalid value after send" (let [a (agent 1)] (set-validator! a pos?) (send a (fn [_] -1)) (await-for 2000 a) (not (nil? (agent-error a)))) true)
(check "validator rejects via zero" (let [a (agent 1)] (set-validator! a pos?) (send a (fn [_] 0)) (await-for 2000 a) (not (nil? (agent-error a)))) true)

;; Nil removes validator
(check "validator nil removes validator" (let [a (agent 1)] (set-validator! a pos?) (set-validator! a nil) (nil? (get-validator a))) true)

;; Validator on creation
(check "validator on agent creation" (let [a (agent 1 :validator pos?)] (not (nil? (get-validator a)))) true)

;; Validator allows valid transitions
(check "validator allows valid transition" (let [a (agent 1)] (set-validator! a pos?) (send a inc) (await-for 2000 a) (= @a 2)) true)

;; ============================================================
;; 10. WATCH TESTS
;; ============================================================

;; Add/remove watch
(check "add-watch returns agent" (agent? (add-watch (agent 0) :test (fn [k a o n] nil))) true)
(check "remove-watch returns agent" (agent? (let [a (agent 0)] (add-watch a :test (fn [k a o n] nil)) (remove-watch a :test))) true)

;; Watch triggers on send
(check "add-watch and send triggers watch" (let [log (atom []) a (agent 0)] (add-watch a :test (fn [k ag old new] (swap! log conj [k old new]))) (send a inc) (await-for 2000 a) (= (count @log) 1)) true)

;; Watch receives correct args
(check "watch receives correct args" (let [log (atom []) a (agent 42)] (add-watch a :w (fn [k ag old new] (swap! log conj {:key k :old old :new new}))) (send a + 8) (await-for 2000 a) (let [entry (first @log)] (and (= (:key entry) :w) (= (:old entry) 42) (= (:new entry) 50)))) true)

;; Multiple watches fire
(check "multiple watches fire" (let [log1 (atom []) log2 (atom []) a (agent 0)] (add-watch a :w1 (fn [k ag old new] (swap! log1 conj [k old new]))) (add-watch a :w2 (fn [k ag old new] (swap! log2 conj [k old new]))) (send a inc) (await-for 2000 a) (and (= (count @log1) 1) (= (count @log2) 1))) true)

;; Remove-watch stops watch
(check "remove-watch stops watch" (let [log (atom []) a (agent 0)] (add-watch a :test (fn [k ag old new] (swap! log conj [k old new]))) (send a inc) (await-for 2000 a) (remove-watch a :test) (send a inc) (await-for 2000 a) (= (count @log) 1)) true)

;; Add-watch replaces existing
(check "add-watch replaces existing watch" (let [log1 (atom []) log2 (atom []) a (agent 0)] (add-watch a :test (fn [k ag old new] (swap! log1 conj [k old new]))) (add-watch a :test (fn [k ag old new] (swap! log2 conj [k old new]))) (send a inc) (await-for 2000 a) (and (= (count @log1) 0) (= (count @log2) 1))) true)

;; Watch fires on send-off
(check "watch fires on send-off" (let [log (atom []) a (agent 0)] (add-watch a :test (fn [k ag old new] (swap! log conj [k old new]))) (send-off a inc) (await-for 2000 a) (= (count @log) 1)) true)

;; Watch fires on multiple sends
(check "watch fires on multiple sends" (let [log (atom []) a (agent 0)] (add-watch a :test (fn [k ag old new] (swap! log conj [k old new]))) (send a inc) (send a inc) (send a inc) (await-for 2000 a) (= (count @log) 3)) true)

;; ============================================================
;; 11. GC STRESS TESTS
;; ============================================================

;; Agent survives gc-sweep
(check "agent survives gc-sweep" (let [a (agent 42)] (zig.core/gc-sweep) (= @a 42)) true)
(check "agent send survives gc-sweep" (let [a (agent 0)] (send a inc) (zig.core/gc-sweep) (await-for 2000 a) (= @a 1)) true)
(check "agent with validator survives gc-sweep" (let [a (agent 1 :validator pos?)] (zig.core/gc-sweep) (not (nil? (get-validator a)))) true)
(check "agent with watch survives gc-sweep" (let [log (atom []) a (agent 0)] (add-watch a :gc (fn [k ag old new] (swap! log conj [k old new]))) (zig.core/gc-sweep) (send a inc) (await-for 2000 a) (= (count @log) 1)) true)

;; Multiple gc-sweeps
(check "agent survives multiple gc-sweeps" (let [a (agent 99)] (loop [i 0] (if (< i 5) (do (zig.core/gc-sweep) (recur (inc i))))) (= @a 99)) true)

;; GC stats don't crash with agents
(check "gc-stats works with agents" (let [a (agent 0)] (send a inc) (await-for 2000 a) (let [stats (zig.core/gc-stats)] (map? stats))) true)

;; ============================================================
;; 12. EDGE CASES
;; ============================================================

;; Note: send to nil/non-agent throws TypeError at Zig level (not catchable by try/catch)
;; These are tested via shell tests in test_shell_error.clj

;; Await with no agents - should handle gracefully or error
(check "await-for with no pending actions" (let [a (agent 0)] (await-for 100 a)) true)

;; Send with complex function
(check "send with complex fn" (let [a (agent [])] (send a conj 1) (send a conj 2) (send a conj 3) (await-for 2000 a) (= @a [1 2 3])) true)

;; Send with string operations
(check "send with string concat" (let [a (agent "")] (send a str "x") (await-for 2000 a) (= @a "x")) true)

;; Agent with map value
(check "agent with map send assoc" (let [a (agent {:count 0})] (send a assoc :count 1) (await-for 2000 a) (= @a {:count 1})) true)

;; Agent identity function
(check "send identity function" (let [a (agent 42)] (send a identity) (await-for 2000 a) (= @a 42)) true)

;; Multiple agents independent state
(check "multiple agents independent" (let [a1 (agent 1) a2 (agent 2)] (send a1 inc) (send a2 dec) (await-for 2000 a1 a2) (and (= @a1 2) (= @a2 1))) true)

;; Send many times
(check "send 50 times" (let [a (agent 0)] (loop [i 0] (if (< i 50) (do (send a inc) (recur (inc i))))) (await-for 2000 a) (= @a 50)) true)

;; ============================================================
;; SHUTDOWN TESTS (MUST be last - shuts down thread pools)
;; ============================================================

(check "shutdown-agents completes" (do (shutdown-agents) :ok) :ok)

(print-summary)
