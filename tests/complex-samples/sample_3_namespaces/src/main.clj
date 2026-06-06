(ns main
  (:require [hello.hello :as h]
            [hello.clojure :as c]
            [hello.world :as w]))

(defn -main []
  (println (str (h/get-hello) " " 
                (c/get-clojure) " " 
                (w/get-world))))
