# Recursion

Since badlang has no loops, recursion is the only way to repeat computation.
This chapter covers common recursion patterns.

## Simple Recursion

The classic factorial:

```
rite factorial
  given {| n: 0 |} => 1
  given {| n |} => n * (invoke factorial {| n: n - 1 |})
seal
```

The first clause is the base case. The second recurses with `n - 1`. Pattern
matching on literals provides the termination condition.

## Accumulator Pattern

Accumulator-passing style avoids deep call stacks by threading state through
a parameter:

```
rite fib_acc
  given {| n: 0, a, b |} => a
  given {| n, a, b |} =>
    invoke fib_acc {| n: n - 1, a: b, b: a + b |}
seal

rite fib
  given {| n |} => invoke fib_acc {| n: n, a: 0, b: 1 |}
seal
```

The public-facing `fib` rite wraps the accumulator version with initial
values. Each recursive call is in tail position, making this efficient
in practice.

Here's another example — summing from 1 to n:

```
rite sum_acc
  given {| n: 0, acc |} => acc
  given {| n, acc |} =>
    invoke sum_acc {| n: n - 1, acc: acc + n |}
seal
```

## Mutual Recursion

Rites can call each other, enabling mutual recursion. The classic example is
Hofstadter's Female and Male sequences:

```
-- F(0) = 1, M(0) = 0
-- F(n) = n - M(F(n-1))
-- M(n) = n - F(M(n-1))

rite female
  given {| n: 0 |} => 1
  given {| n |} =>
    n - (invoke male {|
      n: invoke female {| n: n - 1 |}
    |})
seal

rite male
  given {| n: 0 |} => 0
  given {| n |} =>
    n - (invoke female {|
      n: invoke male {| n: n - 1 |}
    |})
seal
```

Declaration order doesn't matter — `female` can reference `male` even though
`male` is defined later. All rites are visible to each other.

## Recursion with divine

Combining recursion with `divine` for conditional logic:

```
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
```

This counts the number of steps for a Collatz sequence to reach 1. The
`divine` branches on whether `n` is even, then recurses with the appropriate
transformation.

## The Euclidean Algorithm

GCD demonstrates recursion with structural dispatch:

```
rite gcd
  given {| a, b: 0 |} => a
  given {| a: 0, b |} => b
  given {| a, b |} =>
    divine a > b
      given 1 => invoke gcd {| a: a - b, b: b |}
      given 0 => invoke gcd {| a: a, b: b - a |}
    seal
seal
```

The first two clauses handle base cases via literal patterns. The third
clause uses `divine` to choose which value to reduce.

## The Ackermann Function

The Ackermann function is a classic stress test for recursion — it grows
extremely fast:

```
rite ackermann
  given {| m: 0, n |} => n + 1
  given {| m, n: 0 |} =>
    invoke ackermann {| m: m - 1, n: 1 |}
  given {| m, n |} =>
    invoke ackermann {|
      m: m - 1,
      n: invoke ackermann {| m: m, n: n - 1 |}
    |}
seal
```

Three clauses, each matching a different combination of base cases and
recursive cases. The nested `invoke` in the third clause demonstrates how
badlang handles deeply recursive computations.

## Even/Odd via Mutual Recursion

A simple but illustrative example:

```
rite is_even
  given {| n: 0 |} => 1
  given {| n |} => invoke is_odd {| n: n - 1 |}
seal

rite is_odd
  given {| n: 0 |} => 0
  given {| n |} => invoke is_even {| n: n - 1 |}
seal
```

`is_even` delegates to `is_odd` and vice versa, peeling off one from `n`
at each step until the base case is reached.

## Tips

- **Always have a base case.** A literal pattern like `given {| n: 0 |}` is
  the most common termination condition.
- **Use the accumulator pattern** when you're building up a result
  incrementally. Thread an `acc` field through the recursive calls.
- **Pattern order matters.** Put base cases first, recursive cases second.
- **Keep recursion depth reasonable.** badlang compiles to C without tail-call
  optimization, so very deep recursion (millions of frames) will overflow the
  stack.
