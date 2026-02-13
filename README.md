# Stele

<p align="center">
  <img src="logo.svg" alt="Stele logo" width="100"/>
</p>

A structural pattern-matching language.

Stele is an experiment in the limits of agentic programming. The entire
language — parser generator, grammar, type system, C code generation, AArch64
native code generation, and a self-hosting compiler — was built collaboratively
with AI. We pushed the experiment as far as writing a complete Stele compiler
*in Stele itself*, one that bootstraps and reaches a fixed point in both C
and native assembly output.

The language is built from first principles in Haskell. It draws from pattern
calculus and structural subtyping to create a language where pattern matching
is the fundamental operation and all functions accept structural records.

## Quick Start

```bash
# Build the compiler
cabal build

# Compile a program to C
cabal run stele -- examples/hello.stele
# => Compiled to examples/hello.c

# Compile and run in one step
cabal run stele -- --run examples/hello.stele
# => 25
# => 3628800

# Compile to native AArch64 assembly (Apple Silicon)
cabal run stele -- --native examples/hello.stele
# => Compiled to examples/hello

# Compile native and run
cabal run stele -- --native --run examples/hello.stele
```

## Stela (Self-Hosted Build Tool)

`examples/compiler/stela.stele` is a Stele-native build tool (no package
manager) with a Cargo-style command subset:

```bash
stela build <source.stele> [--lib <name> ...]
stela run <source.stele> [--lib <name> ...]
stela check <source.stele> [--lib <name> ...]
stela test <source.stele> [--lib <name> ...]
stela bench <source.stele> [--lib <name> ...]
stela package-lib <source.stele> [--name <name>] [--lib <name> ...]
stela clean
```

It supports sandboxed builds via `sandbox-exec` when available.

### Bootstrapping Stela

```bash
# 1) Build the self-hosted compiler binary
cabal run stele -- examples/compiler/compiler.stele
cc -O1 -o examples/compiler/compiler examples/compiler/compiler.c

# 2) Build stela with the self-hosted compiler
(cd examples/compiler && ./compiler stela.stele stela.c)
cc -O1 -o examples/compiler/stela examples/compiler/stela.c
```

### Using Stela

Run from the compiler directory (`runtime.c` is read relative to the current
working directory by the self-hosted compiler):

```bash
(cd examples/compiler && ./stela build ../hello.stele --compiler ./compiler --mode c)
(cd examples/compiler && ./stela run ../hello.stele --compiler ./compiler --mode c)
(cd examples/compiler && ./stela check ../hello.stele --compiler ./compiler --mode c)
(cd examples/compiler && ./stela test ../hello.stele --compiler ./compiler --mode c)
(cd examples/compiler && ./stela bench ../hello.stele --compiler ./compiler --mode c)
(cd examples/compiler && ./stela clean)
```

Local library packaging/inclusion:

```bash
(cd examples/compiler && ./stela package-lib math.stele --name math)
(cd examples/compiler && ./stela build app.stele --lib math --compiler ./compiler --mode c)
```

Libraries are stored under `.stela/lib/<name>.stelib`.

Bundled standard libraries live under `stdlib/`:

- `stdlib/cli.stele`: CLI helpers for `argc/argv`, flags, and key/value options
- `stdlib/math.stele`: integer math helpers (`abs`, `clamp`, `gcd`, `lcm`, etc.)
- `stdlib/concurrency.stele`: process-level helpers over `spawn/await/sleep_ms`
- `stdlib/assert.stele`: assertion helpers for test targets
- `stdlib/strings.stele`: string helpers (`starts_with`, `ends_with`, `trim`, etc.)
- `stdlib/path.stele`: POSIX-style path helpers (`basename`, `dirname`, `join`, etc.)

Stdlib test targets live under `stdlib/tests/`:

- `stdlib/tests/cli_test.stele`
- `stdlib/tests/math_test.stele`
- `stdlib/tests/concurrency_test.stele`
- `stdlib/tests/assert_test.stele`
- `stdlib/tests/strings_test.stele`
- `stdlib/tests/path_test.stele`

Example packaging flow:

```bash
(cd examples/compiler && ./stela package-lib ../../stdlib/cli.stele --name cli)
(cd examples/compiler && ./stela package-lib ../../stdlib/math.stele --name math)
(cd examples/compiler && ./stela package-lib ../../stdlib/concurrency.stele --name concurrency)
(cd examples/compiler && ./stela run app.stele --lib cli --lib math --lib concurrency --compiler ./compiler --mode c)
```

Run stdlib test targets across the supported mode matrix (`c`, `asm`, `x86`,
and `x86-linux` where host toolchain support exists):

```bash
./stdlib/tests/run.sh
```

Options: `--mode c|asm|x86|x86-linux`, `--sandbox`, `--no-sandbox`, `--lib <name>`, `--name <name>`.

## The Language

### Vocabulary

| Keyword   | Meaning                                         |
|-----------|------------------------------------------------|
| `struct`  | Named record type declaration                   |
| `oneof`   | Sum type declaration with tagged variants        |
| `fn`      | Pure function, defined by pattern clauses       |
| `do`      | Effectful entry point (do block)                |
| `case`    | Pattern clause: `case pattern => body`          |
| `end`     | Closes a struct, fn, do block, or match block   |
| `match`   | Inline pattern match expression                 |
| `print`   | Print a value followed by a newline             |
| `write`   | Write a value without a trailing newline        |
| `readln`  | Read a line of input                            |
| `readint` | Read an integer from input                      |
| `let`     | Bind a local variable                           |
| `{\| \|}` | Record literal delimiters (the "pillars")       |

### Hello, Stele

```
struct Point
  x : Int
  y : Int
end

fn square
  case {| n |} => n * n
end

fn distance
  case {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    (square {| n: dx |}) + (square {| n: dy |})
end

fn factorial
  case {| n: 0 |} => 1
  case {| n |} => n * (factorial {| n: n - 1 |})
end

do main
  let origin = Point {| x: 0, y: 0 |}
  let there = Point {| x: 3, y: 4 |}
  print distance {| a: origin, b: there |}
  print factorial {| n: 10 |}
end
```

Output:

```
25
3628800
```

### Structural Subtyping

Every function takes a single record argument. Pattern matching determines
which fields are required — any record with *at least* those fields
will be accepted. Extra fields are silently permitted (width subtyping).

```
fn magnitude_sq
  case {| x, y |} => x * x + y * y
end

do main
  -- A 2D point works
  print magnitude_sq {| x: 3, y: 4 |}

  -- A 3D point works too — the extra z field is ignored
  print magnitude_sq {| x: 1, y: 2, z: 3 |}
end
```

### Pattern Matching

Functions dispatch on their argument using `case` clauses. Patterns can
match literal values, bind variables, or destructure records:

```
fn collatz_step
  case {| n |} =>
    let half = n / 2
    match half * 2 == n
      case 1 => n / 2
      case 0 => n * 3 + 1
    end
end
```

`match` is an inline pattern match — it evaluates an expression and
matches the result against a series of `case` clauses, all as a single
expression.

### Sum Types

The `oneof` keyword declares sum types with tagged variants. Each variant
can optionally carry record fields:

```
oneof Shape
  Circle { radius : Int }
  Rect { width : Int, height : Int }
  Point
end

fn area
  case Circle {| radius |} => radius * radius * 3
  case Rect {| width, height |} => width * height
  case Point => 0
end
```

Functions pattern-match on variants directly, and `match` expressions work
with sum types too.

### Mutual Recursion

Functions can freely call each other:

```
fn female
  case {| n: 0 |} => 1
  case {| n |} =>
    n - (male {|
      n: female {| n: n - 1 |}
    |})
end

fn male
  case {| n: 0 |} => 0
  case {| n |} =>
    n - (female {|
      n: male {| n: n - 1 |}
    |})
end
```

## Architecture

Stele is implemented as a nine-module Haskell library plus a thin CLI
driver. The compilation pipeline is:

```
Source (.stele) → PEG Parse → AST → Type Check → IR → Backend → cc → Binary
                                                      │
                                                      ├─ C Backend     → .c file
                                                      └─ AArch64 Backend → .s file + runtime
```

### Modules

| Module               | Purpose                                        |
|----------------------|------------------------------------------------|
| `Stele.PEG`          | PEG parser generator, built from scratch       |
| `Stele.AST`          | Abstract syntax tree types                     |
| `Stele.Grammar`      | Grammar definition + parse tree to AST         |
| `Stele.Types`        | Type inference with row polymorphism           |
| `Stele.IR`           | Intermediate representation (basic blocks)     |
| `Stele.Lower`        | AST to IR lowering pass                        |
| `Stele.EmitC`        | C code generation from IR                      |
| `Stele.EmitAArch64`  | AArch64 assembly generation from IR            |
| `Stele.Runtime`      | C runtime source for the native backend        |

### PEG Parser Generator

The parser is built entirely from first principles — no Megaparsec, no
Happy, no Alex. Grammars are first-class Haskell values (`Map String PExpr`)
constructed with a combinator EDSL. The engine uses packrat memoization
for efficient parsing and furthest-position tracking for error reporting.

### Type System

The type checker implements Algorithm-W-style unification extended with
Remy-style row types. Record types carry a row variable that permits
additional fields:

```
{| x: Int, y: Int | r |}
```

This row variable `r` is what enables structural subtyping — a function
expecting `{| x, y |}` will accept any record with those fields plus
whatever `r` unifies with.

### Intermediate Representation

Between the type checker and the backends sits an explicit IR with basic
blocks, named temporaries, and flat instructions. Pattern matching, match
expressions, and let-in chains are all resolved at this stage so that
backends are purely mechanical translations.

### Code Generation

**C backend.** The C emitter produces self-contained C with an embedded
runtime. All values are reference-counted tagged unions allocated with
`malloc`. Because Stele values are immutable and there are no closures,
cycles are impossible and reference counting is sufficient. The generated code
is readable and can be compiled with any C compiler.

**AArch64 backend.** The native emitter produces Apple Silicon assembly. All
variables live on the stack in a fixed-size frame per function. The generated
assembly links against a separate C runtime (`runtime_aarch64.c`) that
provides the same value representation and reference counting.

## Examples

| Example             | Demonstrates                                     |
|---------------------|--------------------------------------------------|
| `examples/hello.stele`     | Structs, functions, construction, postfix calls, pattern matching |
| `examples/subtyping.stele` | Width subtyping, anonymous records              |
| `examples/match.stele`     | Inline pattern matching with fizzbuzz            |
| `examples/mutual.stele`    | Mutual recursion, Ackermann, Collatz, GCD, Fibonacci |
| `examples/oneof.stele`     | Sum types with variants                          |
| `examples/io.stele`        | IO operations                                    |
| `examples/compiler/compiler.stele` | Self-hosting compiler (Stele written in Stele) |

### Self-Hosting Compiler

Stele is self-hosting: `examples/compiler/compiler.stele` is a complete
Stele compiler written in Stele itself. It implements the full pipeline
— tokenizer, parser, C code emitter, and AArch64 native code generator — and
can compile itself. A bootstrap test verifies that the compiler reaches a
fixed point in both modes:

```bash
examples/compiler/bootstrap.sh 3        # C mode
examples/compiler/bootstrap.sh 3 asm    # AArch64 native mode
```

This compiles `compiler.stele` through three generations and confirms each
produces identical output.

## Building

Requirements: GHC 9.6+ and Cabal 3.10+.

```bash
cabal build         # Build the compiler
cabal haddock       # Generate API documentation
cabal run stele     # Run the compiler (shows usage)
```

## License

See the `LICENSE` file.
