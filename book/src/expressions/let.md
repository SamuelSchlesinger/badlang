# Let Bindings

`let` introduces a local variable by binding a name to an expression's value.

## In Function Bodies

Inside a `case` clause body, `let` bindings precede the final expression:

```
fn hypotenuse_sq
  case {| a, b |} =>
    let a_sq = a * a
    let b_sq = b * b
    a_sq + b_sq
end
```

Each `let` binding is visible to all subsequent bindings and to the final
return expression. The last expression in the body (without a `let`) is the
return value.

## In Do Blocks

In a do block, `let` bindings introduce variables for subsequent statements:

```
do main
  let x = 5
  let y = x * 2
  print y
end
```

## Shadowing

A `let` binding can shadow a previous binding of the same name:

```
fn example
  case {| n |} =>
    let n = n + 1
    let n = n * 2
    n
end
```

Here, `example {| n: 5 |}` evaluates to `12`: the original `n` (5) is
shadowed by `n + 1` (6), which is shadowed by `n * 2` (12).

## let in Expressions

`let` bindings can appear anywhere a multi-line expression is expected,
including inside `match` bodies:

```
fn classify
  case {| n |} =>
    let positive = n > 0
    match positive
      case 1 =>
        let doubled = n * 2
        doubled
      case 0 => 0
    end
end
```
