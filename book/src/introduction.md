# Introduction

**badlang** is an experimental programming language of rites and glyphs.

It is built from first principles — parser generator, grammar, type system, and
C code generation — all implemented in Haskell with no external parsing
libraries. badlang draws from pattern calculus and structural subtyping to
create a language where **pattern matching is the fundamental operation** and
all functions accept structural records.

## Philosophy

badlang is designed around a few core ideas:

- **Records are the universal data structure.** Every function takes a single
  record argument. There are no positional parameters, no tuples, no lists —
  just records with named fields.

- **Pattern matching is the only way to inspect values.** There is no
  `if`/`else`. Instead, you use `given` clauses to match on the shape and
  content of records. This is both the branching mechanism and the
  destructuring mechanism.

- **Structural subtyping via row polymorphism.** A function that needs fields
  `x` and `y` will accept *any* record that has those fields, regardless of
  what other fields are present. Types are inferred, not declared.

- **Compilation to C.** badlang compiles to readable, self-contained C99 that
  can be inspected, debugged, and compiled with any C compiler.

## A Taste

```
rite factorial
  given {| n: 0 |} => 1
  given {| n |} => n * (invoke factorial {| n: n - 1 |})
seal

ritual main
  utter invoke factorial {| n: 10 |}
seal
```

Output:

```
3628800
```

A `rite` is a pure function defined by pattern matching. A `ritual` is an
effectful entry point. `invoke` calls a rite. `utter` prints a value.
`{| ... |}` are record literals — the "pillars" that hold the language
together.

## What This Book Covers

This book is a complete guide to the badlang language. It covers:

- How to install the compiler and run your first program
- Every syntactic construct in the language
- The type system and how structural subtyping works
- Input and output: reading from stdin, writing files, command-line arguments
- Patterns and techniques for writing idiomatic badlang
- How the compilation pipeline works under the hood
- A complete reference for all keywords, operators, and built-in rites
