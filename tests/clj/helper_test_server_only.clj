;; Test server side only - uses curl as client
;; Run: ./zig-out/bin/clojurez tests/clj/helper_test_server_only.clj
;; Then in another terminal: curl -v http://127.0.0.1:7799/

(require '[zig.io :as io])

(println "Starting TCP echo server on port 7799...")
(let [server (io/server-socket "127.0.0.1" 7799)]
  (println "Server listening on port 7799. Connect with: curl -v http://127.0.0.1:7799/")
  (println "Press Ctrl+C to stop.")
  (loop []
    (let [accepted (io/accept server)]
      (println "Client connected!")
      (try
        (loop [line (io/read-line-stream accepted)]
          (when line
            (println "Server received: " line)
            (io/write-string accepted (str "Echo: " line "\n"))
            (recur (io/read-line-stream accepted))))
        (println "Client disconnected.")
        (catch Exception e
          (println "Error: " (.getMessage e))))
      (io/close-socket accepted)
      (recur))))
