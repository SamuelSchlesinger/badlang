# Hello, Badlang

Let's walk through a complete program to get a feel for the language.

## Your First Program

Create a file called `first.bad`:

```
do main
  print "Hello, world!"
end
```

Compile and run it:

```bash
cabal run badlang -- --run first.bad
```

Output:

```
Hello, world!
```

A `do` is an effectful entry point — think of it as `main` in C. The body
contains statements that execute for side effects. `print` prints a value
followed by a newline. `end` closes the block.

## Adding a Function

A `fn` is a pure function. Let's add one:

```
fn square
  case {| n |} => n * n
end

do main
  print square {| n: 5 |}
end
```

Output:

```
25
```

The fn `square` takes a record with a field `n` and returns `n * n`. We call
it by passing a record literal `{| n: 5 |}`.

## Named Record Types

You can declare named record types with `struct`:

```
struct Point
  x : Int
  y : Int
end

fn distance_sq
  case {| a : Point, b : Point |} =>
    let dx = a.x - b.x
    let dy = a.y - b.y
    dx * dx + dy * dy
end

do main
  let origin = Point {| x: 0, y: 0 |}
  let there = Point {| x: 3, y: 4 |}
  print distance_sq {| a: origin, b: there |}
end
```

Output:

```
25
```

`struct` declares a record type. Construction uses the type name followed by a
record literal, as in `Point {| x: 0, y: 0 |}`. The fn `distance_sq`
pattern-matches its argument, extracting the `a` and `b` fields, each typed
as `Point`.

## Recursion

Functions can call themselves:

```
fn factorial
  case {| n: 0 |} => 1
  case {| n |} => n * (factorial {| n: n - 1 |})
end

do main
  print factorial {| n: 10 |}
end
```

Output:

```
3628800
```

The first `case` clause matches when `n` is literally `0`. The second matches
any other `n` and recurses. This is how all branching works in badlang — there
is no `if`/`else`, only pattern matching.

## Comments

Line comments start with `--`:

```
-- This is a comment
fn square
  case {| n |} => n * n  -- inline comment
end
```

## What's Next

The following chapters cover each language feature in depth, starting with
the three kinds of declarations.
