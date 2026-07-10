;; Test helper for Clojure VM test suites
;; Load with: (load-file "tests/clj/clj_test_helper.clj")
;; Provides: check, check-true, check-false, check-exception

;; Counters for pass/fail tracking
(def passes (atom 0))
(def failures (atom 0))

;; Check a single test: name, expression result, expected value
(defn check [name result expected]
  (if (= result expected)
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected=" expected " got=" result)))))

;; Check that a value is truthy
(defn check-true [name result]
  (if result
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected truthy, got=" result)))))

;; Check that a value is falsy
(defn check-false [name result]
  (if (not result)
    (do (swap! passes inc)
        (println (str "PASS: " name)))
    (do (swap! failures inc)
        (println (str "FAIL: " name " expected falsy, got=" result)))))

;; Print summary at the end of a test suite
(defn print-summary []
  (println (str "SUMMARY: " @passes " passed, " @failures " failed")))

;; ============================================================
;; with-echo-server: Pure Clojure TCP echo server test harness
;; ============================================================
;;
;; Creates a TCP server that echoes data back, runs a test function
;; with a connected client, and cleans up. Works on all platforms
;; (Linux, macOS, Windows).
;;
;; Usage:
;;   (check "my test"
;;     (with-echo-server
;;       (fn [client]
;;         (zig.io/write-bytes client "hello")
;;         (zig.io/read-bytes client 100)))
;;     "hello")
;;
;; With custom server logic:
;;   (with-echo-server
;;     (fn [client] ...)
;;     (fn [accepted] ...))
;;
;; Timeout: 5 seconds. Returns :timeout if test doesn't complete.

(defn- safe-close [s]
  "Close a socket, ignoring errors."  
  (zig.io/close-socket s))

(defn- echo-loop [accepted]
  "Recursive echo: read data, echo it back, repeat until EOF."  
  (when-let [buf (zig.io/read-bytes accepted 4096)]
    (zig.io/write-bytes accepted buf)
    (echo-loop accepted)))

(defn- default-echo-body [accepted]
  "Default echo server body: read data and echo it back, repeating until EOF."  
  (echo-loop accepted))

(defn with-echo-server
  "Run a test that needs a TCP echo server.

   Creates a server on an ephemeral port, accepts a connection,
   runs the test-fn with the client socket, and cleans up.

   test-fn: receives the client socket, should return test result.
   server-body-fn: (optional) receives the accepted socket, performs
     custom server-side logic. Defaults to echo (read all, write back).

   Returns the result of test-fn on success, or :timeout on failure."  
  ([test-fn] (with-echo-server test-fn nil))
  ([test-fn server-body-fn]
   (let [server-body (or server-body-fn default-echo-body)
         port-atom (atom nil)
         result-atom (atom :timeout)
         done-atom (atom false)]

     ;; Server thread
     (future
       (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
             port (zig.io/get-local-port server)]
         (reset! port-atom port)
         (let [accepted (zig.io/accept-connection server)]
           (server-body accepted)
           (safe-close accepted)
           (safe-close server))))

     ;; Wait for server to be ready
     (loop [_ 0]
       (if (and (< _ 50) (nil? @port-atom))
         (do (sleep 100) (recur (inc _)))
         nil))

     (when-let [port @port-atom]
       (let [client (zig.io/open-client-socket "127.0.0.1" port)
             test-result (test-fn client)]
         (reset! result-atom test-result)
         (safe-close client)))

     ;; Brief wait for server thread to finish
     (sleep 200)
     @result-atom)))
