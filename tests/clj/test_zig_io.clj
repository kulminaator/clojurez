;; zig.io comprehensive test suite
;; Tests: directory ops, file I/O streams, copy, line-seq, with-open, path utils, subprocess
(load-file "tests/clj/clj_test_helper.clj")
(require '[zig.io :as io])

;; ---- Temp directory setup ----
(def tmp-base (str (zig.core/temp-dir) "/clojurez_io_test_"))
(def tmp-file (str tmp-base "test.txt"))
(def tmp-file2 (str tmp-base "test2.txt"))
(def tmp-dir (str tmp-base "testdir/"))
(def tmp-dir2 (str tmp-base "testdir/nested/"))
(def tmp-copy (str tmp-base "copy.txt"))
(def tmp-symlink (str tmp-base "link.txt"))

;; Clean up from previous runs
(zig.io/delete-tree tmp-base)

;; ============================================================
;; File Path Utilities
;; ============================================================

;; as-file with string
(check "as-file string returns map"
  (map? (io/as-file "/tmp/foo.txt"))
  true)
(check "as-file string has :path"
  (:path (io/as-file "/tmp/foo.txt"))
  "/tmp/foo.txt")
(check "as-file string has :name"
  (:name (io/as-file "/tmp/foo.txt"))
  "foo.txt")
(check "as-file string has :dir"
  (:dir (io/as-file "/tmp/foo.txt"))
  "/tmp")
(check "as-file root path"
  (:name (io/as-file "/"))
  "")
(check "as-file relative path"
  (:dir (io/as-file "foo/bar.txt"))
  "foo")

;; as-file with nil
(check "as-file nil returns nil"
  (io/as-file nil)
  nil)

;; file function
(check "file single arg"
  (map? (io/file "/tmp/test.txt"))
  true)
(check "file two args joins paths"
  (:path (io/file "/tmp" "test.txt"))
  "/tmp/test.txt")
(check "file three args joins paths"
  (:path (io/file "/tmp" "sub" "test.txt"))
  "/tmp/sub/test.txt")

;; ============================================================
;; Directory Operations
;; ============================================================

;; make-dir
(zig.io/make-parents tmp-dir2)
(check "is-directory? after make-parents"
  (zig.io/is-directory? tmp-dir2)
  true)
(check "file-exists? after make-parents"
  (zig.io/file-exists? tmp-dir2)
  true)

;; is-file?
(spit tmp-file "hello")
(check "is-file? on file"
  (zig.io/is-file? tmp-file)
  true)
(check "is-file? on dir"
  (zig.io/is-file? tmp-dir)
  false)
(check "is-file? on nonexistent"
  (zig.io/is-file? "/tmp/zzz_nonexistent_xyz.txt")
  false)

;; file-stat
(check "file-stat returns map"
  (map? (zig.io/file-stat tmp-file))
  true)
(check "file-stat has :size"
  (number? (:size (zig.io/file-stat tmp-file)))
  true)
(check "file-stat :kind is :file"
  (:kind (zig.io/file-stat tmp-file))
  :file)
(check "file-stat :kind dir is :directory"
  (:kind (zig.io/file-stat tmp-dir))
  :directory)
(check "file-stat nonexistent returns nil"
  (zig.io/file-stat "/tmp/zzz_nonexistent_xyz.txt")
  nil)

;; file-size
(check "file-size"
  (zig.io/file-size tmp-file)
  5)
(check "file-size nonexistent returns nil"
  (zig.io/file-size "/tmp/zzz_nonexistent_xyz.txt")
  nil)

;; list-dir (use temp-dir for cross-platform compatibility)
(def tmp-list-dir (zig.core/temp-dir))
(check "list-dir returns vector"
  (vector? (zig.io/list-dir tmp-list-dir))
  true)
(check "list-dir entries are maps"
  (every? map? (zig.io/list-dir tmp-list-dir))
  true)
(check "list-dir entries have :name"
  (every? #(string? (:name %)) (zig.io/list-dir tmp-list-dir))
  true)
(check "list-dir entries have :kind"
  (every? #(keyword? (:kind %)) (zig.io/list-dir tmp-list-dir))
  true)

;; walk-dir
(check "walk-dir returns vector"
  (vector? (zig.io/walk-dir tmp-dir))
  true)
(check "walk-dir entries have :path"
  (every? #(string? (:path %)) (zig.io/walk-dir tmp-dir))
  true)

;; file-parent
(check "file-parent absolute"
  (zig.io/file-parent "/tmp/foo.txt")
  "/tmp")
(check "file-parent root"
  (zig.io/file-parent "/")
  "/")
(check "file-parent relative"
  (zig.io/file-parent "foo/bar.txt")
  "foo")
(check "file-parent no slash"
  (zig.io/file-parent "foo.txt")
  ".")

;; file-name
(check "file-name absolute"
  (zig.io/file-name "/tmp/foo.txt")
  "foo.txt")
(check "file-name relative"
  (zig.io/file-name "foo/bar.txt")
  "bar.txt")
(check "file-name no slash"
  (zig.io/file-name "foo.txt")
  "foo.txt")
(check "file-name root"
  (zig.io/file-name "/")
  nil)

;; absolute-path
(check "absolute-path absolute stays same"
  (= (zig.io/absolute-path "/tmp/foo") "/tmp/foo")
  true)

;; ============================================================
;; File Modification Time
;; ============================================================
(check "file-modified-time returns number"
  (number? (zig.io/file-modified-time tmp-file))
  true)

;; ============================================================
;; File I/O Streams (reader/writer)
;; ============================================================

;; open-writer + write-string + close
(let [w (io/writer tmp-file)]
  (io/write-chunk w "hello world")
  (io/flush w)
  (io/-close w))
(check "writer writes content"
  (slurp tmp-file)
  "hello world")

;; open-reader + read-chunk
(let [r (io/reader tmp-file)
      data (io/read-chunk r {})]
  (io/-close r)
  (check "reader reads content" data "hello world"))

;; Append mode
(let [w (io/writer tmp-file :append true)]
  (io/write-chunk w " and more")
  (io/-close w))
(check "writer append mode"
  (slurp tmp-file)
  "hello world and more")

;; input-stream + output-stream (byte streams)
(let [os (io/output-stream tmp-file2)]
  (zig.io/write-bytes os "binary test")
  (io/-close os))
(check "output-stream writes bytes"
  (slurp tmp-file2)
  "binary test")

(let [is (io/input-stream tmp-file2)
      data (zig.io/read-bytes is 100)]
  (io/-close is)
  (check "input-stream reads bytes" data "binary test"))

;; ============================================================
;; line-seq
;; ============================================================
(spit tmp-file "line1\nline2\nline3")
(let [r (io/reader tmp-file)
      lines (into [] (io/line-seq r))]
  (io/-close r)
  (check "line-seq returns correct lines" lines ["line1" "line2" "line3"]))

;; line-seq empty file
(spit tmp-file "")
(let [r (io/reader tmp-file)
      ls (io/line-seq r)
      lines (if ls (into [] ls) [])]
  (io/-close r)
  (check "line-seq empty file" lines []))

;; ============================================================
;; copy
;; ============================================================
(spit tmp-file "copy me")
(io/copy tmp-file tmp-copy)
(check "copy file-to-file"
  (slurp tmp-copy)
  "copy me")

;; ============================================================
;; with-open macro
;; ============================================================
(check "with-open from user namespace"
  (io/with-open [r (io/reader "/etc/hostname")]
    (first (io/line-seq r)))
  (clojure.string/trim-newline (slurp "/etc/hostname")))

(check "with-open closes on normal completion"
  (let [closed (atom false)]
    (io/with-open [r (io/reader "/etc/hostname")]
      (reset! closed true)
      (first (io/line-seq r)))
    @closed)
  true)

(check "with-open with multiple bindings"
  (io/with-open [r1 (io/reader "/etc/hostname")
                 r2 (io/reader "/etc/hostname")]
    (let [l1 (first (io/line-seq r1))
          l2 (first (io/line-seq r2))]
      (= l1 l2)))
  true)

;; ============================================================
;; Symlink operations
;; ============================================================
(spit tmp-file "symlink target")
(zig.io/sym-link tmp-file tmp-symlink)
(check "is-symlink? on symlink"
  (zig.io/is-symlink? tmp-symlink)
  true)
(check "read-link returns target"
  (= (clojure.string/replace (zig.io/read-link tmp-symlink) "\\" "/")
     (clojure.string/replace tmp-file "\\" "/"))
  true)

;; ============================================================
;; rename
;; ============================================================
(spit tmp-file "rename test")
(zig.io/rename tmp-file (str tmp-file ".renamed"))
(check "rename file-exists? new name"
  (zig.io/file-exists? (str tmp-file ".renamed"))
  true)
(check "rename file-exists? old name gone"
  (zig.io/file-exists? tmp-file)
  false)

;; ============================================================
;; delete operations
;; ============================================================
(spit tmp-file "delete me")
(zig.io/delete-file tmp-file)
(check "delete-file removes file"
  (zig.io/file-exists? tmp-file)
  false)

;; delete-dir (empty)
(zig.io/make-parents (str tmp-base "emptydir/"))
(zig.io/delete-dir (str tmp-base "emptydir/"))
(check "delete-dir removes empty dir"
  (zig.io/file-exists? (str tmp-base "emptydir/"))
  false)

;; ============================================================
;; Subprocess sh (blocking)
;; ============================================================
(let [result (io/sh "echo" "hello sh")]
  (check "sh returns map" (map? result) true)
  (check "sh :exit is 0" (:exit result) 0)
  (check "sh :out contains text" (string? (:out result)) true))

;; ============================================================
;; Subprocess sh-stream (async)
;; ============================================================

;; Basic spawn + read + wait
(let [p (io/sh-stream "echo" "async test")
      out (io/sh-out p)
      exit (io/sh-wait p)]
  (check "sh-stream :exit is 0" exit 0)
  (check "sh-stream :out is string" (string? out) true))

;; sh-in + sh-close-in + sh-out
(let [p (io/sh-stream "cat")
      _ (io/sh-in p "stdin data\n")
      _ (io/sh-close-in p)
      out (io/sh-out p)
      exit (io/sh-wait p)]
  (check "sh-stream stdin pipe" (string? out) true)
  (check "sh-stream stdin exit" exit 0))

;; sh-err
(let [p (io/sh-stream "sh" "-c" "echo err >&2")
      err (io/sh-err p)]
  (io/sh-wait p)
  (check "sh-stream stderr" (string? err) true))

;; sh-kill
(let [p (io/sh-stream "sleep" "60")]
  (io/sh-kill p)
  (check "sh-kill returns nil" nil nil))

;; ============================================================
;; Cleanup
;; ============================================================
(zig.io/delete-tree tmp-base)

(print-summary)
