# A replica of clojure programming language written in Zig.

TL;DR - Clojure built in Zig. If you are looking for original clojure you can find it here: https://github.com/clojure/clojure

## Quick Start

Build the project:

```bash
zig build
```

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

## License:
 Eclipse 1.0 license to be in harmony with original clojure project

## Copyright:
- For parts that overlap with the implementation with original clojure, the copyright belongs to Rich Hickey and the according clojure team members.
- For parts that do not overlap with original clojure project, the copyright belongs to Martin Roos
