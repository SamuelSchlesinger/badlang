# Bootstrapping

A self-hosting compiler faces a chicken-and-egg problem: to compile itself, it
needs a compiler. Bootstrapping is the process of resolving this by using an
existing compiler to get things started.

## The Bootstrap Chain

badlang's bootstrap process uses the Haskell reference compiler as the seed:

```
                    Haskell compiler
                         |
compiler.bad ──────► gen0 binary
                         |
compiler.bad ──────► gen1.c ──► gen1 binary
                                    |
compiler.bad ───────────────► gen2.c ──► gen2 binary
                                            |
compiler.bad ─────────────────────────► gen3.c
```

1. **gen0**: The Haskell compiler compiles `compiler.bad` to C, which is
   compiled to a native binary.
2. **gen1**: The gen0 binary compiles `compiler.bad`, producing `gen1.c`.
3. **gen2**: The gen1 binary compiles `compiler.bad`, producing `gen2.c`.
4. **gen3**: And so on.

## The Fixed Point

The key property is that **gen1.c and gen2.c are identical**. This means the
compiler has reached a **fixed point**: it produces the same output regardless
of which generation compiled it.

Why does gen0's output differ? Because gen0 was compiled by the *Haskell*
compiler, which may generate slightly different C code (different variable
numbering, different formatting). But once the self-hosting compiler compiles
itself (gen1), its output is determined entirely by `compiler.bad` — and since
gen1 and gen2 are the same binary (they came from identical C), they produce
identical output.

This fixed-point property is a strong correctness argument: the compiler
faithfully implements the language semantics that it itself is written in.

## Running the Bootstrap Test

The `bootstrap.sh` script automates the full bootstrap chain. It supports two
modes: **C** (default) and **ASM** (AArch64 native).

```bash
cd examples/compiler
./bootstrap.sh 3        # C mode (default)
./bootstrap.sh 3 asm    # AArch64 native mode
```

This compiles through three generations and verifies:

- Each generation compiles successfully
- gen1 through gen3 output files are all identical
- The final generation can compile `hello.bad` and produce correct output

In C mode, gen0 is always built using the Haskell reference compiler. In ASM
mode, gen0 is still built via C (since the Haskell compiler is the seed), but
subsequent generations emit `.s` files and link against `runtime_aarch64.c`.

A successful C-mode run looks like:

```
=== Badlang Bootstrap Test ===
Generations: 3
Mode: c

[gen0] Compiling compiler.bad with Haskell compiler...
[gen0] OK
[gen1] Compiling compiler.bad with gen0...
[gen1] OK
[gen2] Compiling compiler.bad with gen1...
[gen2] OK
[gen3] Compiling compiler.bad with gen2...
[gen3] OK

=== Verifying Fixed Point ===
[gen1.c == gen2.c] OK
[gen1.c == gen3.c] OK

=== Smoke Test (gen3 compiles hello.bad) ===
Output matches expected: OK

=== BOOTSTRAP SUCCESS ===
The compiler reaches a fixed point at gen1.
All 3 generations produce identical c output.
```

## What the Bootstrap Proves

The bootstrap test establishes several things:

1. **Completeness** — the language is expressive enough to implement its own
   compiler.
2. **Correctness** — the self-hosting compiler agrees with the reference
   compiler on the language's semantics (both produce working compilers).
3. **Determinism** — the compiler produces identical output when case
   identical input, regardless of which generation compiled it.
4. **Stability** — changes to the compiler can be validated by re-running the
   bootstrap and checking that the fixed point is preserved.
