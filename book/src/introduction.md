# Introduction

<p align="center">
  <img src="../../logo.svg" alt="Stele logo" width="100"/>
</p>

**Stele** is an experimental programming language built on structural pattern matching.

It is built from first principles — parser generator, grammar, type system, and
C code generation — all implemented in Haskell with no external parsing
libraries. Stele draws from pattern calculus and structural subtyping to
create a language where **pattern matching is the fundamental operation** and
all functions accept structural records.

## Philosophy

Stele is designed around a few core ideas:

- **Records are the universal data structure.** Every function takes a single
  record argument. There are no positional parameters, no tuples, no lists —
  just records with named fields.

- **Pattern matching is the only way to inspect values.** There is no
  `if`/`else`. Instead, you use `case` clauses to match on the shape and
  content of records. This is both the branching mechanism and the
  destructuring mechanism.

- **Structural subtyping via row polymorphism.** A function that needs fields
  `x` and `y` will accept *any* record that has those fields, regardless of
  what other fields are present. Types are inferred, not declared.

- **Compilation to C and native code.** Stele compiles to readable,
  self-contained C99 or directly to AArch64 assembly (Apple Silicon). The
  generated code can be inspected, debugged, and compiled with any C compiler.

## A Taste

```
fn factorial
  case {| n: 0 |} => 1
  case {| n |} => n * (factorial {| n: n - 1 |})
end

do main
  print factorial {| n: 10 |}
end
```

Output:

```
3628800
```

A `fn` is a pure function defined by pattern matching. A `do` is an
effectful entry point. Functions are called by placing an argument after the
function name. `print` prints a value. `{| ... |}` are record literals — the
"pillars" that hold the language together.

## What This Book Covers

This book is a complete guide to the Stele language. It covers:

- How to install the compiler and run your first program
- Every syntactic construct in the language
- The type system and how structural subtyping works
- Input and output: reading from stdin, writing files, command-line arguments
- Patterns and techniques for writing idiomatic Stele
- How the compilation pipeline works under the hood
- A complete reference for all keywords, operators, and built-in functions
