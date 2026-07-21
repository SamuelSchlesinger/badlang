# Stele Language Semantics and Boundaries

This document records the behavior shared by the Haskell bootstrap compiler and
the self-hosted compiler. It is the concise compatibility contract for the
current language.

## Values and control flow

- `Int` is a signed 64-bit integer. Out-of-range integer literals are compile
  errors. Addition, subtraction, multiplication, division, remainder, and unary
  negation are checked; arithmetic overflow and zero divisors terminate with a
  runtime error on every backend.
- Comparisons and boolean operators produce `Int`: zero is false and one is
  true. Stele has no separate `Bool` type.
- `String` values are immutable.
- `Void` is an ordinary unit-like type returned by effectful builtins such as
  `write` and `sleep_ms`. It does not unify with arbitrary values.
- `terminate` has the internal bottom type `Never`, so a terminating branch can
  inhabit the result type required by its sibling branch.
- Function and `match` clauses are tried from top to bottom. The first matching
  clause wins. Exhaustiveness is not checked statically; falling through all
  clauses is a runtime pattern-match failure.
- All branches of a function or `match` must produce compatible types.

## Records, structs, and functions

Records are structurally typed and support width subtyping. A function inferred
to require `{| x: Int |}` also accepts a record with additional fields. Missing
fields, wrong field types, and accesses to fields not known to exist are compile
errors.

Every function takes one value. Record arguments are idiomatic, while scalar
arguments use parentheses:

```stele
distance {| a: p, b: q |}
absolute(-4)
```

Every call is checked against the inferred argument type, including calls to
user functions and local closures. Function types are instantiated freshly at
each call site, which provides pragmatic polymorphism for structural helpers.

`struct` provides a named constructor and named type annotation, but record
compatibility remains structural. Stele does not currently have nominal struct
identity.

Although `fn` and `do` communicate intent, the type system does not track
effects: a function may call I/O or process builtins. `do main` is the normal
program entry point.

## Sum types

`oneof` declarations are nominal. Two declared sums do not unify merely because
their variants have the same payload shape. Variant payloads are checked at
construction and in patterns, and nullary variants have the type of their
declaring sum.

Direct field access on a sum is permitted only when every variant declares that
field with a compatible type. Otherwise callers must pattern-match first.

The self-hosted compiler represents its own heterogeneous AST with structural
records containing a literal `tag` field. Such records are treated as a dynamic
tagged-union escape hatch during branch unification. This exception is needed
for bootstrapping and is intentionally weaker than declared `oneof`; application
code should use `oneof` when it wants checked alternatives.

At runtime, declared variants are lowered to immutable records with a private
`__tag` field. That representation is not their source-level type identity.

## Closures

`fn case ... end` is an anonymous function. Closures may capture lexical
variables, be returned, passed as arguments, and stored in records. Captures
live in a dedicated environment distinct from the call argument, so a caller
field with the same name cannot replace a lexical capture.

The runtime closure ABI is `(argument, environment) -> value` on the C,
AArch64, and x86-64 backends. Closure environments follow the same reference
counting ownership rules as records.

## Modules and signatures

Each `.stele` file is a module. `import Math` loads `math.stele` for qualified
access; `open Math` additionally permits unqualified access to its exports.
Imports are recursive, diamond imports are deduplicated, and cycles are errors.

A sibling `.steli` signature restricts exports with one declaration per line,
for example:

```text
fn square
struct Point
oneof Shape
```

Exporting a `oneof` also exports its variants. With no signature, every named
declaration is exported. Signature visibility is enforced by both compilers.
The Haskell CLI additionally supports `-I` / `--search-path`; the self-hosted
CLI currently resolves relative to the importing file.

## Embedded tests

```stele
test "addition"
  print 2 + 2
end
```

Test declarations are parsed and type-checked in all builds but omitted from a
normal executable. Test mode emits a runner that executes test bodies in source
order. If no test declarations exist, it runs `do main` for compatibility with
older test programs. A failed assertion usually calls `terminate`, so the
current runner is fail-fast rather than isolating failures.

## Runtime and portability boundary

Generated values are immutable, boxed, and reference counted. The C backend
embeds the runtime; native assembly links `runtime/runtime.c`. The native
backends target AArch64 macOS/Linux and x86-64 macOS/Linux and use fixed,
16-byte-aligned stack frames sized before function-body emission.

`read`, `write`, `argv`, process operations, string operations, and arithmetic
validate runtime tags before use. `file_exists {| path |}` checks path existence
without invoking a shell. `sh` and `spawn` deliberately execute `/bin/sh -c`;
callers are responsible for quoting any data they interpolate.

The current language has no exhaustiveness checker, exception handling,
concurrent garbage collector, stable foreign ABI, or optimization guarantee.
Those are boundaries of the implementation, not implicit promises.
