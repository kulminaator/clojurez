;; Debug test - just connect, no read/write
(load-file "tests/clj/clj_test_helper.clj")

(println "Test: just connect, no I/O")
(let [r (with-echo-server
           (fn [client]
             (println "Client: connected, closing...")
             :connected)
           (fn [accepted]
             (println "Server: accepted, closing...")
             :server-done))]
  (println "Result:" r))

(println "Done")
