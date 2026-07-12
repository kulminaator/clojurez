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
| `clojurez` | ~30MB | Debug (full safety checks) |
| `clojurez-medium` | ~1MB | ReleaseSmall |
| `clojurez-mini` | ~1MB | ReleaseSmall + stripped |

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
- **Network sockets** - TCP client/server sockets and UDP datagram sockets via `zig.io` (`socket`, `server-socket`, `accept`, `udp-socket`, `udp-send!`, `udp-receive`, `set-socket-timeout!`), integrated with stream/reader/writer protocols
- **Exceptions** - `try`/`catch`/`finally`/`throw`, `ex-info`, `ex-data`, `ex-message`, `ex-cause`, exception hierarchy (`derive`, `parents`, `isa?`), built-in types (`ArithmeticException`, `RuntimeException`, `IOException`, `FileNotFoundException`, `NullPointerException`, `TimeoutException`)
- **`clojure.math` namespace** - constants (`E`, `PI`), trigonometric (`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`), hyperbolic (`sinh`, `cosh`, `tanh`), exponential/logarithmic (`exp`, `log`, `log10`, `sqrt`, `cbrt`, `pow`, `hypot`), rounding (`ceil`, `floor`, `rint`, `round`), IEEE operations (`IEEE-remainder`, `signum`, `copy-sign`, `ulp`, `scalb`, `next-after`, `next-up`, `next-down`), exact integer arithmetic (`add-exact`, `subtract-exact`, `multiply-exact`, `increment-exact`, `decrement-exact`, `negate-exact`), floor division/modulus (`floor-div`, `floor-mod`)
- **Pre-cached values** - singleton caching for `nil`, booleans, small integers, latin characters, empty collections (`()`, `[]`, `{}`, `#{}`), and mathematical constants (`E`, `PI`)

## Documentation

Auto-generated API reference is available in the `doc/` directory:

- [API Reference Index](doc/index.md) — overview of all namespaces
- [clojure.core](doc/clojure-core.md) — core library functions and macros
- [clojure.string](doc/clojure-string.md) — string manipulation functions
- [clojure.math](doc/clojure-math.md) — mathematical functions and constants
- [zig.core](doc/zig-core.md) — internal Zig builtins
- [zig.io](doc/zig-io.md) — I/O abstractions and protocols
- [Special Forms](doc/special-forms.md) — language special forms

Documentation is regenerated automatically on every build. To regenerate manually:
```bash
./zig-out/bin/clojurez doc/gen_docs.clj
```

## Known Differences from JVM Clojure

- No Java interop (not applicable for a standalone VM)
- No JIT compilation (bytecode compilation is used for eligible function bodies)
- Strings are UTF-8 (not UTF-16)
- Simpler collection internals (some chunking support)
- Minimal runtime (< 1MB stripped)

## Zig interop
Developers coming from JVM Clojure might assume that you can call Zig functions directly from clojurez. Sadly it's not so simple. We do have very precise bindings from zig.core library to native zig functions (and some functions from other namespaces as well), but you can't just call any function in Zig std lib as you wish.

Zig doesn’t include its standard library in your program the way Java includes a runtime. When Zig compiles your code, it only keeps the tiny pieces you actually use, and even those get heavily optimized into raw machine instructions. That means most Zig functions don’t exist in the final binary in any recognizable form. Because of this, your scripting language can only call the Zig functions you explicitly expose — not the entire Zig std library. Think of Zig as a compiler that builds exactly what you ask for, not a runtime that brings its whole toolbox along. We don't use majority of zig's std lib, therefor it is also not compiled into our binary. 

I am considering adding dlopen style support to deal with dynamically linked libraries, this would open the doors not just to Zig but also C libraries.

Since the project is open source - you can fork it and modify it to adjust to your needs (as long as you follow the license and copyrights).

## License

Eclipse Public License 1.0

## Copyright

- Parts overlapping with original Clojure: Rich Hickey and Clojure team
- Original parts: Martin Roos
