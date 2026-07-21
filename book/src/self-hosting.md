# The Self-Hosting Compiler

Stele is **self-hosting**: the modular program rooted at
`compiler/main.stele` is a complete Stele compiler written in Stele itself. It
implements module resolution, type checking, lambda lifting, and the C,
AArch64, and x86-64 backends, and can compile itself.

## Why Self-Hosting?

A self-hosting compiler is the ultimate test of a language's expressiveness. If
a language can implement its own compiler, it demonstrates that the language is
powerful enough for real-world systems programming. For Stele, it also
serves as:

- **A stress test** of every language feature: records, pattern matching,
  recursion, structural subtyping, and I/O all get a serious workout.
- **A correctness proof** via bootstrapping: when the compiler compiles itself
  and produces identical output across generations, we know it faithfully
  implements its own semantics.
- **The largest Stele program**, exercising the compiler at scale (more than
  8,000 lines across its modules).

## Architecture at a Glance

The self-hosting compiler follows the same pipeline as the Haskell bootstrap
compiler:

```
Source → Tokenize → Parse → Resolve modules → Type check → Desugar
       → Lift closures → Emit C/AArch64/x86-64 → Write file
```

The compiler reads a source file, recursively loads its modules, checks the
flattened program, and emits C or native assembly depending on the mode. The C
backend embeds `runtime/runtime.c`; native outputs link against it.

The compiler selects its output mode via command-line arguments:
- `build/compiler source.stele output.c` — emit C (default)
- `build/compiler source.stele output.s asm` — emit AArch64 assembly
- `build/compiler source.stele output.s x86` — emit x86-64 assembly

The compiler is split into focused modules:

| Section | Purpose |
|---------|---------|
| `util`, `lexer`, `parser`, `ast` | Front end and shared data structures |
| `resolve` | Recursive imports, signatures, and name mangling |
| `typecheck` | Inference, row unification, and nominal sums |
| `desugar`, `lambda_lift` | Variant lowering and closure conversion |
| `codegen_c` | C translation |
| `codegen_aarch64`, `codegen_x86` | Native assembly translation |
| `main` | Driver selecting mode and tying the pipeline together |

Each section is covered in detail in the following subchapters.
