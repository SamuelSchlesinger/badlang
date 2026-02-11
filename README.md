# badlang

A programming language of rites and glyphs.

badlang is an experiment in the limits of agentic programming. The entire
language — parser generator, grammar, type system, C code generation, AArch64
native code generation, and a self-hosting compiler — was built collaboratively
with AI. We pushed the experiment as far as writing a complete badlang compiler
*in badlang itself*, one that bootstraps and reaches a fixed point in both C
and native assembly output.

The language is built from first principles in Haskell. It draws from pattern
calculus and structural subtyping to create a language where pattern matching
is the fundamental operation and all functions accept structural records.

## Quick Start

```bash
# Build the compiler
cabal build

# Compile a program to C
cabal run badlang -- examples/hello.bad
# => Compiled to examples/hello.c

# Compile and run in one step
cabal run badlang -- --run examples/hello.bad
# => 25
# => 3628800

# Compile to native AArch64 assembly (Apple Silicon)
cabal run badlang -- --native examples/hello.bad
# => Compiled to examples/hello

# Compile native and run
cabal run badlang -- --native --run examples/hello.bad
```

## The Language

### Vocabulary

| Keyword   | Meaning                                         |
|-----------|------------------------------------------------|
| `altar`   | Named record type declaration                   |
| `rite`    | Pure function, defined by pattern clauses       |
| `ritual`  | Effectful entry point                           |
| `given`   | Pattern clause: `given pattern => body`         |
| `seal`    | Closes an altar, rite, ritual, or divine block  |
| `summon`  | Construct a record from an altar                |
| `invoke`  | Call a rite                                     |
| `divine`  | Inline pattern match expression                 |
| `utter`   | Print a value                                   |
| `let`     | Bind a local variable                           |
| `{| |}` | Record literal delimiters (the "pillars")       |

### Hello, Badlang

```
altar Point
  x : Int
  y : Int
seal

rite square
  given {| n |} => n * n
seal

rite distance
  given {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    (invoke square {| n: dx |}) + (invoke square {| n: dy |})
seal

rite factorial
  given {| n: 0 |} => 1
  given {| n |} => n * (invoke factorial {| n: n - 1 |})
seal

ritual main
  let origin = summon Point {| x: 0, y: 0 |}
  let there = summon Point {| x: 3, y: 4 |}
  utter invoke distance {| a: origin, b: there |}
  utter invoke factorial {| n: 10 |}
seal
```

Output:

```
25
3628800
```

### Structural Subtyping

Every rite takes a single record argument. Pattern matching determines
which fields are required — any record with *at least* those fields
will be accepted. Extra fields are silently permitted (width subtyping).

```
rite magnitude_sq
  given {| x, y |} => x * x + y * y
seal

ritual main
  -- A 2D point works
  utter invoke magnitude_sq {| x: 3, y: 4 |}

  -- A 3D point works too — the extra z field is ignored
  utter invoke magnitude_sq {| x: 1, y: 2, z: 3 |}
seal
```

### Pattern Matching

Rites dispatch on their argument using `given` clauses. Patterns can
match literal values, bind variables, or destructure records:

```
rite collatz_step
  given {| n |} =>
    let half = n / 2
    divine half * 2 == n
      given 1 => n / 2
      given 0 => n * 3 + 1
    seal
seal
```

`divine` is an inline pattern match — it evaluates an expression and
matches the result against a series of `given` clauses, all as a single
expression.

### Mutual Recursion

Rites can freely call each other:

```
rite female
  given {| n: 0 |} => 1
  given {| n |} =>
    n - (invoke male {|
      n: invoke female {| n: n - 1 |}
    |})
seal

rite male
  given {| n: 0 |} => 0
  given {| n |} =>
    n - (invoke female {|
      n: invoke male {| n: n - 1 |}
    |})
seal
```

## Architecture

badlang is implemented as a nine-module Haskell library plus a thin CLI
driver. The compilation pipeline is:

```
Source (.bad) → PEG Parse → AST → Type Check → IR → Backend → cc → Binary
                                                      │
                                                      ├─ C Backend     → .c file
                                                      └─ AArch64 Backend → .s file + runtime
```

### Modules

| Module               | Purpose                                        |
|----------------------|------------------------------------------------|
| `Badlang.PEG`        | PEG parser generator, built from scratch       |
| `Badlang.AST`        | Abstract syntax tree types                     |
| `Badlang.Grammar`    | Grammar definition + parse tree to AST         |
| `Badlang.Types`      | Type inference with row polymorphism           |
| `Badlang.IR`         | Intermediate representation (basic blocks)     |
| `Badlang.Lower`      | AST to IR lowering pass                        |
| `Badlang.EmitC`      | C code generation from IR                      |
| `Badlang.EmitAArch64`| AArch64 assembly generation from IR            |
| `Badlang.Runtime`    | C runtime source for the native backend        |

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
blocks, named temporaries, and flat instructions. Pattern matching, divine
expressions, and let-in chains are all resolved at this stage so that
backends are purely mechanical translations.

### Code Generation

**C backend.** The C emitter produces self-contained C with an embedded
runtime. All values are reference-counted tagged unions allocated with
`malloc`. Because badlang values are immutable and there are no closures,
cycles are impossible and reference counting is sufficient. The generated code
is readable and can be compiled with any C compiler.

**AArch64 backend.** The native emitter produces Apple Silicon assembly. All
variables live on the stack in a fixed-size frame per function. The generated
assembly links against a separate C runtime (`runtime_aarch64.c`) that
provides the same value representation and reference counting.

## Examples

| Example             | Demonstrates                                     |
|---------------------|--------------------------------------------------|
| `examples/hello.bad`     | Altars, rites, summon, invoke, pattern matching |
| `examples/subtyping.bad` | Width subtyping, anonymous records              |
| `examples/divine.bad`    | Inline pattern matching with fizzbuzz            |
| `examples/mutual.bad`    | Mutual recursion, Ackermann, Collatz, GCD, Fibonacci |
| `examples/compiler/compiler.bad` | Self-hosting compiler (badlang written in badlang) |

### Self-Hosting Compiler

badlang is self-hosting: `examples/compiler/compiler.bad` is a complete
badlang compiler written in badlang itself. It implements the full pipeline
— tokenizer, parser, C code emitter, and AArch64 native code generator — and
can compile itself. A bootstrap test verifies that the compiler reaches a
fixed point in both modes:

```bash
examples/compiler/bootstrap.sh 3        # C mode
examples/compiler/bootstrap.sh 3 asm    # AArch64 native mode
```

This compiles `compiler.bad` through three generations and confirms each
produces identical output.

## Building

Requirements: GHC 9.6+ and Cabal 3.10+.

```bash
cabal build         # Build the compiler
cabal haddock       # Generate API documentation
cabal run badlang   # Run the compiler (shows usage)
```

## License

See the `LICENSE` file.
