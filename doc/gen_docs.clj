;; Documentation generator for ClojureZ
;; Run: ./zig-out/bin/clojurez doc/gen_docs.clj
(ns doc.gen-docs)

(def output-dir "doc")

(defn find-namespace [name]
  (find-ns (read-string name)))

(defn replace-dots [s]
  (clojure.string/replace s "." "-"))

(defn is-private? [sym]
  (let [name-str (str sym)]
    (or (clojure.string/starts-with? name-str "-")
        (clojure.string/ends-with? name-str "-helper")
        (clojure.string/ends-with? name-str "*"))))

(defn ns-names []
  (sort (map (fn [ns-obj] (str (:name ns-obj))) (all-ns))))

(defn ns-link [name]
  (str "- [" name "](" (replace-dots name) ".md)"))

(defn build-index [names]
  (let [filtered (filter #(not= % "user") names)
        links (map ns-link filtered)]
    (str "# ClojureZ API Reference\n\n"
         "Auto-generated documentation.\n\n"
         "## Namespaces\n\n"
         (clojure.string/join "\n" (vec links)) "\n\n"
         "## Special Forms\n\n"
         "- [Special Forms](special-forms.md)\n\n")))

(defn write-index [names]
  (spit (str output-dir "/index.md") (build-index names))
  (println "Wrote doc/index.md"))

(defn write-special-forms []
  (spit (str output-dir "/special-forms.md")
        (str "# Special Forms\n\n"
             "def, defn, fn, if, let, loop, recur, do, quote, when,\n"
             "ns, lazy-seq, and, or, cond, set!, var, deref, quit, exit\n"))
  (println "Wrote doc/special-forms.md"))

(defn doc-entry [k doc-str]
  (str "\n---\n\n## " k "\n\n" doc-str "\n"))

(defn write-ns-doc [ns-name ns-obj]
  (when ns-obj
    (let [file-path (str output-dir "/" (replace-dots ns-name) ".md")
          interns (ns-interns ns-obj)
          ks (vec (keys interns))]
      (println (str "Processing " ns-name " (" (zig.core/count ks) " entries)..."))
      ;; Write header
      (spit file-path (str "# " ns-name "\n\n"))
      ;; Write each doc entry incrementally using builtins to avoid closure clone explosion
      (loop [i 0]
        (when (< i (zig.core/count ks))
          (let [k (zig.core/nth ks i)
                v (zig.core/get interns k)]
            (when (and (not (is-private? k)) (has-doc? v))
              (spit file-path (doc-entry k (get-doc v)) :append true))
            (recur (zig.core/plus i 1)))))
      (println (str "Wrote " file-path)))))

(defn process-namespaces [names]
  (doseq [ns-name (filter #(not= % "user") names)]
    (let [ns-obj (find-namespace ns-name)]
      (write-ns-doc ns-name ns-obj))))

(defn -main []
  (println "Generating documentation...")
  (make-parents output-dir)
  (let [names (ns-names)]
    (println (str "Namespaces: " names))
    (write-index names)
    (write-special-forms)
    (process-namespaces names)
    (println "\nDocumentation generation complete.")))

(-main)
