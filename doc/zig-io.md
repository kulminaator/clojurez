# zig.io


## Table of Contents

- [alength](#alength)
- [as-relative-path](#as-relative-path)
- [char-at](#char-at)
- [copy](#copy)
- [file](#file)
- [input-stream](#input-stream)
- [line-seq](#line-seq)
- [output-stream](#output-stream)
- [parse-sh-args](#parse-sh-args)
- [reader](#reader)
- [sh](#sh)
- [sh-close-in](#sh-close-in)
- [sh-err](#sh-err)
- [sh-in](#sh-in)
- [sh-kill](#sh-kill)
- [sh-out](#sh-out)
- [sh-stream](#sh-stream)
- [sh-wait](#sh-wait)
- [split-path](#split-path)
- [with-open](#with-open)
- [with-sh-dir](#with-sh-dir)
- [with-sh-env](#with-sh-env)
- [writer](#writer)

---

## alength

[(^String s)]

Get length of string.

---

## as-relative-path

[(x)]

Take an as-file-able thing and return a string if it is
   a relative path, else throw an exception.

---

## char-at

[(s i)]

Get character at index in string.

---

## copy

[(input output & opts)]

Copies data from input to output. Returns nil.

   Input may be a reader handle, input stream handle, or a file path string.
   Output may be a writer handle, output stream handle, or a file path string.

   Options:
     :buffer-size  buffer size to use (default 4096)
     :encoding     encoding for char/binary conversion (default "UTF-8")

---

## file

[(arg) (parent child) (parent child & more)]

Returns a file map, passing each arg to as-file.  Multiple-arg
   versions treat the first argument as parent and subsequent args as
   children relative to the parent.

   Returns a map: {:path "..." :name "..." :dir "..."}

---

## input-stream

[(x & opts)]

Attempts to coerce its argument into an open input stream handle.

   If argument is a String, it is treated as a file path.

   Options:
     :buffer-size buffer size in bytes (default 4096)

---

## line-seq

[(reader)]

Returns a lazy sequence of lines from a reader handle.
   Each line is a string without the newline character.

---

## output-stream

[(x & opts)]

Attempts to coerce its argument into an open output stream handle.

   If argument is a String, it is treated as a file path.

   Options:
     :append      true to append (default false)
     :buffer-size buffer size in bytes (default 4096)

---

## parse-sh-args

[(args)]

Separate command strings from keyword options.

---

## reader

[(x & opts)]

Attempts to coerce its argument into an open reader handle.

   If argument is a String, it is treated as a file path.

   Options:
     :encoding    character encoding (default "UTF-8")
     :buffer-size buffer size in bytes (default 4096)

---

## sh

[(& args)]

Launches a sub-process with the given command and arguments.

   Arguments before any keyword are treated as command strings.
   Keyword options:

   :in      data to feed to stdin (String)
   :in-enc  encoding for input (default "UTF-8")
   :out-enc encoding for output (default "UTF-8", or :bytes for raw bytes)
   :env     environment map for the subprocess
   :dir     working directory for the subprocess

   Returns a map:
     :exit => exit code (integer)
     :out  => stdout (String or byte vector)
     :err  => stderr (String)

---

## sh-close-in

[(handle)]

Close the stdin pipe of a process handle, signaling EOF to
   the subprocess.

   Returns nil.

---

## sh-err

[(handle) (handle max-bytes)]

Read available output from a process handle's stderr.

   Returns a string of whatever data is available, or nil if
   the pipe is closed and empty.

   max-bytes (optional) limits the amount read, default 4096.

---

## sh-in

[(handle data)]

Write data to a process handle's stdin.

   Returns nil.

---

## sh-kill

[(handle)]

Kill a running subprocess.

   Terminates the process and cleans up resources. Returns nil.

---

## sh-out

[(handle) (handle max-bytes)]

Read available output from a process handle's stdout.

   Returns a string of whatever data is available, or nil if
   the pipe is closed and empty.

   max-bytes (optional) limits the amount read, default 4096.

---

## sh-stream

[(& args)]

Spawns a subprocess and returns a process handle for async I/O.

   The handle allows incremental reading of stdout/stderr and
   writing to stdin. Use sh-wait to wait for completion and get
   the exit code, or sh-kill to terminate the process.

   Arguments before any keyword are treated as command strings.
   Keyword options are passed through (currently not fully used).

   Returns a wrapped process handle.

---

## sh-wait

[(handle)]

Wait for a subprocess to finish and return its exit code.

   Closes all pipes and cleans up resources. Returns the exit code
   as an integer.

---

## split-path

[(path)]

Split a path string into directory and name components.

---

## with-open

[(bindings & body)]

bindings => [name1 init1 name2 init2 ...]

  Evaluates body in a let form where name1 is
  bound to the result of init1, name2 to the result of init2, etc.
  After body is evaluated, each name that implements Closeable
  will have -close called on it (in reverse order), regardless of
  whether body completed normally or exited via an exception.

---

## with-sh-dir

[(dir & forms)]

Sets the directory for use with sh.

---

## with-sh-env

[(env & forms)]

Sets the environment for use with sh.

---

## writer

[(x & opts)]

Attempts to coerce its argument into an open writer handle.

   If argument is a String, it is treated as a file path.

   Options:
     :encoding    character encoding (default "UTF-8")
     :append      true to append (default false)
     :buffer-size buffer size in bytes (default 4096)
