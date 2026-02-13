# The Self-Hosting Compiler

badlang is **self-hosting**: the file `examples/compiler/compiler.bad` is a
complete badlang compiler written in badlang itself. It implements the full
compilation pipeline — tokenizer, parser, C code emitter, and AArch64 native
code generator — and can compile itself.

## Why Self-Hosting?

A self-hosting compiler is the ultimate test of a language's expressiveness. If
a language can implement its own compiler, it demonstrates that the language is
powerful enough for real-world systems programming. For badlang, it also
serves as:

- **A stress test** of every language feature: records, pattern matching,
  recursion, structural subtyping, and I/O all get a serious workout.
- **A correctness proof** via bootstrapping: when the compiler compiles itself
  and produces identical output across generations, we know it faithfully
  implements its own semantics.
- **The largest badlang program**, exercising the compiler at scale (~3000
  lines).

## Architecture at a Glance

The self-hosting compiler follows the same pipeline as the Haskell reference
compiler, minus the type checker:

```
Source (.bad) → Tokenize → Parse → Emit C or AArch64 → Write File
```

The compiler reads a source file, tokenizes it, parses the token stream into
an AST, and generates either C code or AArch64 assembly depending on the mode.
It relies on a shared `runtime.c` (or `runtime_aarch64.c` for native mode)
that provides the value representation, reference counting, and built-in
functions for file I/O and string manipulation.

The compiler selects its output mode via command-line arguments:
- `compiler source.bad output.c` — emit C (default)
- `compiler source.bad output.s asm` — emit AArch64 assembly

The entire compiler is a single file organized into clear sections:

| Section | Purpose |
|---------|---------|
| Utility library | Character classification, string helpers, linked lists |
| Tokenizer | Lexical analysis into tokens |
| Parser | Recursive descent into AST nodes |
| C code emitter | AST to C translation |
| AArch64 code emitter | AST to native assembly translation |
| Driver | Main do selecting mode and tying it all together |

Each section is covered in detail in the following subchapters.
