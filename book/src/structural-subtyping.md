# Structural Subtyping

Structural subtyping is one of badlang's defining features. It means that a
function accepting `{| x, y |}` will work with *any* record that has at least
those fields — regardless of what other fields are present.

## The Core Idea

Consider this rite:

```
rite magnitude_sq
  given {| x, y |} => x * x + y * y
seal
```

The pattern `{| x, y |}` declares the **minimum contract**: the argument must
have fields `x` and `y`. But it says nothing about other fields. All of these
calls work:

```
invoke magnitude_sq {| x: 3, y: 4 |}
invoke magnitude_sq {| x: 1, y: 2, z: 3 |}
invoke magnitude_sq {| x: 10, y: 10, name: "point", extra: 999 |}
```

The extra fields (`z`, `name`, `extra`) are silently ignored. This is
**width subtyping** — a wider record (more fields) is a subtype of a narrower
one (fewer fields).

## Practical Benefits

### Code Reuse

A rite that needs only `x` and `y` can operate on 2D points, 3D points,
game entities, UI elements — anything with those fields:

```
altar Vec2
  x : Int
  y : Int
seal

altar Vec3
  x : Int
  y : Int
  z : Int
seal

rite magnitude_sq
  given {| x, y |} => x * x + y * y
seal

ritual main
  let flat = summon Vec2 {| x: 3, y: 4 |}
  let deep = summon Vec3 {| x: 1, y: 2, z: 3 |}

  -- Both work with the same rite
  utter invoke magnitude_sq flat
  utter invoke magnitude_sq deep
seal
```

Output:

```
25
5
```

### Incremental Refinement

You can write rites at different levels of specificity:

```
-- Works with any record having x and y
rite magnitude_sq_2d
  given {| x, y |} => x * x + y * y
seal

-- Requires x, y, and z
rite magnitude_sq_3d
  given {| x, y, z |} => x * x + y * y + z * z
seal
```

A `Vec3` record works with both. A `Vec2` record works only with the 2D
version. The type system enforces this automatically.

## How It Works: Row Polymorphism

Under the hood, structural subtyping is implemented via **row polymorphism**
(specifically, Remy-style row types).

When the type checker sees `given {| x, y |} => ...`, it infers a type like:

```
{| x: Int, y: Int | r |} -> Int
```

The `r` is a **row variable** — it stands for "any additional fields." When
you call this rite with `{| x: 3, y: 4, z: 5 |}`, the row variable `r`
unifies with `{| z: Int |}`. The required fields are checked; the rest flow
through `r`.

This is fully automatic. You never write row variables yourself — the type
checker infers them.

## Pattern Dispatch and Subtyping

Width subtyping interacts naturally with multi-clause pattern matching:

```
rite classify
  given {| x: 0, y: 0 |} => 0   -- origin
  given {| x: 0 |}       => 1   -- on y-axis
  given {| y: 0 |}       => 2   -- on x-axis
  given {| x, y |}       => 3   -- general point
seal
```

Each clause requires different fields. The most specific patterns (requiring
specific values) are tried first. The last clause is a catch-all that accepts
any record with `x` and `y`.

```
ritual main
  utter invoke classify {| x: 0, y: 0 |}      -- 0
  utter invoke classify {| x: 0, y: 5 |}      -- 1
  utter invoke classify {| x: 7, y: 0 |}      -- 2
  utter invoke classify {| x: 3, y: 4 |}      -- 3
seal
```

## Anonymous Records

You don't need altars to benefit from structural subtyping. Anonymous records
work just as well:

```
ritual main
  utter invoke magnitude_sq {| x: 10, y: 10, extra: 999 |}
seal
```

The `extra` field is accepted and ignored. No altar declaration needed.
