# Recursion

Since Stele has no loops, recursion is the only way to repeat computation.
This chapter covers common recursion patterns.

## Simple Recursion

The classic factorial:

```
fn factorial
  case {| n: 0 |} => 1
  case {| n |} => n * (factorial {| n: n - 1 |})
end
```

The first clause is the base case. The second recurses with `n - 1`. Pattern
matching on literals provides the termination condition.

## Accumulator Pattern

Accumulator-passing style avoids deep call stacks by threading state through
a parameter:

```
fn fib_acc
  case {| n: 0, a, b |} => a
  case {| n, a, b |} =>
    fib_acc {| n: n - 1, a: b, b: a + b |}
end

fn fib
  case {| n |} => fib_acc {| n: n, a: 0, b: 1 |}
end
```

The public-facing `fib` fn wraps the accumulator version with initial
values. Each recursive call is in tail position, making this efficient
in practice.

Here's another example — summing from 1 to n:

```
fn sum_acc
  case {| n: 0, acc |} => acc
  case {| n, acc |} =>
    sum_acc {| n: n - 1, acc: acc + n |}
end
```

## Mutual Recursion

Functions can call each other, enabling mutual recursion. The classic example is
Hofstadter's Female and Male sequences:

```
-- F(0) = 1, M(0) = 0
-- F(n) = n - M(F(n-1))
-- M(n) = n - F(M(n-1))

fn female
  case {| n: 0 |} => 1
  case {| n |} =>
    n - (male {|
      n: female {| n: n - 1 |}
    |})
end

fn male
  case {| n: 0 |} => 0
  case {| n |} =>
    n - (female {|
      n: male {| n: n - 1 |}
    |})
end
```

Declaration order doesn't matter — `female` can reference `male` even though
`male` is defined later. All functions are visible to each other.

## Recursion with match

Combining recursion with `match` for conditional logic:

```
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
```

This counts the number of steps for a Collatz sequence to reach 1. The
`match` branches on whether `n` is even, then recurses with the appropriate
transformation.

## The Euclidean Algorithm

GCD demonstrates recursion with structural dispatch:

```
fn gcd
  case {| a, b: 0 |} => a
  case {| a: 0, b |} => b
  case {| a, b |} =>
    match a > b
      case 1 => gcd {| a: a - b, b: b |}
      case 0 => gcd {| a: a, b: b - a |}
    end
end
```

The first two clauses handle base cases via literal patterns. The third
clause uses `match` to choose which value to reduce.

## The Ackermann Function

The Ackermann function is a classic stress test for recursion — it grows
extremely fast:

```
fn ackermann
  case {| m: 0, n |} => n + 1
  case {| m, n: 0 |} =>
    ackermann {| m: m - 1, n: 1 |}
  case {| m, n |} =>
    ackermann {|
      m: m - 1,
      n: ackermann {| m: m, n: n - 1 |}
    |}
end
```

Three clauses, each matching a different combination of base cases and
recursive cases. The nested call in the third clause demonstrates how
Stele handles deeply recursive computations.

## Even/Odd via Mutual Recursion

A simple but illustrative example:

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

`is_even` delegates to `is_odd` and vice versa, peeling off one from `n`
at each step until the base case is reached.

## Tips

- **Always have a base case.** A literal pattern like `case {| n: 0 |}` is
  the most common termination condition.
- **Use the accumulator pattern** when you're building up a result
  incrementally. Thread an `acc` field through the recursive calls.
- **Pattern order matters.** Put base cases first, recursive cases second.
- **Keep recursion depth reasonable.** Stele compiles to C without tail-call
  optimization, so very deep recursion (millions of frames) will overflow the
  stack.
