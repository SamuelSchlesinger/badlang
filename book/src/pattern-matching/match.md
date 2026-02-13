# Match

`match` is an inline pattern match expression. It evaluates a scrutinee
expression and matches the result against a series of `case` clauses, all
within a single expression context.

## Syntax

```
match scrutinee
  case pattern1 => body1
  case pattern2 => body2
  ...
end
```

## Why match?

Stele has no `if`/`else`. Instead, `match` fills that role and more. Since
comparison operators return integers (`1` for true, `0` for false), you can
use `match` to branch on conditions:

```
fn abs
  case {| n |} =>
    match n >= 0
      case 1 => n
      case 0 => 0 - n
    end
end
```

## Matching on Records

`match` really shines when matching on record shapes:

```
fn fizzbuzz
  case {| n |} =>
    let by3 = n - (n / 3) * 3
    let by5 = n - (n / 5) * 5
    match {| a: by3, b: by5 |}
      case {| a: 0, b: 0 |} => "fizzbuzz"
      case {| a: 0 |}       => "fizz"
      case {| b: 0 |}       => "buzz"
      case {| a, b |}       => ""
    end
end
```

Here, `match` matches a record with fields `a` and `b`, dispatching on
whether they are zero. This is more expressive than a chain of if/else
statements — it matches on the *structure* of data.

## Matching on Integers

When the scrutinee is a simple integer expression, `match` acts like a
switch statement:

```
fn collatz_step
  case {| n |} =>
    match is_even {| n: n |}
      case 1 => n / 2
      case 0 => n * 3 + 1
    end
end
```

## Nesting match

`match` expressions can be nested:

```
fn classify
  case {| x, y |} =>
    match x == 0
      case 1 =>
        match y == 0
          case 1 => "origin"
          case 0 => "y-axis"
        end
      case 0 =>
        match y == 0
          case 1 => "x-axis"
          case 0 => "general"
        end
    end
end
```

However, matching on a record with multiple fields (as in the fizzbuzz
example) is usually cleaner than nesting.

## match vs. Multi-Clause Functions

Both `match` and multi-clause functions use `case` for pattern matching. The
difference is scope:

- **Multi-clause functions** match on the function's argument at the top level
- **`match`** matches on any expression, anywhere within an expression

Use multi-clause functions when the dispatch is the primary structure of the
function. Use `match` when you need to branch partway through a computation.
