;; Basic test of with-echo-server helper
(load-file "tests/clj/clj_test_helper.clj")

;; Test 1: Simple connect and close
(println "Test 1: connect and close")
(let [r (with-echo-server (fn [client] "connected"))]
  (check "connect and close" r "connected"))

;; Test 2: Echo round-trip
(println "Test 2: echo round-trip")
(let [r (with-echo-server (fn [client]
             (zig.io/write-bytes client "hello world")
             (zig.io/read-bytes client 100)))]
  (check "echo round-trip" r "hello world"))

;; Test 3: Multiple writes and reads
(println "Test 3: multiple writes")
(let [r (with-echo-server (fn [client]
             (zig.io/write-bytes client "msg1")
             (let [r1 (zig.io/read-bytes client 100)]
               (zig.io/write-bytes client "msg2")
               (let [r2 (zig.io/read-bytes client 100)]
                 [r1 r2]))))]
  (check "multiple writes" r ["msg1" "msg2"]))

;; Test 4: Custom server body (server sends first)
(println "Test 4: custom server body")
(let [r (with-echo-server
           (fn [client]
             (zig.io/read-bytes client 100))
           (fn [accepted]
             (zig.io/write-string accepted "server says hi\n")
             (zig.io/read-bytes accepted 100)))]
  (check "custom server body" r "server says hi\n"))

;; Test 5: Client gets local port
(println "Test 5: client local port")
(let [r (with-echo-server (fn [client]
             (> (zig.io/get-local-port client) 0)))]
  (check "client local port" r true))

(print-summary)
