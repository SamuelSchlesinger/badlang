# Let Bindings

`let` introduces a local variable by binding a name to an expression's value.

## In Rite Bodies

Inside a `given` clause body, `let` bindings precede the final expression:

```
rite hypotenuse_sq
  given {| a, b |} =>
    let a_sq = a * a
    let b_sq = b * b
    a_sq + b_sq
seal
```

Each `let` binding is visible to all subsequent bindings and to the final
return expression. The last expression in the body (without a `let`) is the
return value.

## In Rituals

In a ritual, `let` bindings introduce variables for subsequent statements:

```
ritual main
  let x = 5
  let y = x * 2
  utter y
seal
```

## Shadowing

A `let` binding can shadow a previous binding of the same name:

```
rite example
  given {| n |} =>
    let n = n + 1
    let n = n * 2
    n
seal
```

Here, `invoke example {| n: 5 |}` evaluates to `12`: the original `n` (5) is
shadowed by `n + 1` (6), which is shadowed by `n * 2` (12).

## let in Expressions

`let` bindings can appear anywhere a multi-line expression is expected,
including inside `divine` bodies:

```
rite classify
  given {| n |} =>
    let positive = n > 0
    divine positive
      given 1 =>
        let doubled = n * 2
        doubled
      given 0 => 0
    seal
seal
```
