# Divine

`divine` is an inline pattern match expression. It evaluates a scrutinee
expression and matches the result against a series of `given` clauses, all
within a single expression context.

## Syntax

```
divine scrutinee
  given pattern1 => body1
  given pattern2 => body2
  ...
seal
```

## Why divine?

badlang has no `if`/`else`. Instead, `divine` fills that role and more. Since
comparison operators return integers (`1` for true, `0` for false), you can
use `divine` to branch on conditions:

```
rite abs
  given {| n |} =>
    divine n >= 0
      given 1 => n
      given 0 => 0 - n
    seal
seal
```

## Matching on Records

`divine` really shines when matching on record shapes:

```
rite fizzbuzz
  given {| n |} =>
    let by3 = n - (n / 3) * 3
    let by5 = n - (n / 5) * 5
    divine {| a: by3, b: by5 |}
      given {| a: 0, b: 0 |} => "fizzbuzz"
      given {| a: 0 |}       => "fizz"
      given {| b: 0 |}       => "buzz"
      given {| a, b |}       => ""
    seal
seal
```

Here, `divine` matches a record with fields `a` and `b`, dispatching on
whether they are zero. This is more expressive than a chain of if/else
statements — it matches on the *structure* of data.

## Matching on Integers

When the scrutinee is a simple integer expression, `divine` acts like a
switch statement:

```
rite collatz_step
  given {| n |} =>
    divine invoke is_even {| n: n |}
      given 1 => n / 2
      given 0 => n * 3 + 1
    seal
seal
```

## Nesting divine

`divine` expressions can be nested:

```
rite classify
  given {| x, y |} =>
    divine x == 0
      given 1 =>
        divine y == 0
          given 1 => "origin"
          given 0 => "y-axis"
        seal
      given 0 =>
        divine y == 0
          given 1 => "x-axis"
          given 0 => "general"
        seal
    seal
seal
```

However, matching on a record with multiple fields (as in the fizzbuzz
example) is usually cleaner than nesting.

## divine vs. Multi-Clause Rites

Both `divine` and multi-clause rites use `given` for pattern matching. The
difference is scope:

- **Multi-clause rites** match on the function's argument at the top level
- **`divine`** matches on any expression, anywhere within an expression

Use multi-clause rites when the dispatch is the primary structure of the
function. Use `divine` when you need to branch partway through a computation.
