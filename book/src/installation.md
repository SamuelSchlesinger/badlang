# Installation

## Prerequisites

To build the badlang compiler, you need:

- **GHC** 9.6 or later (the Glasgow Haskell Compiler)
- **Cabal** 3.10 or later (the Haskell build tool)
- **A C compiler** — GCC or Clang. The generated code uses
  `__builtin_va_arg` for variadic record construction, which both support.

### Installing GHC and Cabal

The recommended way to install GHC and Cabal is through
[GHCup](https://www.haskell.org/ghcup/):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
```

Follow the prompts to install GHC and Cabal.

## Building the Compiler

Clone the repository and build:

```bash
git clone <repository-url>
cd badlang
cabal build
```

This compiles the badlang compiler. You can verify it works:

```bash
cabal run badlang
```

This prints usage information if no arguments are given.

## Compiling Programs

To compile a `.bad` source file to C:

```bash
cabal run badlang -- examples/hello.bad
```

This produces `examples/hello.c`. You can then compile it manually:

```bash
cc examples/hello.c -o hello
./hello
```

## Compile and Run

The `--run` flag compiles to C, invokes the C compiler, and runs the
resulting binary in one step:

```bash
cabal run badlang -- --run examples/hello.bad
```

Output:

```
25
3628800
```

This is the most convenient way to work during development.
