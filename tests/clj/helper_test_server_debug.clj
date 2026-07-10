;; Debug server - prints timing info
(require '[zig.io :as io])

(defn now [] (zig.core/nano-time))

(println "Starting TCP echo server on port 7799...")
(let [server (io/server-socket "127.0.0.1" 7799)]
  (println "Server listening at" (now))
  (let [accepted (io/accept server)]
    (println "Client connected at" (now))
    (try
      (println "About to read at" (now))
      (let [data (io/read-bytes accepted 1024)]
        (println "Read completed at" (now))
        (println "Server received: " data)
        (when data
          (println "About to write at" (now))
          (io/write-bytes accepted (str "Echo: " data))
          (println "Write completed at" (now))))
      (catch Exception e
        (println "Error: " (.getMessage e))))
    (io/close-socket accepted)
    (io/close-socket server)))
