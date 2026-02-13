# Worked Examples

This chapter walks through several complete programs that demonstrate how
badlang's features combine in practice.

## FizzBuzz

The classic interview problem: for a number n, return "fizzbuzz" if divisible
by both 3 and 5, "fizz" if only by 3, "buzz" if only by 5, or empty
otherwise.

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

do main
  print fizzbuzz {| n: 3 |}
  print fizzbuzz {| n: 5 |}
  print fizzbuzz {| n: 15 |}
  print fizzbuzz {| n: 7 |}
end
```

Output:

```
fizz
buzz
fizzbuzz

```

**Key techniques:**

- Since there's no modulo operator, we compute the remainder manually:
  `n - (n / 3) * 3`.
- We pack both remainders into a record and use `match` to match on the
  *combination* of values — much cleaner than nested if/else.
- Width subtyping means `case {| a: 0 |}` matches a record with both `a`
  and `b` fields, as long as `a` is 0. The `b` field is simply ignored.

## Geometry with Structural Subtyping

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

fn magnitude_sq_3d
  case {| x, y, z |} => x * x + y * y + z * z
end

fn classify
  case {| x: 0, y: 0 |} => 0
  case {| x: 0 |}       => 1
  case {| y: 0 |}       => 2
  case {| x, y |}       => 3
end

do main
  let flat = Vec2 {| x: 3, y: 4 |}
  let deep = Vec3 {| x: 1, y: 2, z: 3 |}

  -- Width subtyping: Vec3 works with magnitude_sq
  print magnitude_sq flat
  print magnitude_sq deep
  print magnitude_sq_3d deep

  -- Pattern dispatch
  print classify {| x: 0, y: 0 |}
  print classify {| x: 0, y: 5 |}
  print classify {| x: 7, y: 0 |}
  print classify {| x: 3, y: 4 |}

  -- Anonymous records work too
  print magnitude_sq {| x: 10, y: 10, extra: 999 |}
end
```

Output:

```
25
5
14
0
1
2
3
200
```

**Key techniques:**

- `magnitude_sq` accepts both `Vec2` and `Vec3` because it only needs `x`
  and `y`.
- `classify` uses progressively broader patterns to dispatch on which fields
  are zero.
- Anonymous records with extra fields work seamlessly.

## A Number Theory Toolkit

```
fn is_even
  case {| n |} =>
    let half = n / 2
    match half * 2 == n
      case 1 => 1
      case 0 => 0
    end
end

fn gcd
  case {| a, b: 0 |} => a
  case {| a: 0, b |} => b
  case {| a, b |} =>
    match a > b
      case 1 => gcd {| a: a - b, b: b |}
      case 0 => gcd {| a: a, b: b - a |}
    end
end

fn fib
  case {| n |} => fib_acc {| n: n, a: 0, b: 1 |}
end

fn fib_acc
  case {| n: 0, a, b |} => a
  case {| n, a, b |} =>
    fib_acc {| n: n - 1, a: b, b: a + b |}
end

fn collatz_count
  case {| n: 1, steps |} => steps
  case {| n, steps |} =>
    match is_even {| n: n |}
      case 1 =>
        collatz_count {| n: n / 2, steps: steps + 1 |}
      case 0 =>
        collatz_count {| n: n * 3 + 1, steps: steps + 1 |}
    end
end

do main
  print gcd {| a: 252, b: 105 |}
  print gcd {| a: 1071, b: 462 |}
  print fib {| n: 20 |}
  print collatz_count {| n: 27, steps: 0 |}
end
```

Output:

```
21
21
6765
111
```

**Key techniques:**

- `is_even` uses the multiply-and-compare trick since there's no modulo.
- `gcd` uses subtraction-based Euclidean algorithm with `match` for branching.
- `fib` wraps an accumulator-passing helper for efficiency.
- `collatz_count` combines `match` with recursion for conditional stepping.

## Interactive Program

```
fn factorial
  case {| n: 0 |} => 1
  case {| n |} => n * (factorial {| n: n - 1 |})
end

do main
  print "Enter a number to compute its factorial:"
  write "> "
  let n = readint
  write "The factorial of "
  write n
  write " is "
  print factorial {| n: n |}
end
```

**Key techniques:**

- `readint` reads an integer from stdin.
- `write` builds up a line of output without newlines.
- `print` finishes the line with a newline.
