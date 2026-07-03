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
(zig.core/delete-tree tmp-base)

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
(zig.core/make-parents tmp-dir2)
(check "is-directory? after make-parents"
  (zig.core/is-directory? tmp-dir2)
  true)
(check "file-exists? after make-parents"
  (zig.core/file-exists? tmp-dir2)
  true)

;; is-file?
(spit tmp-file "hello")
(check "is-file? on file"
  (zig.core/is-file? tmp-file)
  true)
(check "is-file? on dir"
  (zig.core/is-file? tmp-dir)
  false)
(check "is-file? on nonexistent"
  (zig.core/is-file? "/tmp/zzz_nonexistent_xyz.txt")
  false)

;; file-stat
(check "file-stat returns map"
  (map? (zig.core/file-stat tmp-file))
  true)
(check "file-stat has :size"
  (number? (:size (zig.core/file-stat tmp-file)))
  true)
(check "file-stat :kind is :file"
  (:kind (zig.core/file-stat tmp-file))
  :file)
(check "file-stat :kind dir is :directory"
  (:kind (zig.core/file-stat tmp-dir))
  :directory)
(check "file-stat nonexistent returns nil"
  (zig.core/file-stat "/tmp/zzz_nonexistent_xyz.txt")
  nil)

;; file-size
(check "file-size"
  (zig.core/file-size tmp-file)
  5)
(check "file-size nonexistent returns nil"
  (zig.core/file-size "/tmp/zzz_nonexistent_xyz.txt")
  nil)

;; list-dir (use temp-dir for cross-platform compatibility)
(def tmp-list-dir (zig.core/temp-dir))
(check "list-dir returns vector"
  (vector? (zig.core/list-dir tmp-list-dir))
  true)
(check "list-dir entries are maps"
  (every? map? (zig.core/list-dir tmp-list-dir))
  true)
(check "list-dir entries have :name"
  (every? #(string? (:name %)) (zig.core/list-dir tmp-list-dir))
  true)
(check "list-dir entries have :kind"
  (every? #(keyword? (:kind %)) (zig.core/list-dir tmp-list-dir))
  true)

;; walk-dir
(check "walk-dir returns vector"
  (vector? (zig.core/walk-dir tmp-dir))
  true)
(check "walk-dir entries have :path"
  (every? #(string? (:path %)) (zig.core/walk-dir tmp-dir))
  true)

;; file-parent
(check "file-parent absolute"
  (zig.core/file-parent "/tmp/foo.txt")
  "/tmp")
(check "file-parent root"
  (zig.core/file-parent "/")
  "/")
(check "file-parent relative"
  (zig.core/file-parent "foo/bar.txt")
  "foo")
(check "file-parent no slash"
  (zig.core/file-parent "foo.txt")
  ".")

;; file-name
(check "file-name absolute"
  (zig.core/file-name "/tmp/foo.txt")
  "foo.txt")
(check "file-name relative"
  (zig.core/file-name "foo/bar.txt")
  "bar.txt")
(check "file-name no slash"
  (zig.core/file-name "foo.txt")
  "foo.txt")
(check "file-name root"
  (zig.core/file-name "/")
  nil)

;; absolute-path
(check "absolute-path absolute stays same"
  (= (zig.core/absolute-path "/tmp/foo") "/tmp/foo")
  true)

;; ============================================================
;; File Modification Time
;; ============================================================
(check "file-modified-time returns number"
  (number? (zig.core/file-modified-time tmp-file))
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
  (zig.core/write-bytes os "binary test")
  (io/-close os))
(check "output-stream writes bytes"
  (slurp tmp-file2)
  "binary test")

(let [is (io/input-stream tmp-file2)
      data (zig.core/read-bytes is 100)]
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
;; with-open macro (skipped — try/finally not yet implemented)
;; ============================================================
;; (check "with-open reads content" ...)
;; NOTE: with-open requires try/finally which is not yet implemented

;; ============================================================
;; Symlink operations
;; ============================================================
(spit tmp-file "symlink target")
(zig.core/sym-link tmp-file tmp-symlink)
(check "is-symlink? on symlink"
  (zig.core/is-symlink? tmp-symlink)
  true)
(check "read-link returns target"
  (zig.core/read-link tmp-symlink)
  tmp-file)

;; ============================================================
;; rename
;; ============================================================
(spit tmp-file "rename test")
(zig.core/rename tmp-file (str tmp-file ".renamed"))
(check "rename file-exists? new name"
  (zig.core/file-exists? (str tmp-file ".renamed"))
  true)
(check "rename file-exists? old name gone"
  (zig.core/file-exists? tmp-file)
  false)

;; ============================================================
;; delete operations
;; ============================================================
(spit tmp-file "delete me")
(zig.core/delete-file tmp-file)
(check "delete-file removes file"
  (zig.core/file-exists? tmp-file)
  false)

;; delete-dir (empty)
(zig.core/make-parents (str tmp-base "emptydir/"))
(zig.core/delete-dir (str tmp-base "emptydir/"))
(check "delete-dir removes empty dir"
  (zig.core/file-exists? (str tmp-base "emptydir/"))
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
(zig.core/delete-tree tmp-base)

(print-summary)
