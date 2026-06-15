# A replica of clojure programming language written in Zig.

TL;DR - Clojure built in Zig. If you are looking for original clojure you can find it here: https://github.com/clojure/clojure

## Quick Start

Build the project:

```bash
zig build
```

Alternatively, if you don't want to build from source - you can also download the latest release from Github 
Link: [https://github.com/kulminaator/clojurez/releases](https://github.com/kulminaator/clojurez/releases)


The binary is placed at `zig-out/bin/clojurez`.

### Evaluate an expression

```bash
./zig-out/bin/clojurez -e '(+ 1 2 3)'
```

### Run a single file

```bash
./zig-out/bin/clojurez my_script.clj
```

### Run a project with a main function

Similar to `clojure -M` / `java -cp`:

```bash
./zig-out/bin/clojurez -cp src -m my.namespace
```

This resolves `my.namespace` to `src/my/namespace.clj` and calls its `-main` function.

### Start the REPL

```bash
./zig-out/bin/clojurez
```

Type `(quit)` or `(exit)` or `CTRL+D` to exit.

For full details — features, API, testing, and project structure — see [TECHNICAL_README.md](TECHNICAL_README.md).

## Key Features
- **Garbage collection** — automatic memory management for all runtime values
- **Big number support** — BigInt, Ratio, and BigDecimal with arbitrary precision
- **Macros** — full macro expansion with `defmacro`
- **Namespaces** — `ns` declarations with `:require` and `:as` aliases
- **Protocols** — `defprotocol`, `extend`, `extend-type`, `extend-protocol`, `satisfies?`
- **Records** — `defrecord` with factory functions, map-like operations, and protocol support
- **Lazy sequences** — `lazy-seq`, `map`, `filter`, `take`, `drop`, etc.
- **UTF-8** — full Unicode support in strings, symbols, and keywords

## Compatibility
While the project strives for good compatibility, we are definitely not there yet and we will never be fully there, as we lack JVM.

So here are the known differences:
 - no java support, not today, not ever
 - hence also no jit. we are pretty much a parsing machine most of the time
 - our strings are utf8, not utf16
 - our collections have a simpler design and don't have chunking etc.
 - our runtime is minuscule, less than a megabyte in the minimized form

## License:
 Eclipse 1.0 license to be in harmony with original clojure project

## Copyright:
- For parts that overlap with the implementation with original clojure, the copyright belongs to Rich Hickey and the according clojure team members.
- For parts that do not overlap with original clojure project, the copyright belongs to Martin Roos
