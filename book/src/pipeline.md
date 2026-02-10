# The Compilation Pipeline

badlang compiles source code to standalone executables via C. The pipeline
has five stages:

```
Source (.bad) → PEG Parse → AST → Type Check → C Codegen → cc → Binary
```

Each stage is implemented as a separate Haskell module.

## Stage 1: PEG Parsing

**Module:** `Badlang.PEG`

The parser is built entirely from first principles — no Megaparsec, no Happy,
no Alex. It implements a **Parsing Expression Grammar (PEG)** engine with:

- **Packrat memoization** for O(n) parsing
- **Furthest-position tracking** for error reporting
- A **combinator EDSL** for defining grammars as Haskell values

Grammars are first-class values of type `Map String PExpr`, where each entry
maps a rule name to a parsing expression. The combinators include:

- `pLit` — match a literal string
- `pSeq` — sequencing
- `pAlt` — ordered choice
- `pStar`, `pPlus` — repetition
- `pRef` — reference another rule
- `pNot` — negative lookahead

The parser produces a parse tree, which is then transformed into an AST.

## Stage 2: AST Construction

**Module:** `Badlang.Grammar` + `Badlang.AST`

The grammar module defines the badlang grammar using the PEG combinator EDSL
and provides functions to convert parse trees into typed AST nodes.

The AST types (defined in `Badlang.AST`) include:

- `Program` — a list of declarations
- `Decl` — altar, rite, or ritual
- `Expr` — all expression forms (literals, records, invoke, divine, etc.)
- `Pattern` — all pattern forms (variable, literal, record, wildcard)
- `Stmt` — ritual statements (utter, whisper, let, expression)

## Stage 3: Type Checking

**Module:** `Badlang.Types`

The type checker implements **Algorithm W** extended with **Remy-style row
types**. It works in two passes:

1. **Registration pass:** Collect all declarations into the type environment.
   Each rite gets a fresh type variable; each altar's fields are recorded.

2. **Checking pass:** For each declaration body, walk the AST generating
   type constraints. Unify constraints as they arise using IORef-based
   mutable type variables.

Row unification follows Remy's algorithm:
- When unifying two record types, extract matching fields and unify them
  pairwise
- Remaining fields flow through the row variable
- This enables width subtyping automatically

Type errors are reported with the expression that caused the mismatch.

## Stage 4: C Code Generation

**Module:** `Badlang.Emit`

The emitter produces a single, self-contained C file with an embedded runtime.
See the [C Code Generation](./codegen.md) chapter for details.

## Stage 5: C Compilation

The badlang CLI invokes the system C compiler (`cc`) to compile the generated
C code into a binary. With `--run`, it also executes the resulting binary
immediately.

## Module Summary

| Module | Role |
|--------|------|
| `Badlang.PEG` | PEG parser generator — packrat parsing from scratch |
| `Badlang.AST` | Abstract syntax tree data types |
| `Badlang.Grammar` | Grammar definition + parse tree → AST |
| `Badlang.Types` | Type inference with row polymorphism |
| `Badlang.Emit` | C code generation with embedded runtime |
