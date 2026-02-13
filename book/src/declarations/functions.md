# Functions

A `fn` is a pure function defined by one or more pattern-matching clauses.

## Syntax

```
fn name
  case pattern1 => body1
  case pattern2 => body2
  ...
end
```

## How Functions Work

Every fn:

1. Takes a **single argument** (always a record)
2. Tries each `case` clause **in order** from top to bottom
3. Returns the body of the **first matching clause**

If no clause matches, the program crashes at runtime (there is no exhaustiveness
checking yet).

## Single-Clause Functions

The simplest functions have one clause that binds the fields of the argument:

```
fn square
  case {| n |} => n * n
end

fn greet
  case {| name |} => "Hello"
end
```

## Multi-Clause Functions

Multiple clauses enable dispatch based on the shape or content of the argument:

```
fn factorial
  case {| n: 0 |} => 1
  case {| n |} => n * (factorial {| n: n - 1 |})
end
```

The first clause matches when `n` is literally `0`. The second matches any
other value of `n`. Clause order matters — the first match wins.

## Let Bindings in Bodies

A clause body can contain `let` bindings before the final expression:

```
fn distance_sq
  case {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    dx * dx + dy * dy
end
```

Each `let` introduces a local variable visible to subsequent bindings and the
final expression.

## Calling Other Functions

Functions call other functions by placing an argument after the function name:

```
fn hypotenuse_sq
  case {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    (square {| n: dx |}) + (square {| n: dy |})
end
```

## Recursion

Functions can call themselves recursively:

```
fn fib_acc
  case {| n: 0, a, b |} => a
  case {| n, a, b |} =>
    fib_acc {| n: n - 1, a: b, b: a + b |}
end
```

## Mutual Recursion

Functions can call each other freely, regardless of declaration order:

```
fn is_even
  case {| n: 0 |} => 1
  case {| n |} => is_odd {| n: n - 1 |}
end

fn is_odd
  case {| n: 0 |} => 0
  case {| n |} => is_even {| n: n - 1 |}
end
```

## Structural Subtyping

A fn's pattern determines the **minimum** set of required fields. Any record
with at least those fields will be accepted:

```
fn magnitude_sq
  case {| x, y |} => x * x + y * y
end

do main
  -- All of these work:
  print magnitude_sq {| x: 3, y: 4 |}
  print magnitude_sq {| x: 1, y: 2, z: 3 |}
  print magnitude_sq {| x: 10, y: 10, extra: 999 |}
end
```

The extra fields `z` and `extra` are silently ignored. This is width subtyping
at work.
