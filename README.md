# ClojureZ - Clojure in Zig

A Clojure interpreter written in Zig. No JVM required.

## Quick Start

Clone the project then build it.
```bash
zig build
./zig-out/bin/clojurez -e '(+ 1 2 3)'
```

Alternatively, if you don't want to build from source - you can also download the latest release from Github
Link: [https://github.com/kulminaator/clojurez/releases](https://github.com/kulminaator/clojurez/releases)


### Modes

```bash
# Start the REPL
./zig-out/bin/clojurez

# Evaluate an expression
./zig-out/bin/clojurez -e '(defn square [n] (* n n)) (square 5)'

# Run a file
./zig-out/bin/clojurez my_script.clj

# Run with classpath and main function
./zig-out/bin/clojurez -cp src -m my.namespace
```

Type `(quit)`, `(exit)`, or press `CTRL+D` to exit the REPL.

### Build Variants

| Binary | Size | Use |
|--------|------|-----|
| `clojurez` | ~24MB | Debug (full safety checks) |
| `clojurez-medium` | ~740KB | ReleaseSmall |
| `clojurez-mini` | ~740KB | ReleaseSmall + stripped |

## Key Features

- **Garbage collection** - mark-and-sweep GC, all runtime values managed automatically
- **Full numeric tower** - integer, float, BigInt (`123N`), Ratio (`(/ 22 7)` → `22/7`), BigDecimal (`123.456M`)
- **Macros** - `defmacro` with full expansion, shorthand `#(%)` for anonymous functions
- **Namespaces** - `ns` with `:require`/`:as`, classpath via `-cp`, main via `-m`
- **Protocols** - `defprotocol`, `extend`, `extend-type`, `extend-protocol`, `satisfies?`
- **Records** - `defrecord` with factory functions, map-like ops, protocol support
- **Lazy sequences** - `lazy-seq`, `map`, `filter`, `take`, `drop`, `iterate`, `cycle`
- **UTF-8** - full Unicode support in strings, symbols, keywords, characters
- **Regex** - `#"..."` literals with a pure-Zig regex engine
- **Bitwise ops** - `bit-and`, `bit-or`, `bit-xor`, `bit-shift-left`, etc.
- **Atoms** - `atom`, `swap!`, `reset!`
- **Multithreading** - `future`, `future-call`, `promise`, `deliver`, `realized?`, `sleep`
- **Bytecode compilation** - functions with pure arithmetic/comparison bodies are compiled to bytecode for faster repeated execution
- **Filesystem operations** - `stat`, `list-dir`, `walk-dir`, `make-dir`, `delete`, `rename`, `copy`, `delete-tree` via `zig.core`
- **Stream I/O** - buffered input/output streams, readers, writers via `zig.core/open-input-stream`, `open-output-stream`, `open-reader`, `open-writer`
- **Process I/O** - synchronous subprocess execution via `(sh ...)`, async streaming subprocess I/O via `(sh-stream ...)` with `sh-in`, `sh-out`, `sh-err`, `sh-wait`, `sh-kill`
- **`zig.io` namespace** - protocol-based I/O abstractions (`Closeable`, `IOFactory`, `Readable`, `Writable`), path utilities, `with-open`, `copy`, `line-seq`

## Known Differences from JVM Clojure

- No Java interop (not applicable for a standalone VM)
- No JIT compilation (bytecode compilation is used for eligible function bodies)
- Strings are UTF-8 (not UTF-16)
- Simpler collection internals (no chunking)
- Minimal runtime (< 1MB stripped)

## License

Eclipse Public License 1.0

## Copyright

- Parts overlapping with original Clojure: Rich Hickey and Clojure team
- Original parts: Martin Roos
