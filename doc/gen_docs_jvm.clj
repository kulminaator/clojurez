;; Documentation generator for ClojureZ (JVM Clojure version)
;; Run: clojure doc/gen_docs_jvm.clj
(ns doc.gen-docs-jvm)

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
  (sort (map str (all-ns))))

(defn ns-link [name]
  (str "- [" name "](" (replace-dots name) ".md)"))

(defn build-index [names]
  (let [links (clojure.string/join "\n" (map ns-link (filter #(not= % "user") names)))]
    (str "# ClojureZ API Reference\n\n"
         "Auto-generated documentation.\n\n"
         "## Namespaces\n\n"
         links "\n\n"
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

(defn var-doc [v]
  (:doc (meta v)))

(defn get-docs [interns]
  (filter (fn [k]
            (let [v (get interns k)]
              (and (not (is-private? k)) (var-doc v))))
          (keys interns)))

(defn build-ns-content [ns-name interns]
  (let [docs (get-docs interns)
        entries (map (fn [k] (doc-entry k (var-doc (get interns k)))) docs)]
    (str "# " ns-name "\n\n" (clojure.string/join "" entries))))

(defn write-ns-doc [ns-name ns-obj]
  (when ns-obj
    (let [file-path (str output-dir "/" (replace-dots ns-name) ".md")
          interns (ns-interns ns-obj)
          ks (if interns (keys interns) '())]
      (println (str "Processing " ns-name " (" (count ks) " entries)..."))
      (spit file-path (build-ns-content ns-name interns))
      (println (str "Wrote " file-path)))))

(defn process-namespaces [names]
  (doseq [ns-name (filter #(not= % "user") names)]
    (let [ns-obj (find-namespace ns-name)]
      (write-ns-doc ns-name ns-obj))))

(defn -main []
  (println "Generating documentation...")
  (let [names (ns-names)]
    (println (str "Namespaces: " names))
    (write-index names)
    (write-special-forms)
    (process-namespaces names)
    (println "\nDocumentation generation complete.")))

(-main)
