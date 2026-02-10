# Hello, Badlang

Let's walk through a complete program to get a feel for the language.

## Your First Program

Create a file called `first.bad`:

```
ritual main
  utter "Hello, world!"
seal
```

Compile and run it:

```bash
cabal run badlang -- --run first.bad
```

Output:

```
Hello, world!
```

A `ritual` is an effectful entry point — think of it as `main` in C. The body
contains statements that execute for side effects. `utter` prints a value
followed by a newline. `seal` closes the block.

## Adding a Rite

A `rite` is a pure function. Let's add one:

```
rite square
  given {| n |} => n * n
seal

ritual main
  utter invoke square {| n: 5 |}
seal
```

Output:

```
25
```

The rite `square` takes a record with a field `n` and returns `n * n`. We call
it with `invoke`, passing a record literal `{| n: 5 |}`.

## Named Record Types

You can declare named record types with `altar`:

```
altar Point
  x : Int
  y : Int
seal

rite distance_sq
  given {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    dx * dx + dy * dy
seal

ritual main
  let origin = summon Point {| x: 0, y: 0 |}
  let there = summon Point {| x: 3, y: 4 |}
  utter invoke distance_sq {| a: origin, b: there |}
seal
```

Output:

```
25
```

`altar` declares a record type. `summon` constructs a value of that type. The
rite `distance_sq` pattern-matches its argument, extracting the `a` and `b`
fields, each typed as `Point`.

## Recursion

Rites can call themselves:

```
rite factorial
  given {| n: 0 |} => 1
  given {| n |} => n * (invoke factorial {| n: n - 1 |})
seal

ritual main
  utter invoke factorial {| n: 10 |}
seal
```

Output:

```
3628800
```

The first `given` clause matches when `n` is literally `0`. The second matches
any other `n` and recurses. This is how all branching works in badlang — there
is no `if`/`else`, only pattern matching.

## Comments

Line comments start with `--`:

```
-- This is a comment
rite square
  given {| n |} => n * n  -- inline comment
seal
```

## What's Next

The following chapters cover each language feature in depth, starting with
the three kinds of declarations.
