# Worked Examples

This chapter walks through several complete programs that demonstrate how
badlang's features combine in practice.

## FizzBuzz

The classic interview problem: for a number n, return "fizzbuzz" if divisible
by both 3 and 5, "fizz" if only by 3, "buzz" if only by 5, or empty
otherwise.

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

ritual main
  utter invoke fizzbuzz {| n: 3 |}
  utter invoke fizzbuzz {| n: 5 |}
  utter invoke fizzbuzz {| n: 15 |}
  utter invoke fizzbuzz {| n: 7 |}
seal
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
- We pack both remainders into a record and use `divine` to match on the
  *combination* of values — much cleaner than nested if/else.
- Width subtyping means `given {| a: 0 |}` matches a record with both `a`
  and `b` fields, as long as `a` is 0. The `b` field is simply ignored.

## Geometry with Structural Subtyping

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

rite magnitude_sq_3d
  given {| x, y, z |} => x * x + y * y + z * z
seal

rite classify
  given {| x: 0, y: 0 |} => 0
  given {| x: 0 |}       => 1
  given {| y: 0 |}       => 2
  given {| x, y |}       => 3
seal

ritual main
  let flat = summon Vec2 {| x: 3, y: 4 |}
  let deep = summon Vec3 {| x: 1, y: 2, z: 3 |}

  -- Width subtyping: Vec3 works with magnitude_sq
  utter invoke magnitude_sq flat
  utter invoke magnitude_sq deep
  utter invoke magnitude_sq_3d deep

  -- Pattern dispatch
  utter invoke classify {| x: 0, y: 0 |}
  utter invoke classify {| x: 0, y: 5 |}
  utter invoke classify {| x: 7, y: 0 |}
  utter invoke classify {| x: 3, y: 4 |}

  -- Anonymous records work too
  utter invoke magnitude_sq {| x: 10, y: 10, extra: 999 |}
seal
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
rite is_even
  given {| n |} =>
    let half = n / 2
    divine half * 2 == n
      given 1 => 1
      given 0 => 0
    seal
seal

rite gcd
  given {| a, b: 0 |} => a
  given {| a: 0, b |} => b
  given {| a, b |} =>
    divine a > b
      given 1 => invoke gcd {| a: a - b, b: b |}
      given 0 => invoke gcd {| a: a, b: b - a |}
    seal
seal

rite fib
  given {| n |} => invoke fib_acc {| n: n, a: 0, b: 1 |}
seal

rite fib_acc
  given {| n: 0, a, b |} => a
  given {| n, a, b |} =>
    invoke fib_acc {| n: n - 1, a: b, b: a + b |}
seal

rite collatz_count
  given {| n: 1, steps |} => steps
  given {| n, steps |} =>
    divine invoke is_even {| n: n |}
      given 1 =>
        invoke collatz_count {| n: n / 2, steps: steps + 1 |}
      given 0 =>
        invoke collatz_count {| n: n * 3 + 1, steps: steps + 1 |}
    seal
seal

ritual main
  utter invoke gcd {| a: 252, b: 105 |}
  utter invoke gcd {| a: 1071, b: 462 |}
  utter invoke fib {| n: 20 |}
  utter invoke collatz_count {| n: 27, steps: 0 |}
seal
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
- `gcd` uses subtraction-based Euclidean algorithm with `divine` for branching.
- `fib` wraps an accumulator-passing helper for efficiency.
- `collatz_count` combines `divine` with recursion for conditional stepping.

## Interactive Program

```
rite factorial
  given {| n: 0 |} => 1
  given {| n |} => n * (invoke factorial {| n: n - 1 |})
seal

ritual main
  utter "Enter a number to compute its factorial:"
  whisper "> "
  let n = scry
  whisper "The factorial of "
  whisper n
  whisper " is "
  utter invoke factorial {| n: n |}
seal
```

**Key techniques:**

- `scry` reads an integer from stdin.
- `whisper` builds up a line of output without newlines.
- `utter` finishes the line with a newline.
