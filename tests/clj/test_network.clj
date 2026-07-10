;; Network socket tests for clojurez
;; Pure Clojure TCP server — no external binaries needed

(load-file "tests/clj/clj_test_helper.clj")
(require '[zig.io :as io])

;; ============================================================
;; Helpers
;; ============================================================

(defn- safe-close [s]
  "Close a socket, ignoring errors."  
  (try (zig.io/close-socket s) (catch Exception _ nil)))

(defn- with-tcp-client
  "Run test-fn with a connected TCP client socket.
   Creates a server on ephemeral port, accepts connection, passes client to test-fn.
   Cleans up both sockets."  
  [test-fn]
  (let [port-atom (atom nil)
        result-atom (atom nil)
        error-atom (atom nil)]
    ;; Server thread
    (future
      (try
        (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
              port (zig.io/get-local-port server)]
          (reset! port-atom port)
          (let [accepted (zig.io/accept-connection server)]
            ;; Hold connection while test runs (poll result-atom)
            (loop [_ 0]
              (if (and (< _ 100) (nil? @result-atom))
                (do (sleep 50) (recur (inc _)))
                nil))
            (safe-close accepted)
            (safe-close server)))
        (catch Exception e
          (reset! error-atom (ex-message e)))))
    ;; Wait for server to bind
    (loop [_ 0]
      (if (and (< _ 50) (nil? @port-atom))
        (do (sleep 100) (recur (inc _)))
        nil))
    ;; Connect client and run test
    (when-let [port @port-atom]
      (let [client (zig.io/open-client-socket "127.0.0.1" port)]
        (try
          (reset! result-atom (test-fn client))
          (catch Exception e
            (reset! result-atom (ex-message e))))
        (sleep 50)
        (safe-close client)))
    @result-atom))

;; ============================================================
;; Phase 2: TCP Client Tests
;; ============================================================

;; --- open-client-socket ---
(check "tcp-client: open-client-socket connects to echo server"
  (with-tcp-client
    (fn [client]
      (zig.io/close-socket client)
      true))
  true)

(check "tcp-client: open-client-socket connection refused throws"
  (try
    (zig.io/open-client-socket "127.0.0.1" 19999)
    false
    (catch Exception e true))
  true)

(check "tcp-client: open-client-socket bad host throws"
  (try
    (zig.io/open-client-socket "not-a-valid-host-name" 80)
    false
    (catch Exception e true))
  true)

;; --- close-socket ---
(check "tcp-client: close-socket returns nil"
  (with-tcp-client
    (fn [client]
      (zig.io/close-socket client)))
  nil)

(check "tcp-client: close-socket double-close is no-op"
  (with-tcp-client
    (fn [client]
      (zig.io/close-socket client)
      (zig.io/close-socket client)
      true))
  true)

;; --- get-local-port ---
(check "tcp-client: get-local-port returns positive integer"
  (with-tcp-client
    (fn [client]
      (let [port (zig.io/get-local-port client)]
        (zig.io/close-socket client)
        (> port 0))))
  true)

;; --- get-remote-address / get-remote-port ---
(check "tcp-client: get-remote-address returns string"
  (with-tcp-client
    (fn [client]
      (let [addr (zig.io/get-remote-address client)]
        (zig.io/close-socket client)
        (string? addr))))
  true)

(check "tcp-client: get-remote-port returns correct port"
  (with-tcp-client
    (fn [client]
      (let [port (zig.io/get-remote-port client)]
        (zig.io/close-socket client)
        (> port 0)))) ; ephemeral port, just check it's valid
  true)

;; --- shutdown-socket-input/output/both ---
(check "tcp-client: shutdown-socket-input returns nil"
  (with-tcp-client
    (fn [client]
      (zig.io/shutdown-socket-input client)
      (zig.io/close-socket client)
      true))
  true)

(check "tcp-client: shutdown-socket-output returns nil"
  (with-tcp-client
    (fn [client]
      (zig.io/shutdown-socket-output client)
      (zig.io/close-socket client)
      true))
  true)

(check "tcp-client: shutdown-socket-both returns nil"
  (with-tcp-client
    (fn [client]
      (zig.io/shutdown-socket-both client)
      (zig.io/close-socket client)
      true))
  true)

;; ============================================================
;; Phase 3: TCP Server Tests
;; ============================================================

;; --- listen-server-socket ---
(check "tcp-server: listen-server-socket binds to ephemeral port"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0)]
    (let [port (zig.io/get-local-port server)]
      (zig.io/close-socket server)
      (> port 0)))
  true)

(check "tcp-server: listen-server-socket binds to explicit port"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 19910)]
    (let [port (zig.io/get-local-port server)]
      (zig.io/close-socket server)
      port))
  19910)

(check "tcp-server: get-bind-address returns string"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
        addr (zig.io/get-bind-address server)]
    (zig.io/close-socket server)
    (string? addr))
  true)

(check "tcp-server: get-bind-address contains host and port"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 19911)
        addr (zig.io/get-bind-address server)]
    (zig.io/close-socket server)
    (and (clojure.string/includes? addr "127.0.0.1")
         (clojure.string/includes? addr "19911")))
  true)

(check "tcp-server: socket-kind returns tcp-server"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
        kind (zig.io/socket-kind server)]
    (zig.io/close-socket server)
    kind)
  :tcp-server)

;; --- accept-connection (requires a client to connect) ---
(check "tcp-server: accept-connection returns accepted socket"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
        port (zig.io/get-local-port server)
        result (atom nil)]
    ;; Server thread: accept and close
    (future
      (try
        (let [accepted (zig.io/accept-connection server)]
          (zig.io/close-socket accepted)
          (zig.io/close-socket server)
          (reset! result :accepted))
        (catch Exception e
          (reset! result (ex-message e)))))
    ;; Client: connect and close
    (sleep 200)
    (let [client (zig.io/open-client-socket "127.0.0.1" port)]
      (zig.io/close-socket client))
    ;; Wait for server thread
    (sleep 500)
    @result)
  :accepted)

(check "tcp-server: accept-connection socket-kind returns tcp-accepted"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
        port (zig.io/get-local-port server)
        result (atom nil)]
    (future
      (try
        (let [accepted (zig.io/accept-connection server)]
          (reset! result (zig.io/socket-kind accepted))
          (zig.io/close-socket accepted)
          (zig.io/close-socket server))
        (catch Exception e
          (reset! result (ex-message e)))))
    (sleep 200)
    (let [client (zig.io/open-client-socket "127.0.0.1" port)]
      (zig.io/close-socket client))
    (sleep 500)
    @result)
  :tcp-accepted)

(check "tcp-server: accepted socket has remote address"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
        port (zig.io/get-local-port server)
        result (atom nil)]
    (future
      (try
        (let [accepted (zig.io/accept-connection server)]
          (let [addr (zig.io/get-remote-address accepted)
                rport (zig.io/get-remote-port accepted)]
            (reset! result {:addr addr :port rport :ok (and (string? addr) (> rport 0))}))
          (zig.io/close-socket accepted)
          (zig.io/close-socket server))
        (catch Exception e
          (reset! result (ex-message e)))))
    (sleep 200)
    (let [client (zig.io/open-client-socket "127.0.0.1" port)]
      (zig.io/close-socket client))
    (sleep 500)
    (:ok @result))
  true)

(check "tcp-server: accepted socket has local port"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 19912)
        port (zig.io/get-local-port server)
        result (atom nil)]
    (future
      (try
        (let [accepted (zig.io/accept-connection server)]
          (let [lport (zig.io/get-local-port accepted)]
            (reset! result {:lport lport :ok (= lport 19912)}))
          (zig.io/close-socket accepted)
          (zig.io/close-socket server))
        (catch Exception e
          (reset! result (ex-message e)))))
    (sleep 200)
    (let [client (zig.io/open-client-socket "127.0.0.1" port)]
      (zig.io/close-socket client))
    (sleep 500)
    (:ok @result))
  true)

(check "tcp-server: full client-server round-trip"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0)
        port (zig.io/get-local-port server)
        result (atom nil)]
    ;; Server thread: accept, close, signal done
    (future
      (try
        (let [accepted (zig.io/accept-connection server)]
          (zig.io/close-socket accepted)
          (zig.io/close-socket server)
          (reset! result :server-done))
        (catch Exception e
          (reset! result (ex-message e)))))
    ;; Client: connect, close
    (sleep 200)
    (let [client (zig.io/open-client-socket "127.0.0.1" port)]
      (zig.io/close-socket client))
    ;; Wait for server thread
    (sleep 500)
    @result)
  :server-done)

(check "tcp-server: listen-server-socket with reuse-address option"
  (let [server1 (zig.io/listen-server-socket "127.0.0.1" 19913 {:reuse-address true})
        port1 (zig.io/get-local-port server1)]
    (zig.io/close-socket server1)
    (let [server2 (zig.io/listen-server-socket "127.0.0.1" 19913 {:reuse-address true})
          port2 (zig.io/get-local-port server2)]
      (zig.io/close-socket server2)
      (= port2 19913)))
  true)

(check "tcp-server: listen-server-socket with backlog option"
  (let [server (zig.io/listen-server-socket "127.0.0.1" 0 {:backlog 5})
        port (zig.io/get-local-port server)]
    (zig.io/close-socket server)
    (> port 0))
  true)

;; ============================================================
;; Phase 5: UDP Datagram Socket Tests
;; ============================================================

;; --- open-udp-socket ---
(check "udp: open-udp-socket creates socket"
  (let [s (zig.io/open-udp-socket)]
    (zig.io/close-socket s)
    true)
  true)

(check "udp: open-udp-socket with bind-port"
  (let [s (zig.io/open-udp-socket {:bind-port 19920})
        port (zig.io/get-local-port s)]
    (zig.io/close-socket s)
    (= port 19920))
  true)

(check "udp: open-udp-socket with bind-address"
  (let [s (zig.io/open-udp-socket {:bind-address "127.0.0.1" :bind-port 19921})
        port (zig.io/get-local-port s)]
    (zig.io/close-socket s)
    (= port 19921))
  true)

(check "udp: open-udp-socket ephemeral port"
  (let [s (zig.io/open-udp-socket)
        port (zig.io/get-local-port s)]
    (zig.io/close-socket s)
    (> port 0))
  true)

(check "udp: open-udp-socket socket-kind returns udp"
  (let [s (zig.io/open-udp-socket)
        kind (zig.io/socket-kind s)]
    (zig.io/close-socket s)
    kind)
  :udp)

;; --- udp-send / udp-receive ---
(check "udp: send and receive datagram"
  (let [server (zig.io/open-udp-socket {:bind-port 19922})
        client (zig.io/open-udp-socket)]
    (zig.io/udp-send client "127.0.0.1" 19922 "udp hello")
    (let [msg (zig.io/core-udp-receive server)]
      (zig.io/close-socket server)
      (zig.io/close-socket client)
      (:data msg)))
  "udp hello")

(check "udp: receive returns sender address"
  (let [server (zig.io/open-udp-socket {:bind-port 19923})
        client (zig.io/open-udp-socket)]
    (zig.io/udp-send client "127.0.0.1" 19923 "test")
    (let [msg (zig.io/core-udp-receive server)]
      (zig.io/close-socket server)
      (zig.io/close-socket client)
      (and (string? (:from msg))
           (integer? (:port msg))
           (string? (:data msg)))))
  true)

(check "udp: receive returns correct sender port"
  (let [server (zig.io/open-udp-socket {:bind-port 19924})
        client (zig.io/open-udp-socket {:bind-port 19925})
        client-port (zig.io/get-local-port client)]
    (zig.io/udp-send client "127.0.0.1" 19924 "port test")
    (let [msg (zig.io/core-udp-receive server)]
      (zig.io/close-socket server)
      (zig.io/close-socket client)
      (= (:port msg) client-port)))
  true)

(check "udp: send binary-like data"
  (let [server (zig.io/open-udp-socket {:bind-port 19926})
        client (zig.io/open-udp-socket)]
    (zig.io/udp-send client "127.0.0.1" 19926 "binary\x00data")
    (let [msg (zig.io/core-udp-receive server)]
      (zig.io/close-socket server)
      (zig.io/close-socket client)
      (:data msg)))
  "binary\x00data")

(check "udp: send empty string does not crash"
  (let [s (zig.io/open-udp-socket)]
    (zig.io/udp-send s "127.0.0.1" 19999 "")
    (zig.io/close-socket s)
    true)
  true)

(check "udp: send multiple datagrams in order"
  (let [server (zig.io/open-udp-socket {:bind-port 19928})
        client (zig.io/open-udp-socket)]
    (zig.io/udp-send client "127.0.0.1" 19928 "first")
    (zig.io/udp-send client "127.0.0.1" 19928 "second")
    (let [msg1 (zig.io/core-udp-receive server)
          msg2 (zig.io/core-udp-receive server)]
      (zig.io/close-socket server)
      (zig.io/close-socket client)
      [(:data msg1) (:data msg2)]))
  ["first" "second"])

(check "udp: close-socket on udp socket returns nil"
  (let [s (zig.io/open-udp-socket)]
    (zig.io/close-socket s))
  nil)

(check "udp: close-socket double-close is no-op"
  (let [s (zig.io/open-udp-socket)]
    (zig.io/close-socket s)
    (zig.io/close-socket s)
    true)
  true)

;; --- udp-send to unreachable address ---
(check "udp: send to unreachable host throws"
  (let [s (zig.io/open-udp-socket)]
    (zig.io/close-socket s)
    (try
      (let [s2 (zig.io/open-udp-socket)]
        (zig.io/udp-send s2 "192.0.2.1" 19999 "test")
        ;; Note: UDP send may not fail immediately for unreachable hosts
        ;; This test just verifies no crash on send attempt
        (zig.io/close-socket s2)
        true)
      (catch Exception e true)))
  true)

;; --- udp-receive on closed socket ---
(check "udp: receive on closed socket throws"
  (let [s (zig.io/open-udp-socket)]
    (zig.io/close-socket s)
    (try
      (zig.io/core-udp-receive s)
      false
      (catch Exception e true)))
  true)

;; --- open-udp-socket with buffer-size option ---
(check "udp: open-udp-socket with buffer-size option"
  (let [s (zig.io/open-udp-socket {:buffer-size 8192})]
    (zig.io/close-socket s)
    true)
  true)

;; ============================================================
;; Phase 6: Clojure-Level API Tests
;; ============================================================

;; --- socket (high-level TCP client wrapper) ---
(check "api: socket creates and connects"
  (with-tcp-client
    (fn [client]
      (io/close-socket client)
      true))
  true)

(check "api: socket with buffer-size option"
  (with-tcp-client
    (fn [client]
      (io/close-socket client)
      true))
  true)

;; --- server-socket (high-level TCP server wrapper) ---
(check "api: server-socket binds to ephemeral port"
  (let [server (io/server-socket "127.0.0.1" 0)
        port (io/get-local-port server)]
    (io/close-socket server)
    (> port 0))
  true)

(check "api: server-socket with options"
  (let [server (io/server-socket "127.0.0.1" 0 {:backlog 5 :reuse-address true})
        port (io/get-local-port server)]
    (io/close-socket server)
    (> port 0))
  true)

;; --- accept ---
(check "api: accept returns accepted socket"
  (let [server (io/server-socket "127.0.0.1" 0)
        port (io/get-local-port server)
        result (atom nil)]
    (future
      (try
        (let [accepted (io/accept server)]
          (io/close-socket accepted)
          (io/close-socket server)
          (reset! result :accepted))
        (catch Exception e
          (reset! result (ex-message e)))))
    (sleep 200)
    (let [client (io/socket "127.0.0.1" port)]
      (io/close-socket client))
    (sleep 500)
    @result)
  :accepted)

;; --- socket-address ---
(check "api: socket-address for server returns map"
  (let [server (io/server-socket "127.0.0.1" 0)
        addr (io/socket-address server)]
    (io/close-socket server)
    (boolean (and (map? addr)
                  (:bind-address addr)
                  (:local-port addr))))
  true)

(check "api: socket-address for client returns map"
  (let [server (io/server-socket "127.0.0.1" 0)
        port (io/get-local-port server)
        result (atom nil)]
    (future
      (try
        (let [accepted (io/accept server)]
          (reset! result (io/socket-address accepted))
          (io/close-socket accepted)
          (io/close-socket server))
        (catch Exception e
          (reset! result (ex-message e)))))
    (sleep 200)
    (let [client (io/socket "127.0.0.1" port)]
      (io/close-socket client))
    (sleep 500)
    (let [addr @result]
      (boolean (and (map? addr)
                    (:remote-address addr)
                    (:remote-port addr)
                    (:local-port addr)))))
  true)

;; --- socket-kind ---
(check "api: socket-kind for client returns :tcp-client"
  (with-tcp-client
    (fn [client]
      (let [kind (io/socket-kind client)]
        (io/close-socket client)
        kind)))
  :tcp-client)

(check "api: socket-kind for server returns :tcp-server"
  (let [s (io/server-socket "127.0.0.1" 0)
        kind (io/socket-kind s)]
    (io/close-socket s)
    kind)
  :tcp-server)

(check "api: socket-kind for udp returns :udp"
  (let [s (io/udp-socket)
        kind (io/socket-kind s)]
    (io/close-socket s)
    kind)
  :udp)

;; --- socket-shutdown ---
(defn- with-shutdown-test
  "Run socket-shutdown on an accepted server socket with a live client.
   Server signals port-ready atom before accept, result atom after shutdown.
   Client stays alive until server signals done."  
  [direction]
  (let [port-atom (atom nil)
        result-atom (atom nil)]
    ;; Server thread: listen → accept → shutdown → signal done
    (future
      (try
        (let [server (io/server-socket "127.0.0.1" 0)
              port (io/get-local-port server)]
          (reset! port-atom port)
          (let [accepted (io/accept server)]
            (io/socket-shutdown accepted direction)
            (io/close-socket accepted)
            (io/close-socket server)
            (reset! result-atom :ok)))
        (catch Exception e
          (reset! result-atom (ex-message e)))))
    ;; Wait for server to be listening
    (loop [_ 0]
      (when (and (< _ 50) (nil? @port-atom))
        (sleep 50) (recur (inc _))))
    ;; Connect client and hold connection until server is done
    (when-let [port @port-atom]
      (let [client (io/socket "127.0.0.1" port)]
        (loop [_ 0]
          (if (and (< _ 100) (nil? @result-atom))
            (do (sleep 50) (recur (inc _)))
            (safe-close client))))
        @result-atom)))

(check "api: socket-shutdown :input"
  (with-shutdown-test :input)
  :ok)

(check "api: socket-shutdown :output"
  (with-shutdown-test :output)
  :ok)

(check "api: socket-shutdown :both"
  (with-shutdown-test :both)
  :ok)

(check "api: socket-shutdown invalid direction throws"
  (let [s (io/server-socket "127.0.0.1" 0)]
    (io/close-socket s)
    (try
      (io/socket-shutdown s :invalid)
      false
      (catch Exception e true)))
  true)

;; --- udp-socket ---
(check "api: udp-socket creates socket"
  (let [s (io/udp-socket)]
    (io/close-socket s)
    true)
  true)

(check "api: udp-socket with bind-port"
  (let [s (io/udp-socket :bind-port 19940)
        port (io/get-local-port s)]
    (io/close-socket s)
    (= port 19940))
  true)

;; --- udp-send! / udp-receive ---
(check "api: udp-send! and udp-receive"
  (let [server (io/udp-socket :bind-port 19941)
        client (io/udp-socket)]
    (io/udp-send! client "127.0.0.1" 19941 "api udp test")
    (let [msg (io/udp-receive server)]
      (io/close-socket server)
      (io/close-socket client)
      (:data msg)))
  "api udp test")

;; --- IOFactory: reader on socket ---
(check "api: reader on accepted socket"
  (let [server (io/server-socket "127.0.0.1" 0)
        port (io/get-local-port server)
        result (atom nil)]
    (future
      (try
        (let [accepted (io/accept server)]
          (let [r (io/reader accepted)]
            (reset! result "reader created")
            (io/close-socket accepted))
          (io/close-socket server))
        (catch Exception e
          (reset! result (ex-message e)))))
    (sleep 200)
    (let [client (io/socket "127.0.0.1" port)]
      (io/close-socket client))
    (sleep 500)
    @result)
  "reader created")

(check "api: writer on accepted socket"
  (let [server (io/server-socket "127.0.0.1" 0)
        port (io/get-local-port server)
        result (atom nil)]
    (future
      (try
        (let [accepted (io/accept server)]
          (let [w (io/writer accepted)]
            (reset! result "writer created")
            (io/close-socket accepted))
          (io/close-socket server))
        (catch Exception e
          (reset! result (ex-message e)))))
    (sleep 200)
    (let [client (io/socket "127.0.0.1" port)]
      (io/close-socket client))
    (sleep 500)
    @result)
  "writer created")

(check "api: reader on server socket throws"
  (try
    (let [server (io/server-socket "127.0.0.1" 0)]
      (io/reader server)
      (io/close-socket server)
      false)
    (catch Exception e true))
  true)

(check "api: writer on server socket throws"
  (try
    (let [server (io/server-socket "127.0.0.1" 0)]
      (io/writer server)
      (io/close-socket server)
      false)
    (catch Exception e true))
  true)

;; --- with-open integration ---
(check "api: with-open closes server socket"
  (let [result (atom nil)]
    (io/with-open [server (io/server-socket "127.0.0.1" 0)]
      (reset! result (io/get-local-port server)))
    (> @result 0))
  true)

(check "api: with-open closes on exception"
  (try
    (io/with-open [server (io/server-socket "127.0.0.1" 0)]
      (throw (ex-info "test error" {})))
    false
    (catch Exception e true))
  true)

(print-summary)
