# Installation

## Prerequisites

To use a pre-built Stele compiler binary, you need only:

- **A C compiler** — GCC or Clang. The generated code uses
  `__builtin_va_arg` for variadic record construction, which both support.

To bootstrap the compiler from source, you also need:

- **GHC** 9.6 or later (the Glasgow Haskell Compiler)
- **Cabal** 3.10 or later (the Haskell build tool)

### Installing GHC and Cabal

The recommended way to install GHC and Cabal is through
[GHCup](https://www.haskell.org/ghcup/):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
```

Follow the prompts to install GHC and Cabal.

## Using a Pre-Built Compiler

If you have a pre-built `compiler` binary, you can compile programs directly:

```bash
./compiler examples/hello.stele hello.c
cc -O1 -o hello hello.c
./hello
```

## Bootstrapping from Source

Clone the repository and bootstrap:

```bash
git clone <repository-url>
cd stele
./bootstrap.sh 2
```

This uses the Haskell bootstrap compiler (in `bootstrap/haskell/`) to build
the self-hosted compiler through two generations and verify a fixed point.
The resulting `compiler` binary is the self-hosted compiler.

You can also bootstrap manually:

```bash
cd bootstrap/haskell
cabal build
cabal run stele -- ../../compiler.stele
cd ../..
cc -O1 -o compiler compiler.c
```

## Compiling Programs

To compile a `.stele` source file to C:

```bash
./compiler examples/hello.stele hello.c
```

This produces `hello.c`. You can then compile and run it:

```bash
cc -O1 -o hello hello.c
./hello
```

Output:

```
25
3628800
```

## Compile to Native Assembly

The self-hosted compiler can also emit native assembly:

```bash
# AArch64 (Apple Silicon / Linux ARM)
./compiler examples/hello.stele hello.s asm
cc -O1 -o hello hello.s runtime/runtime_aarch64.c

# x86_64 (macOS / Linux)
./compiler examples/hello.stele hello.s x86
cc -O1 -o hello hello.s runtime/runtime_x86_64.c
```
