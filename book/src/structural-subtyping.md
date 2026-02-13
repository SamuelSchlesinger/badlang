# Structural Subtyping

Structural subtyping is one of badlang's defining features. It means that a
function accepting `{| x, y |}` will work with *any* record that has at least
those fields — regardless of what other fields are present.

## The Core Idea

Consider this fn:

```
fn magnitude_sq
  case {| x, y |} => x * x + y * y
end
```

The pattern `{| x, y |}` declares the **minimum contract**: the argument must
have fields `x` and `y`. But it says nothing about other fields. All of these
calls work:

```
magnitude_sq {| x: 3, y: 4 |}
magnitude_sq {| x: 1, y: 2, z: 3 |}
magnitude_sq {| x: 10, y: 10, name: "point", extra: 999 |}
```

The extra fields (`z`, `name`, `extra`) are silently ignored. This is
**width subtyping** — a wider record (more fields) is a subtype of a narrower
one (fewer fields).

## Practical Benefits

### Code Reuse

A fn that needs only `x` and `y` can operate on 2D points, 3D points,
game entities, UI elements — anything with those fields:

```
struct Vec2
  x : Int
  y : Int
end

struct Vec3
  x : Int
  y : Int
  z : Int
end

fn magnitude_sq
  case {| x, y |} => x * x + y * y
end

do main
  let flat = Vec2 {| x: 3, y: 4 |}
  let deep = Vec3 {| x: 1, y: 2, z: 3 |}

  -- Both work with the same fn
  print magnitude_sq flat
  print magnitude_sq deep
end
```

Output:

```
25
5
```

### Incremental Refinement

You can write functions at different levels of specificity:

```
-- Works with any record having x and y
fn magnitude_sq_2d
  case {| x, y |} => x * x + y * y
end

-- Requires x, y, and z
fn magnitude_sq_3d
  case {| x, y, z |} => x * x + y * y + z * z
end
```

A `Vec3` record works with both. A `Vec2` record works only with the 2D
version. The type system enforces this automatically.

## How It Works: Row Polymorphism

Under the hood, structural subtyping is implemented via **row polymorphism**
(specifically, Remy-style row types).

When the type checker sees `case {| x, y |} => ...`, it infers a type like:

```
{| x: Int, y: Int | r |} -> Int
```

The `r` is a **row variable** — it stands for "any additional fields." When
you call this fn with `{| x: 3, y: 4, z: 5 |}`, the row variable `r`
unifies with `{| z: Int |}`. The required fields are checked; the rest flow
through `r`.

This is fully automatic. You never write row variables yourself — the type
checker infers them.

## Pattern Dispatch and Subtyping

Width subtyping interacts naturally with multi-clause pattern matching:

```
fn classify
  case {| x: 0, y: 0 |} => 0   -- origin
  case {| x: 0 |}       => 1   -- on y-axis
  case {| y: 0 |}       => 2   -- on x-axis
  case {| x, y |}       => 3   -- general point
end
```

Each clause requires different fields. The most specific patterns (requiring
specific values) are tried first. The last clause is a catch-all that accepts
any record with `x` and `y`.

```
do main
  print classify {| x: 0, y: 0 |}      -- 0
  print classify {| x: 0, y: 5 |}      -- 1
  print classify {| x: 7, y: 0 |}      -- 2
  print classify {| x: 3, y: 4 |}      -- 3
end
```

## Anonymous Records

You don't need structs to benefit from structural subtyping. Anonymous records
work just as well:

```
do main
  print magnitude_sq {| x: 10, y: 10, extra: 999 |}
end
```

The `extra` field is accepted and ignored. No struct declaration needed.
