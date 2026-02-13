# The Compilation Pipeline

Stele compiles source code to standalone executables through two backends:
a portable **C backend** and a native **AArch64 backend** (Apple Silicon).
Both share a common front end and intermediate representation.

```
Source (.stele) → PEG Parse → AST → Type Check → IR → Backend → cc → Binary
                                                      │
                                                      ├─ C Backend     → .c file
                                                      └─ AArch64 Backend → .s file + runtime
```

Each stage is implemented as a separate Haskell module.

## Stage 1: PEG Parsing

**Module:** `Stele.PEG`

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

**Module:** `Stele.Grammar` + `Stele.AST`

The grammar module defines the Stele grammar using the PEG combinator EDSL
and provides functions to convert parse trees into typed AST nodes.

The AST types (defined in `Stele.AST`) include:

- `Program` — a list of declarations
- `Decl` — struct, fn, or do
- `Expr` — all expression forms (literals, records, function calls, match, etc.)
- `Pattern` — all pattern forms (variable, literal, record, wildcard)
- `Stmt` — do statements (print, write, let, expression)

## Stage 3: Type Checking

**Module:** `Stele.Types`

The type checker implements **Algorithm W** extended with **Remy-style row
types**. It works in two passes:

1. **Registration pass:** Collect all declarations into the type environment.
   Each fn gets a fresh type variable; each struct's fields are recorded.

2. **Checking pass:** For each declaration body, walk the AST generating
   type constraints. Unify constraints as they arise using IORef-based
   mutable type variables.

Row unification follows Remy's algorithm:
- When unifying two record types, extract matching fields and unify them
  pairwise
- Remaining fields flow through the row variable
- This enables width subtyping automatically

Type errors are reported with the expression that caused the mismatch.

## Stage 4: Lowering to IR

**Module:** `Stele.IR` + `Stele.Lower`

The lowering pass transforms the typed AST into an explicit intermediate
representation with basic blocks, named temporaries, and flat instructions.
Pattern matching, match expressions, and let-in chains are all resolved at
this stage so that backends are purely mechanical translations.

Key properties of the IR:

- **Flat instructions** — no nested expressions; every subexpression is
  named as a `Var`.
- **Explicit reference counting** — `IRetain` and `IRelease` are first-class
  instructions.
- **Pattern matching decomposed into primitives** — `ITagCheck`, `INullCheck`,
  `IIntEq`, `IStrEq` plus `TBranch` terminators create explicit control flow.
- **No SSA phi nodes** — join points (match results) use a pre-declared
  result variable written by whichever branch succeeds.

## Stage 5: Code Generation

### C Backend

**Module:** `Stele.EmitC`

The C backend translates the IR into a single, self-contained C99 source file
with an embedded runtime. Each IR instruction maps to one or two lines of C,
and basic blocks become labeled sections with `goto`. See the
[C Code Generation](./codegen.md) chapter for details.

### AArch64 Backend

**Module:** `Stele.EmitAArch64`

The AArch64 backend emits Apple Silicon assembly (`.s` files). All IR
variables are stored on the stack using a fixed-size frame per function.
The generated assembly links against a separate C runtime
(`runtime_aarch64.c`) that provides the same value representation and
reference counting as the embedded C runtime.

## Stage 6: Assembling and Linking

The Stele CLI invokes the system C compiler (`cc`) to compile the generated
output into a binary:

- **C mode** (default): `cc -o prog prog.c`
- **Native mode** (`--native`): `cc -o prog prog.s prog_rt.c`

With `--run`, the resulting binary is executed immediately.

## Module Summary

| Module | Role |
|--------|------|
| `Stele.PEG` | PEG parser generator — packrat parsing from scratch |
| `Stele.AST` | Abstract syntax tree data types |
| `Stele.Grammar` | Grammar definition + parse tree → AST |
| `Stele.Types` | Type inference with row polymorphism |
| `Stele.IR` | Intermediate representation (basic blocks + flat instructions) |
| `Stele.Lower` | AST → IR lowering pass |
| `Stele.EmitC` | C code generation from IR |
| `Stele.EmitAArch64` | AArch64 assembly generation from IR |
| `Stele.Runtime` | C runtime source for the native backend |
