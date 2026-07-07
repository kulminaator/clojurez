;; zig.io — I/O utilities for ClojureZ
;; Inspired by clojure.java.io and clojure.java.shell
;;
;; This namespace provides:
;;   - Protocol-based I/O abstractions (Closeable, IOFactory, Readable, Writable)
;;   - File path manipulation (file, as-file, as-relative-path)
;;   - Stream creation (reader, writer, input-stream, output-stream)
;;   - Data copying (copy, line-seq)
;;   - Resource management (with-open)
;;   - Subprocess execution (sh, with-sh-dir, with-sh-env)

(ns zig.io
  "I/O utilities for ClojureZ")

;; ============================================================
;; Protocols
;; ============================================================

(defprotocol Closeable
  "Unified resource cleanup for files, streams, and processes."
  (-close [this]))

(defprotocol IOFactory
  "Factory functions that create ready-to-use I/O handles on top of
   anything that can be converted to the requested kind of handle.

   Common options include:
     :append      true to open stream in append mode
     :encoding    string name of encoding to use, e.g. \"UTF-8\"
     :buffer-size integer buffer size in bytes"
  (make-reader [x opts]
    "Creates a character reader handle.")
  (make-writer [x opts]
    "Creates a character writer handle.")
  (make-input-stream [x opts]
    "Creates a byte input stream handle.")
  (make-output-stream [x opts]
    "Creates a byte output stream handle."))

(defprotocol Coercions
  "Coerce between various resource-namish things."
  (as-file [x]
    "Coerce argument to a file map {:path ... :name ... :dir ...}."))

(defprotocol Readable
  "Read data from a handle."
  (read-chunk [reader opts]
    "Read a chunk of data. Returns a string or nil on EOF."))

(defprotocol Writable
  "Write data to a handle."
  (write-chunk [writer chunk]
    "Write a chunk of data. Returns nil.")
  (flush [writer]
    "Flush buffered data. Returns nil."))

;; ============================================================
;; Coercions implementation
;; ============================================================

(defn- split-path
  "Split a path string into directory and name components."
  [path]
  (let [last-slash (clojure.string/last-index-of path \/)]
    (if last-slash
      {:dir (subs path 0 last-slash)
       :name (subs path (inc last-slash))}
      {:dir "."
       :name path})))

(extend-protocol Coercions
  :nil
  (as-file [_] nil)

  :string
  (as-file [s]
    (let [parts (split-path s)]
      (merge {:path s} parts)))

  ;; File maps pass through
  :map
  (as-file [x]
    (if (and (map? x) (:path x))
      x
      (let [parts (split-path (str x))]
        (merge {:path (str x)} parts)))))

;; ============================================================
;; IOFactory extensions — wire Clojure protocols to Zig built-ins
;; ============================================================

(extend-protocol IOFactory
  :string
  (make-reader [path opts]
    (zig.io/open-reader path opts))
  (make-writer [path opts]
    (zig.io/open-writer path opts))
  (make-input-stream [path opts]
    (zig.io/open-input-stream path opts))
  (make-output-stream [path opts]
    (zig.io/open-output-stream path opts)))

;; ============================================================
;; Readable/Writable extensions for wrapped handles
;; ============================================================

(extend-protocol Readable
  :wrapped
  (read-chunk [reader _opts]
    (zig.io/read-line-stream reader)))

(extend-protocol Writable
  :wrapped
  (write-chunk [writer chunk]
    (zig.io/write-string writer chunk))
  (flush [writer]
    (zig.io/flush-stream writer)))

;; ============================================================
;; Closeable extension for wrapped handles
;; ============================================================

(extend-protocol Closeable
  :wrapped
  (-close [handle]
    (zig.io/close-stream handle)))

;; ============================================================
;; File path utilities
;; ============================================================

(defn file
  "Returns a file map, passing each arg to as-file.  Multiple-arg
   versions treat the first argument as parent and subsequent args as
   children relative to the parent.

   Returns a map: {:path \"...\" :name \"...\" :dir \"...\"}"
  ([arg]
     (as-file arg))
  ([parent child]
     (let [p (as-file parent)
           ppath (or (:path p) (str p))]
       (as-file (str ppath "/" child))))
  ([parent child & more]
     (reduce file (file parent child) more)))

(defn as-relative-path
  "Take an as-file-able thing and return a string if it is
   a relative path, else throw an exception."
  [x]
  (let [f (as-file x)
        p (:path f)]
    (if (and p (> (alength p) 0) (char= (char-at p 0) \/))
      (throw (js/Error. (str f " is not a relative path")))
      p)))

(defn- char-at
  "Get character at index in string."
  [s i]
  (subs s i (inc i)))

(defn- alength
  "Get length of string."
  [^String s]
  (count s))

;; ============================================================
;; Stream creation functions
;; ============================================================

(defn reader
  "Attempts to coerce its argument into an open reader handle.

   If argument is a String, it is treated as a file path.

   Options:
     :encoding    character encoding (default \"UTF-8\")
     :buffer-size buffer size in bytes (default 4096)"
  [x & opts]
  (let [opts-map (when opts (apply hash-map opts))]
    (make-reader x opts-map)))

(defn writer
  "Attempts to coerce its argument into an open writer handle.

   If argument is a String, it is treated as a file path.

   Options:
     :encoding    character encoding (default \"UTF-8\")
     :append      true to append (default false)
     :buffer-size buffer size in bytes (default 4096)"
  [x & opts]
  (let [opts-map (when opts (apply hash-map opts))]
    (make-writer x opts-map)))

(defn input-stream
  "Attempts to coerce its argument into an open input stream handle.

   If argument is a String, it is treated as a file path.

   Options:
     :buffer-size buffer size in bytes (default 4096)"
  [x & opts]
  (let [opts-map (when opts (apply hash-map opts))]
    (make-input-stream x opts-map)))

(defn output-stream
  "Attempts to coerce its argument into an open output stream handle.

   If argument is a String, it is treated as a file path.

   Options:
     :append      true to append (default false)
     :buffer-size buffer size in bytes (default 4096)"
  [x & opts]
  (let [opts-map (when opts (apply hash-map opts))]
    (make-output-stream x opts-map)))

;; ============================================================
;; Copy and line-seq
;; ============================================================

(defn copy
  "Copies data from input to output. Returns nil.

   Input may be a reader handle, input stream handle, or a file path string.
   Output may be a writer handle, output stream handle, or a file path string.

   Options:
     :buffer-size  buffer size to use (default 4096)
     :encoding     encoding for char/binary conversion (default \"UTF-8\")"
  [input output & opts]
  (let [opts-map (when opts (apply hash-map opts))
        buf-size (or (:buffer-size opts-map) 4096)]
    ;; This delegates to the Zig builtin which handles the actual copy
    (zig.core/copy input output opts-map)))

(defn line-seq
  "Returns a lazy sequence of lines from a reader handle.
   Each line is a string without the newline character."
  [reader]
  ((fn next-line []
     (let [line (read-chunk reader {})]
       (when line (cons line (lazy-seq (next-line))))))))

;; ============================================================
;; Resource management
;; ============================================================

(defmacro with-open
  "bindings => [name1 init1 name2 init2 ...]

  Evaluates body in a let form where name1 is
  bound to the result of init1, name2 to the result of init2, etc.
  After body is evaluated, each name that implements Closeable
  will have -close called on it (in reverse order), regardless of
  whether body completed normally or exited via an exception."
  [bindings & body]
  (let [pairs (partition 2 bindings)
        names (map first pairs)
        inits (map second pairs)]
    (reduce
     (fn [body [name init]]
       `(let [~name ~init]
          (try
            ~body
            (finally
              (if (satisfies? Closeable ~name)
                (-close ~name)
                nil)))))
     `(do ~@body)
     (reverse pairs))))

;; ============================================================
;; Subprocess execution (sh)
;; ============================================================

(def *sh-dir* nil)
(def *sh-env* nil)

(defmacro with-sh-dir
  "Sets the directory for use with sh."
  [dir & forms]
  `(binding [*sh-dir* ~dir]
     ~@forms))

(defmacro with-sh-env
  "Sets the environment for use with sh."
  [env & forms]
  `(binding [*sh-env* ~env]
     ~@forms))

(defn- parse-sh-args
  "Separate command strings from keyword options."
  [args]
  (let [default-opts {:out-enc "UTF-8" :in-enc "UTF-8" :dir *sh-dir* :env *sh-env*}
        args-v (vec args)
        ;; Find the index of the first non-string element (start of options)
        idx (loop [i 0]
              (if (and (< i (count args-v)) (string? (nth args-v i)))
                (recur (inc i))
                i))
        cmd (vec (take idx args-v))
        opts (vec (drop idx args-v))]
    [cmd (merge default-opts (apply hash-map opts))]))

(defn sh
  "Launches a sub-process with the given command and arguments.

   Arguments before any keyword are treated as command strings.
   Keyword options:

   :in      data to feed to stdin (String)
   :in-enc  encoding for input (default \"UTF-8\")
   :out-enc encoding for output (default \"UTF-8\", or :bytes for raw bytes)
   :env     environment map for the subprocess
   :dir     working directory for the subprocess

   Returns a map:
     :exit => exit code (integer)
     :out  => stdout (String or byte vector)
     :err  => stderr (String)"
  [& args]
  (let [[cmd opts] (parse-sh-args args)]
    (zig.io/sh-execute cmd opts)))

;; ============================================================
;; Async subprocess execution (streaming I/O)
;; ============================================================

(defn sh-stream
  "Spawns a subprocess and returns a process handle for async I/O.

   The handle allows incremental reading of stdout/stderr and
   writing to stdin. Use sh-wait to wait for completion and get
   the exit code, or sh-kill to terminate the process.

   Arguments before any keyword are treated as command strings.
   Keyword options are passed through (currently not fully used).

   Returns a wrapped process handle."  [& args]
  (let [[cmd opts] (parse-sh-args args)]
    (zig.io/sh-execute-stream cmd opts)))

(defn sh-out
  "Read available output from a process handle's stdout.

   Returns a string of whatever data is available, or nil if
   the pipe is closed and empty.

   max-bytes (optional) limits the amount read, default 4096."  ([handle]
     (zig.io/sh-read-output handle))
    ([handle max-bytes]
     (zig.io/sh-read-output handle max-bytes)))

(defn sh-err
  "Read available output from a process handle's stderr.

   Returns a string of whatever data is available, or nil if
   the pipe is closed and empty.

   max-bytes (optional) limits the amount read, default 4096."  ([handle]
     (zig.io/sh-read-error handle))
    ([handle max-bytes]
     (zig.io/sh-read-error handle max-bytes)))

(defn sh-in
  "Write data to a process handle's stdin.

   Returns nil."  [handle data]
  (zig.io/sh-write-input handle data))

(defn sh-close-in
  "Close the stdin pipe of a process handle, signaling EOF to
   the subprocess.

   Returns nil."  [handle]
  (zig.io/sh-close-input handle))

(defn sh-wait
  "Wait for a subprocess to finish and return its exit code.

   Closes all pipes and cleans up resources. Returns the exit code
   as an integer."  [handle]
  (zig.core/sh-wait handle))

(defn sh-kill
  "Kill a running subprocess.

   Terminates the process and cleans up resources. Returns nil."  [handle]
  (zig.core/sh-kill handle))
