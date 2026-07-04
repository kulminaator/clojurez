;; Documentation generator for ClojureZ
;; Run: ./zig-out/bin/clojurez doc/gen_docs.clj
(ns doc.gen-docs)

(def output-dir "doc")
(def temp-prefix "/tmp/cljdoc_")

(defn find-namespace [name]
  (find-ns (read-string name)))

(defn replace-dots [s]
  (let [n (count s)
        chars (map (fn [i]
                     (let [ch (subs s i (inc i))]
                       (if (= ch ".") "-" ch)))
                   (range n))]
    (apply str (vec chars))))

(defn is-private? [sym]
  (let [name-str (str sym)]
    (or (clojure.string/starts-with? name-str "-")
        (clojure.string/ends-with? name-str "-helper")
        (clojure.string/ends-with? name-str "*"))))

(defn build-index [ns-names]
  (str "# ClojureZ API Reference\n\n"
       "Auto-generated documentation.\n\n## Namespaces\n\n"
       (clojure.string/join "\n"
         (map #(str "- [" % "](" (replace-dots %) ".md)")
              (filter #(not= % "user") ns-names)))
       "\n\n## Special Forms\n\n- [Special Forms](special-forms.md)\n\n"))

(defn -main []
  (println "Generating documentation...")
  (make-parents output-dir)
  (let [ns-names (sort (map (fn [ns-obj] (str (:name ns-obj))) (all-ns)))
        temp-files (atom [])]
    (println (str "Namespaces: " ns-names))
    ;; Write index
    (spit (str output-dir "/index.md") (build-index ns-names))
    (println "Wrote doc/index.md")
    ;; Write special forms
    (spit (str output-dir "/special-forms.md")
          (str "# Special Forms\n\n"
               "def, defn, fn, if, let, loop, recur, do, quote, when,\n"
               "ns, lazy-seq, and, or, cond, set!, var, deref, quit, exit\n"))
    (println "Wrote doc/special-forms.md")
    ;; Process each namespace
    (doseq [ns-name (filter #(not= % "user") ns-names)]
      (let [ns-obj (find-namespace ns-name)]
        (when ns-obj
          (let [file-path (str output-dir "/" (replace-dots ns-name) ".md")
                header-path (str temp-prefix ns-name "-header")
                interns (ns-interns ns-obj)
                ks (if interns (keys interns) '())]
            (println (str "Processing " ns-name " (" (count ks) " entries)..."))
            ;; Write header to temp file
            (spit header-path (str "# " ns-name "\n\n"))
            (swap! temp-files conj header-path)
            ;; Write each function doc to a separate temp file
            (doseq [k ks
                    :let [v (get interns k)]
                    :when (and (not (is-private? k)) (has-doc? v))]
              (let [doc-str (get-doc v)
                    entry-path (str temp-prefix ns-name "-" (count @temp-files))]
                (spit entry-path (str "\n---\n\n## " k "\n\n" doc-str "\n"))
                (swap! temp-files conj entry-path)))
            ;; Concatenate all temp files into final file
            (loop [files @temp-files
                   content (str "# " ns-name "\n\n")]
              (if (empty? files)
                (do
                  (spit file-path content)
                  (println (str "Wrote " file-path))
                  ;; Clean up temp files
                  (doseq [f @temp-files]
                    (try (java.io.File. f) (catch _ nil))))
                (let [f (first files)]
                  (recur (rest files)
                         (str content (if (file-exists? f) (slurp f) "")))))))
          ;; Reset temp files for next namespace
          (reset! temp-files [])))))
    (println "\nDocumentation generation complete.")))

(-main)
