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

(defn format-arglists [arglists]
  "Format arglists as a single line: ((a b) (a b & rest)) -> [(a b) (a b & rest)]"
  (when arglists
    (str "[" (clojure.string/join " " (map str arglists)) "]")))

(defn doc-entry [k arglists doc-str]
  (let [args-line (when arglists (str arglists "\n\n"))]
    (str "\n---\n\n## " k "\n\n" (or args-line "") doc-str "\n")))

(defn anchor-link [sym]
  "Create a markdown anchor for a symbol heading." (str "#" (str sym)))

(defn toc-entry [sym]
  (str "- [" sym "](" (anchor-link sym) ")"))

(defn write-ns-doc [ns-name ns-obj]
  (when ns-obj
    (let [file-path (str output-dir "/" (replace-dots ns-name) ".md")
          interns (ns-interns ns-obj)
          ;; Get public symbols with docs, sorted alphabetically
          ks (vec (keys interns))
          public-with-docs (sort (filter (fn [k]
                                            (and (not (is-private? k))
                                                 (has-doc? (zig.core/get interns k))))
                                          ks))]
      (println (str "Processing " ns-name " (" (zig.core/count public-with-docs) " public entries)..."))
      ;; Write header + table of contents
      (let [toc-lines (map toc-entry public-with-docs)
            toc (str "\n## Table of Contents\n\n"
                     (clojure.string/join "\n" (vec toc-lines)) "\n")]
        (spit file-path (str "# " ns-name "\n\n" toc)))
      ;; Write each doc entry incrementally using builtins to avoid closure clone explosion
      (loop [i 0]
        (when (< i (zig.core/count public-with-docs))
          (let [k (zig.core/nth public-with-docs i)
                v (zig.core/get interns k)
                args (format-arglists (get-arglists v))]
            (spit file-path (doc-entry k args (get-doc v)) :append true)
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
