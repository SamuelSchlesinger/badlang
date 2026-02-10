# Rites

A `rite` is a pure function defined by one or more pattern-matching clauses.

## Syntax

```
rite name
  given pattern1 => body1
  given pattern2 => body2
  ...
seal
```

## How Rites Work

Every rite:

1. Takes a **single argument** (always a record)
2. Tries each `given` clause **in order** from top to bottom
3. Returns the body of the **first matching clause**

If no clause matches, the program crashes at runtime (there is no exhaustiveness
checking yet).

## Single-Clause Rites

The simplest rites have one clause that binds the fields of the argument:

```
rite square
  given {| n |} => n * n
seal

rite greet
  given {| name |} => "Hello"
seal
```

## Multi-Clause Rites

Multiple clauses enable dispatch based on the shape or content of the argument:

```
rite factorial
  given {| n: 0 |} => 1
  given {| n |} => n * (invoke factorial {| n: n - 1 |})
seal
```

The first clause matches when `n` is literally `0`. The second matches any
other value of `n`. Clause order matters — the first match wins.

## Let Bindings in Bodies

A clause body can contain `let` bindings before the final expression:

```
rite distance_sq
  given {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    dx * dx + dy * dy
seal
```

Each `let` introduces a local variable visible to subsequent bindings and the
final expression.

## Calling Other Rites

Rites call other rites with `invoke`:

```
rite hypotenuse_sq
  given {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    (invoke square {| n: dx |}) + (invoke square {| n: dy |})
seal
```

## Recursion

Rites can call themselves recursively:

```
rite fib_acc
  given {| n: 0, a, b |} => a
  given {| n, a, b |} =>
    invoke fib_acc {| n: n - 1, a: b, b: a + b |}
seal
```

## Mutual Recursion

Rites can call each other freely, regardless of declaration order:

```
rite is_even
  given {| n: 0 |} => 1
  given {| n |} => invoke is_odd {| n: n - 1 |}
seal

rite is_odd
  given {| n: 0 |} => 0
  given {| n |} => invoke is_even {| n: n - 1 |}
seal
```

## Structural Subtyping

A rite's pattern determines the **minimum** set of required fields. Any record
with at least those fields will be accepted:

```
rite magnitude_sq
  given {| x, y |} => x * x + y * y
seal

ritual main
  -- All of these work:
  utter invoke magnitude_sq {| x: 3, y: 4 |}
  utter invoke magnitude_sq {| x: 1, y: 2, z: 3 |}
  utter invoke magnitude_sq {| x: 10, y: 10, extra: 999 |}
seal
```

The extra fields `z` and `extra` are silently ignored. This is width subtyping
at work.
