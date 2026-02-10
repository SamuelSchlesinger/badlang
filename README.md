# badlang

A programming language of rites and glyphs.

badlang is an experimental language built from first principles — parser
generator, grammar, type system, and C code generation — all in Haskell.
It draws from pattern calculus and structural subtyping to create a
language where pattern matching is the fundamental operation and all
functions accept structural records.

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

badlang is implemented as a five-module Haskell library plus a thin CLI
driver. The compilation pipeline is:

```
Source (.bad) → PEG Parse → AST → Type Check → C Codegen → cc → Binary
```

### Modules

| Module             | Purpose                                        |
|--------------------|------------------------------------------------|
| `Badlang.PEG`      | PEG parser generator, built from scratch       |
| `Badlang.AST`      | Abstract syntax tree types                     |
| `Badlang.Grammar`  | Grammar definition + parse tree to AST         |
| `Badlang.Types`    | Type inference with row polymorphism           |
| `Badlang.Emit`     | C code generation with embedded runtime        |

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

### C Code Generation

The emitter produces self-contained C with an embedded runtime. All
values are reference-counted tagged unions allocated with `malloc`.
Because badlang values are immutable and there are no closures, cycles
are impossible and reference counting is sufficient. Pattern matching
compiles to cascading if-chains. The generated code is readable and
can be compiled with any C compiler that supports `__builtin_va_arg`
(GCC and Clang).

## Examples

| Example             | Demonstrates                                     |
|---------------------|--------------------------------------------------|
| `examples/hello.bad`     | Altars, rites, summon, invoke, pattern matching |
| `examples/subtyping.bad` | Width subtyping, anonymous records              |
| `examples/divine.bad`    | Inline pattern matching with fizzbuzz            |
| `examples/mutual.bad`    | Mutual recursion, Ackermann, Collatz, GCD, Fibonacci |

## Building

Requirements: GHC 9.6+ and Cabal 3.10+.

```bash
cabal build         # Build the compiler
cabal haddock       # Generate API documentation
cabal run badlang   # Run the compiler (shows usage)
```

## License

See the `LICENSE` file.
