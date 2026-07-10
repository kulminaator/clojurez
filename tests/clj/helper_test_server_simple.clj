;; Simple test server - reads raw bytes, not lines
(require '[zig.io :as io])

(println "Starting TCP echo server on port 7799...")
(let [server (io/server-socket "127.0.0.1" 7799)]
  (println "Server listening. Connect with: curl -v http://127.0.0.1:7799/")
  (let [accepted (io/accept server)]
    (println "Client connected!")
    (try
      ;; Read raw bytes (not line-based)
      (let [data (io/read-bytes accepted 1024)]
        (println "Server received bytes: " data)
        (when data
          (io/write-bytes accepted (str "Echo: " data))
          (println "Server echoed back.")))
      (catch Exception e
        (println "Error: " (.getMessage e))))
    (io/close-socket accepted)
    (io/close-socket server)))
