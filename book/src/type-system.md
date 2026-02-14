# The Type System

Stele uses type inference — you almost never write type annotations. The
compiler figures out the types of all expressions automatically and reports
errors when things don't line up.

## Primitive Types

| Type | Description | Examples |
|------|-------------|---------|
| `Int` | 64-bit signed integer | `0`, `42`, `-5` |
| `String` | Immutable string | `"hello"`, `""` |
| `Void` | Unit type (no meaningful value) | Return type of `write` |

## Record Types

Records have types determined by their fields:

```
{| x: Int, y: Int |}
{| name: String, age: Int |}
{| |}
```

## Open Record Types (Row Polymorphism)

The key insight of Stele's type system is that record types can be **open**.
When a fn pattern-matches on `{| x, y |}`, the inferred type is:

```
{| x: Int, y: Int | r |}
```

The `| r` is a row variable representing "and possibly more fields." This is
what enables structural subtyping — any record with at least `x` and `y` will
match, regardless of additional fields.

Row variables are never written by the programmer. They are inferred
automatically.

## Type Inference Rules

The type checker follows these rules:

| Expression | Inferred Type |
|-----------|--------------|
| Integer literal (`42`) | `Int` |
| String literal (`"hi"`) | `String` |
| Variable | Type from environment |
| `a + b`, `a * b`, etc. | Both operands `Int`, result `Int` |
| `a == b`, `a < b`, etc. | Both operands same type, result `Int` |
| `a && b`, `a \|\| b` | Both operands `Int`, result `Int` |
| `{| x: e1, y: e2 |}` | `{| x: T1, y: T2 |}` |
| `rec.field` | Type of `field` in `rec`'s type |
| `f arg` | Return type of `f` |
| `readln` | `String` |
| `readint` | `Int` |

## How Inference Works

Stele uses **Algorithm W** — the classic Hindley-Milner type inference
algorithm — extended with **Remy-style row types** for records.

The process:

1. **Collect declarations.** All structs, functions, and do blocks are
   registered in the type environment before any bodies are checked.

2. **Infer each body.** For each fn, the type checker walks the pattern and
   body, generating type constraints. For each record pattern, a fresh row
   variable is created to allow extra fields.

3. **Unify constraints.** When two types must be equal (e.g., both sides of
   `+` must be `Int`), the unifier checks compatibility. For records, this
   uses Remy's row unification: matching fields are unified pairwise, and
   remaining fields flow through the row variable.

4. **Report errors.** If unification fails (e.g., adding a string to an
   integer), the type checker reports the mismatch.

## Pragmatic Let-Polymorphism

Each function call creates **fresh type variables** for the callee. This
means a fn can be called with structurally different arguments at different
call sites:

```
fn get_x
  case {| x |} => x
end

do main
  -- Called with different record types at each site:
  print get_x {| x: 42 |}
  print get_x {| x: "hello" |}
end
```

This is a pragmatic form of let-polymorphism that avoids the complexity of
a full polymorphic type system while providing useful flexibility.

## Type Errors

The type checker catches errors like:

- Adding a string to an integer
- Accessing a field that doesn't exist on a record
- Passing a record that's missing required fields

```
fn needs_xyz
  case {| x, y, z |} => x + y + z
end

do main
  -- Type error: record is missing field z
  print needs_xyz {| x: 1, y: 2 |}
end
```

## No Explicit Type Annotations

Type annotations appear in only one place: struct field declarations.

```
struct Point
  x : Int
  y : Int
end
```

Everywhere else — fn bodies, do statements, let bindings — types are
inferred. There is no syntax for writing type annotations on expressions or
function signatures.
