# The Self-Hosting Compiler

badlang is **self-hosting**: the file `examples/compiler/compiler.bad` is a
complete badlang compiler written in badlang itself. It implements the full
compilation pipeline — tokenizer, parser, and C code emitter — and can
compile itself.

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
- **The largest badlang program**, exercising the compiler at scale (~2000
  lines).

## Architecture at a Glance

The self-hosting compiler follows the same pipeline as the Haskell reference
compiler, minus the type checker:

```
Source (.bad) → Tokenize → Parse → Emit C → Write File
```

The compiler reads a source file, tokenizes it, parses the token stream into
an AST, generates C code, and writes the result to a file. It relies on a
shared `runtime.c` that provides the value representation, reference counting,
and built-in rites for file I/O and string manipulation.

The entire compiler is a single file organized into clear sections:

| Section | Purpose |
|---------|---------|
| Utility library | Character classification, string helpers, linked lists |
| Tokenizer | Lexical analysis into tokens |
| Parser | Recursive descent into AST nodes |
| Code emitter | AST to C translation |
| Driver | Main ritual tying it all together |

Each section is covered in detail in the following subchapters.
